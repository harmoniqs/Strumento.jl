# twin_job_server.jl — the server module body (included from
# StrumentoJobServerExt). The wire contract types, the payload reader, the
# envelope-level translation, the twin execution path, the job queue, and the
# stdlib HTTP server. Developed slice by slice (issue #29).

using Base64: base64decode

# ──── The decoded wire payload ───────────────────────────────────────────────
# qick's dump_prog() dict, decoded to its physical meaning. Every field below
# is qick's own encoding, decoded per qick's own source (NpEncoder/decode_array
# for the envelope pages, cfg2reg for the conf bits, int2freq for the DDS) —
# no format invention (the D14 constraint).

"""One envelope page: the NpEncoder triple (base64, shape, dtype) decoded to
int16 I/Q sample vectors, with its placement (`addr`, in samples) and the
generator's `next_addr` watermark."""
struct EnvelopePage
    name::String
    addr::Int
    idata::Vector{Int16}
    qdata::Vector{Int16}
end

"""One wave-table entry: a pulse assignment on a generator channel, with
qick's register codes decoded to physical meaning (freq MHz, phase deg) and
the conf bits unpacked (outsel/mode/stdysel/phrst per cfg2reg's layout)."""
struct WireWave
    name::String
    freq_MHz::Float64
    phase_deg::Float64
    env_addr::Int
    gain_code::Int
    length_cycles::Int
    outsel::String
    mode::String
    stdysel::String
    phrst::Bool
end

"""The decoded `CompiledJob`: what the envelope-level translation and the
output shaping need. The tProc lane (`prog_list`/`labels`) is read ONLY for
the static port-assignment pairing (which wave plays on which generator —
qick's own dump pairing), never interpreted for control flow."""
struct WirePayload
    overlay_id::String
    envelopes::Dict{Int,Vector{EnvelopePage}}   # gen ch => pages in table order
    next_addrs::Dict{Int,Int}                   # gen ch => envelope watermark
    waves::Vector{WireWave}                     # the wave table, in order
    port_plan::Vector{Pair{Int,Vector{Int}}}   # gen ch => wave indices (play order)
    gen_cfg::Dict{Int,NamedTuple}               # gen ch => the soccfg facts used
    loop_dims::Vector{Int}
    avg_level::Int
    labels::Dict{String,String}
    reps::Int
    soft_avgs::Int
    ro_chs::Vector{Int}
    reads_per_shot::Vector{Int}
    expts::Union{Nothing,Int}
end

# The soccfg facts a played generator contributes (fs in Hz, sample-memory
# addressing, amplitude scale, the DDS/phase decode pair, the port id). The
# Nyquist zone is NOT here — it is a per-program declaration (gen_chs).
function _gen_facts(soccfg::AbstractDict, gen_ch::Int)
    gens = get(soccfg, "gens", nothing)
    (gens isa AbstractVector && 0 ≤ gen_ch < length(gens)) || error(
        "read_payload: generator channel $gen_ch is not in the overlay's " *
        "soccfg (has $(gens === nothing ? 0 : length(gens)))",
    )
    g = gens[gen_ch+1]          # wire channels are 0-based; the soccfg gens list is 1-based
    for k in ("fs", "samps_per_clk", "maxv", "f_dds", "b_dds", "b_phase", "tproc_ch")
        haskey(g, k) || error(
            "read_payload: the overlay soccfg's gens[$gen_ch] is missing `$k` " *
            "— a dump_cfg() snapshot carries it (D25: one overlay, one snapshot)",
        )
    end
    return (
        fs_hz = Float64(g["fs"]) * 1e6,
        samps_per_clk = Int(g["samps_per_clk"]),
        maxv = Int(g["maxv"]),
        f_dds_MHz = Float64(g["f_dds"]),
        b_dds = Int(g["b_dds"]),
        b_phase = Int(g["b_phase"]),
        tproc_ch = Int(g["tproc_ch"]),
    )
end

# Decode one NpEncoder triple (base64, shape, dtype) per qick's decode_array.
# v1 supports the envelope dtype qick's generators actually emit (little-
# endian int16, shape (n, 2) I/Q); anything else is named, not guessed.
function _decode_np_array(triple, what::String)
    (triple isa AbstractVector && length(triple) == 3) || error(
        "read_payload: $what is not an NpEncoder triple [base64, shape, dtype] " *
        "(got $(typeof(triple)))",
    )
    b64, shape, dtype = triple
    b64 isa AbstractString || error("read_payload: $what's base64 payload is not a string")
    shape isa AbstractVector || error("read_payload: $what's shape is not a list")
    dtype isa AbstractString || error("read_payload: $what's dtype is not a string")
    dtype == "<i2" || error(
        "read_payload: $what has dtype $(repr(dtype)) — v1 decodes the envelope " *
        "pages qick's complex-env generators emit (\"<i2\", int16)",
    )
    (length(shape) == 2 && shape[2] == 2) || error(
        "read_payload: $what's shape $shape is not (n, 2) — complex-env envelope " *
        "pages are I/Q pairs",
    )
    n = Int(shape[1])
    raw = try
        base64decode(b64)
    catch err
        error("read_payload: $what's base64 does not decode ($(sprint(showerror, err)))")
    end
    length(raw) == 2 * n * sizeof(Int16) || error(
        "read_payload: $what carries $(length(raw)) bytes but declares $n I/Q int16 " *
        "pairs ($(2 * n * sizeof(Int16)) bytes) — the payload is malformed",
    )
    samples = reinterpret(Int16, raw)
    return Vector{Int16}(samples[1:2:(2n-1)]), Vector{Int16}(samples[2:2:2n])
end

# The channel keys of a dump_prog channel map (a JSON object keyed by the
# channel's string form: "0", "1", ...).
keys_str(obj) = String[string(k) for k in keys(obj)]   # then parse(Int, _) for channels

# Unpack qick's generator conf register (cfg2reg's layout: outsel bits 0-1,
# mode bit 2, stdysel bit 3, phrst bit 4, tmux at bit 8+).
function _decode_conf(conf::Int, name::String)
    conf < 2^8 || error(
        "read_payload: wave $(repr(name)) carries tmux bits in conf ($conf) — " *
        "muxed generators are outside the twin server's v1 envelope level",
    )
    return (
        outsel = ("product", "dds", "input", "zero")[(conf&3)+1],
        mode = (conf >> 2) & 1 == 0 ? "oneshot" : "periodic",
        stdysel = (conf >> 3) & 1 == 0 ? "last" : "zero",
        phrst = (conf >> 4) & 1 == 1,
    )
end

"""
    read_payload(soccfg, job_wire) -> WirePayload

Decode one `CompiledJob` wire dict against the overlay's soccfg snapshot
(`dump_cfg()` form). The payload is qick's `dump_prog()` serialized through
`NpEncoder`; every decode follows qick's own encoder semantics — envelope
pages via `decode_array` (base64 int16 (n, 2) I/Q), the wave codes via
`int2freq`/`deg2reg`'s inverse and `cfg2reg`'s bit layout, the played pairing
via the `WPORT_WR` port-assignment table. The sweep axis is realized from the
DECLARED loop structure (`loop_dims`/`avg_level`), never from tProc register
semantics — the axis is the product of the loop dimensions with the averaged
axis removed.
"""
function read_payload(soccfg::AbstractDict, job_wire::AbstractDict)
    for key in ("overlay_id", "program", "acquire")
        haskey(job_wire, key) || error(
            "read_payload: the CompiledJob wire form is missing `$key` " *
            "(the D14 contract is {overlay_id, program, acquire})",
        )
    end
    program, acquire = job_wire["program"], job_wire["acquire"]
    for key in
        ("envelopes", "gen_chs", "ro_chs", "waves", "prog_list", "loop_dims", "avg_level")
        haskey(program, key) || error(
            "read_payload: program is missing `$key` — the payload is qick's " *
            "dump_prog() dict; a key this central being absent means the " *
            "payload was not produced by the D14 path",
        )
    end

    # ── envelope pages, per declared generator ──
    # dump_prog's `envelopes` is a LIST indexed by generator channel (the
    # same shape load_prog enumerates); each element is that gen's page dict.
    envelopes = Dict{Int,Vector{EnvelopePage}}()
    next_addrs = Dict{Int,Int}()
    for (i, envdict) in enumerate(program["envelopes"])
        gen_ch = i - 1                # wire numbering: the payload's generator channel
        haskey(envdict, "next_addr") || error(
            "read_payload: envelopes[$gen_ch] carries no `next_addr` — the " *
            "sample-memory watermark is part of dump_prog's envelope form",
        )
        next_addrs[gen_ch] = Int(envdict["next_addr"])
        pages = EnvelopePage[]
        for (name, env) in get(envdict, "envs", Dict())
            haskey(env, "addr") || error(
                "read_payload: envelope $(repr(name)) on gen $gen_ch carries no `addr`",
            )
            idata, qdata =
                _decode_np_array(env["data"], "envelope $(repr(name)) (gen $gen_ch)")
            push!(pages, EnvelopePage(string(name), Int(env["addr"]), idata, qdata))
        end
        envelopes[gen_ch] = pages
    end

    # ── the played port plan FIRST: the static WPORT_WR pairing ──
    # DST = the generator's tProc channel, ADDR = the wave-table index. This
    # is the wave-table's port assignment (qick's own dump pairing), read as
    # DATA — no register values, timing, or branching are interpreted.
    # (Parsed first because the wave decode needs the gen association: the
    # DDS facts that give register codes physical meaning are per-generator.)
    soccfg_gens = get(soccfg, "gens", [])
    tproc_to_gen = Dict{Int,Int}(
        _gen_facts(soccfg, ch).tproc_ch => ch for ch = 0:(length(soccfg_gens)-1)
    )
    n_waves = length(program["waves"])
    played = Dict{Int,Vector{Int}}()
    for inst in program["prog_list"]
        get(inst, "CMD", "") == "WPORT_WR" || continue
        dst, addr = get(inst, "DST", nothing), get(inst, "ADDR", nothing)
        dst isa AbstractString && addr isa AbstractString || error(
            "read_payload: a WPORT_WR entry lacks DST/ADDR — the port " *
            "assignment table is malformed",
        )
        haskey(tproc_to_gen, parse(Int, dst)) || continue   # a readout-config write, not a drive
        startswith(addr, "&") || error(
            "read_payload: WPORT_WR ADDR $(repr(addr)) is not a wave-table " *
            "reference (\"&<index>\")",
        )
        idx = parse(Int, addr[2:end]) + 1
        1 ≤ idx ≤ n_waves || error(
            "read_payload: WPORT_WR references wave $idx but the wave table " *
            "holds $n_waves",
        )
        gen_ch = tproc_to_gen[parse(Int, dst)]
        order = get!(() -> Int[], played, gen_ch)
        idx in order || push!(order, idx)
    end
    port_plan = [gen_ch => played[gen_ch] for gen_ch in sort(collect(keys(played)))]

    # ── the wave table: qick's codes, decoded against the playing generator ──
    # The gen association is NOT in the wave entries — it lives in the port
    # plan above. A wave played on several generators decodes against the
    # first (same-type gens at the same fs, per qick's multi-gen rule).
    wave_gen = Dict{Int,Int}()
    for (gen_ch, idxs) in played, idx in idxs
        haskey(wave_gen, idx) || (wave_gen[idx] = gen_ch)
    end
    fallback_gen = isempty(played) ? 0 : port_plan[1].first
    # the per-program generator declarations (the Nyquist zone lives here)
    gen_decls = get(program, "gen_chs", Dict())
    nqz(gen_ch) = begin
        decl = get(gen_decls, string(gen_ch), nothing)
        decl isa AbstractDict || error(
            "read_payload: generator channel $gen_ch plays a wave but is not " *
            "declared in gen_chs — the Nyquist zone rides the declaration",
        )
        haskey(decl, "nqz") || error(
            "read_payload: gen_chs[$gen_ch] carries no `nqz` — the " *
            "Nyquist zone is part of dump_prog's generator declaration",
        )
        Int(decl["nqz"])
    end
    waves = WireWave[]
    for (i, w) in enumerate(program["waves"])
        for key in ("name", "freq", "phase", "env", "gain", "length", "conf")
            haskey(w, key) || error(
                "read_payload: a wave is missing `$key` — the wave table " *
                "(freq/phase/env/gain/length/conf) is dump_prog's assignment form",
            )
        end
        gen_ch = get(wave_gen, i, fallback_gen)
        facts = _gen_facts(soccfg, gen_ch)
        conf = _decode_conf(Int(w["conf"]), string(w["name"]))
        push!(
            waves,
            WireWave(
                string(w["name"]),
                Int(w["freq"]) * facts.f_dds_MHz / 2^facts.b_dds,
                Int(w["phase"]) * 360.0 / 2^facts.b_phase,
                Int(w["env"]),
                Int(w["gain"]),
                Int(w["length"]),
                conf.outsel,
                conf.mode,
                conf.stdysel,
                conf.phrst,
            ),
        )
    end

    # ── the soccfg facts for the played generators (zone from the program) ──
    gen_cfg = Dict{Int,NamedTuple}(
        gen_ch => merge(_gen_facts(soccfg, gen_ch), (nqz = nqz(gen_ch),)) for
        gen_ch in keys(played)
    )

    # ── the declared loop structure + the acquire block ──
    loop_dims = Int.(program["loop_dims"])
    avg_level = Int(program["avg_level"])
    0 ≤ avg_level < length(loop_dims) ||
        error("read_payload: avg_level $avg_level is outside loop_dims $loop_dims")
    for key in ("reps", "soft_avgs", "ro_chs", "reads_per_shot")
        haskey(acquire, key) || error(
            "read_payload: the acquire block is missing `$key` (the D14 shape " *
            "contract: reps/soft_avgs/ro_chs/reads_per_shot[/expts])",
        )
    end
    reps, soft_avgs = Int(acquire["reps"]), Int(acquire["soft_avgs"])
    reps ≥ 1 || error("read_payload: acquire reps must be ≥ 1 (got $reps)")
    soft_avgs ≥ 1 || error("read_payload: acquire soft_avgs must be ≥ 1 (got $soft_avgs)")
    ro_chs = Int.(acquire["ro_chs"])
    reads_per_shot = Int.(acquire["reads_per_shot"])
    # the declared readout surface must match the program's own declarations —
    # the same refuse-on-mismatch rule the reference board-side agent applies
    # (ro_chs and reads_per_shot come from the program's trigger counting, so
    # a disagreement means the buffers would be silently mis-shaped).
    declared_ros = sort!(parse.(Int, keys_str(program["ro_chs"])))
    sort!(ro_chs) == declared_ros || error(
        "read_payload: the acquire block declares readout channels $(sort!(copy(ro_chs))) " *
        "but the program declared $declared_ros — refusing a job whose declared " *
        "shape does not match its program",
    )
    length(reads_per_shot) == length(ro_chs) || error(
        "read_payload: reads_per_shot has $(length(reads_per_shot)) entries but " *
        "acquire declares $(length(ro_chs)) readout channels",
    )
    for (i, ch) in enumerate(ro_chs)
        trigs = get(program["ro_chs"][string(ch)], "trigs", nothing)
        trigs isa Integer || error(
            "read_payload: the program's ro_chs[$ch] carries no `trigs` — " *
            "the per-channel trigger count is dump_prog's declaration",
        )
        reads_per_shot[i] == Int(trigs) || error(
            "read_payload: the acquire block declares reads_per_shot[$i] = " *
            "$(reads_per_shot[i]) but the program's readout channel $ch triggers " *
            "$trigs reads per shot — refusing a job whose declared shape does " *
            "not match its program",
        )
    end
    expt_dims = loop_dims[setdiff(1:length(loop_dims), avg_level + 1)]
    derived_expts = isempty(expt_dims) ? nothing : prod(expt_dims)
    declared = get(acquire, "expts", nothing)
    declared === nothing ||
        declared == derived_expts ||
        error(
            "read_payload: the acquire block declares expts=$declared but the " *
            "program's loop structure $loop_dims (avg_level $avg_level) yields " *
            "$(derived_expts === nothing ? "no expts axis" : derived_expts) — " *
            "refusing a job whose declared shape does not match its program",
        )
    return WirePayload(
        string(job_wire["overlay_id"]),
        envelopes,
        next_addrs,
        waves,
        port_plan,
        gen_cfg,
        loop_dims,
        avg_level,
        Dict{String,String}(
            string(k) => string(v) for (k, v) in get(program, "labels", Dict())
        ),
        reps,
        soft_avgs,
        ro_chs,
        reads_per_shot,
        derived_expts,
    )
end

@testitem "the twin job server rides its own Piccolo+JSON extension" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (job-server extension surface)"
        @test true
    else
        using Piccolo       # the physics trigger: loads StrumentoPiccoloExt
        using JSON          # the wire trigger: with Piccolo, attaches THIS extension
        ext = Base.get_extension(Strumento, :StrumentoJobServerExt)
        @test ext !== nothing
        @test isdefined(ext, :TwinJobServer)
        # the extension never leaks onto the parent (Julia 1.12 semantics)
        @test !isdefined(Strumento, :TwinJobServer)
    end
end

@testitem "read_payload decodes the golden fixture's wire form" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (job-server extension surface)"
        @test true
    else
        using Piccolo   # the physics trigger: with JSON, attaches the extension
        using JSON
        ext = Base.get_extension(Strumento, :StrumentoJobServerExt)
        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
        soccfg = JSON.parsefile(joinpath(fixtures, "soccfg_v2_testbench.json"))
        wire = JSON.parsefile(joinpath(fixtures, "compiled_job_golden.json"))

        payload = ext.read_payload(soccfg, wire)

        # the envelope pages: NpEncoder form (base64, shape, dtype) -> int16 I/Q.
        # Pinned from the committed fixture (exact integers, no float goldens):
        # env0_0 is a 1152-sample gaussian, I-only (Q all zero), DAC peak 32766.
        @test length(payload.envelopes) == 1
        pages = payload.envelopes[0]                  # gen channel 0
        @test length(pages) == 1
        page = pages[1]
        @test page.name == "env0_0"
        @test page.addr == 0
        @test payload.next_addrs[0] == 1152            # the gen's next free address
        @test length(page.idata) == 1152
        @test page.idata[1:8] == [4421, 4452, 4483, 4514, 4546, 4577, 4609, 4641]
        @test page.idata[(end-3):end] == [4514, 4483, 4452, 4421]
        @test maximum(page.idata) == 32766
        @test all(iszero, page.qdata)

        # the wave table: qick's own codes, decoded to their physical meaning.
        @test length(payload.waves) == 1
        wave = payload.waves[1]
        @test wave.name == "pulse0_0_w0"
        @test wave.freq_MHz ≈ 4000.0 atol = 1e-3      # reg 1792437607, f_dds 9584.64, 32-bit DDS
        @test wave.phase_deg == 0
        @test wave.gain_code == 0                     # the sweep's start value
        @test wave.length_cycles == 72                # fabric cycles; 1152 = 72 x 16 samples
        @test wave.outsel == "product"                 # conf 8: stdysel zero, oneshot, product, no phrst
        @test wave.env_addr == 0                      # the envelope's addr // samps_per_clk

        # the played port plan: WPORT_WR DST (the gen's tproc channel) -> wave
        # indices in play order. One wave on generator 0 (tproc channel 0).
        @test payload.port_plan == [0 => [1]]         # gen ch 0 -> [wave 1]

        # the declared loop structure + the acquire block: the axis contract.
        @test payload.loop_dims == [100, 11]
        @test payload.avg_level == 0
        @test payload.reps == 100
        @test payload.soft_avgs == 2
        @test payload.ro_chs == [0]
        @test payload.reads_per_shot == [1]
        @test payload.expts == 11                      # prod of loop_dims minus the averaged axis
    end
end

@testitem "read_payload names the defect on malformed payloads" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (job-server extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        ext = Base.get_extension(Strumento, :StrumentoJobServerExt)
        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
        soccfg = JSON.parsefile(joinpath(fixtures, "soccfg_v2_testbench.json"))
        golden = JSON.parsefile(joinpath(fixtures, "compiled_job_golden.json"))

        # every case: the mutation, and the needle the error must carry (the
        # error names WHAT is wrong and WHERE — a malformed payload is a
        # wire-contract violation, not a 500).
        mutate(fn) = (w = deepcopy(golden); fn(w); w)
        cases = [
            (mutate(w -> delete!(w, "program")), "missing `program`"),
            (mutate(w -> delete!(w["program"], "waves")), "missing `waves`"),
            (mutate(w -> delete!(w["program"], "avg_level")), "missing `avg_level`"),
            # a truncated envelope: the declared shape outruns the bytes
            (
                mutate(
                    w -> (
                        e = w["program"]["envelopes"][1]["envs"]["env0_0"];
                        e["data"] = [e["data"][1], [10, 2], e["data"][3]];
                        w
                    ),
                ),
                "declares 10 I/Q int16 pairs",
            ),
            # a shape that is not an I/Q pair
            (
                mutate(
                    w -> (
                        e = w["program"]["envelopes"][1]["envs"]["env0_0"];
                        e["data"] = [e["data"][1], [1152, 1], e["data"][3]];
                        w
                    ),
                ),
                "(n, 2)",
            ),
            # an unsupported dtype (qick emits int16 pages)
            (
                mutate(
                    w -> (
                        e = w["program"]["envelopes"][1]["envs"]["env0_0"];
                        e["data"] = [e["data"][1], e["data"][2], "<i4"];
                        w
                    ),
                ),
                "\"<i4\"",
            ),
            # a wave entry missing its gain
            (
                mutate(
                    w -> (
                        d = Dict(w["program"]["waves"][1]);
                        delete!(d, "gain");
                        w["program"]["waves"][1] = d;
                        w
                    ),
                ),
                "`gain`",
            ),
            # tmux bits in conf — muxed generators are outside v1's envelope level
            (
                mutate(
                    w -> (
                        d = Dict(w["program"]["waves"][1]);
                        d["conf"] = 256 + d["conf"];
                        w["program"]["waves"][1] = d;
                        w
                    ),
                ),
                "tmux",
            ),
            # a port write pointing past the wave table
            (
                mutate(
                    w -> (
                        inst = Dict(w["program"]["prog_list"][6]);
                        inst["ADDR"] = "&9";
                        w["program"]["prog_list"][6] = inst;
                        w
                    ),
                ),
                "wave 10",
            ),
            # the acquire block lying about the sweep axis
            (
                mutate(
                    w -> (w["acquire"] = merge(Dict(w["acquire"]), Dict("expts" => 10)); w),
                ),
                "expts=10",
            ),
            # an acquire readout the program never declared
            (
                mutate(
                    w -> (
                        w["acquire"] = merge(Dict(w["acquire"]), Dict("ro_chs" => [7]));
                        w
                    ),
                ),
                "readout channels [7]",
            ),
            # reads_per_shot disagreeing with the program's trigger count
            (
                mutate(
                    w -> (
                        w["acquire"] = merge(
                            Dict(w["acquire"]),
                            Dict("reads_per_shot" => [2]),
                        );
                        w
                    ),
                ),
                "reads_per_shot",
            ),
            # avg_level outside the loop structure
            (
                mutate(
                    w -> (
                        w["program"] = merge(Dict(w["program"]), Dict("avg_level" => 3));
                        w
                    ),
                ),
                "avg_level 3",
            ),
        ]
        for (wire, needle) in cases
            err = try
                ext.read_payload(soccfg, wire);
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin(needle, sprint(showerror, err))
        end
    end
end
