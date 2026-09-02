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
qick's own dump pairing) and the CloseLoop sweep ladder (see below), never
interpreted for control flow."""
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
    sweep_ladder::Vector{Tuple{Int,String,Int}} # (wave idx 1-based, field, per-expt step)
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

# The CloseLoop sweep ladder (qick's encoding-A form): read_wmem → wave-field
# increments → write_wmem, compiled INSIDE the expts loop. Reading it is static
# DATA extraction — the literal per-expt step the payload carries — never tProc
# register simulation (the expts AXIS still rides the declared loop structure;
# the ladder only carries the per-expt VALUES). Wave-field registers are qick's
# own map (QickProgramV2.REG_ALIASES): w0 freq, w1 phase, w2 env, w3 gain,
# w4 length, w5 conf.
#
# Anchoring: qick emits the ladder before the expts loop's back-edge (a
# TEST/JUMP-IF-NZ pair whose literal counter is the expts count − 1 — checked
# against the DECLARED axis, a consistency check, not a simulation), and a
# restore ladder AFTER it (the compiler leaving wave memory as it found it,
# once per reps iteration — invisible to the v1 response model, which batches
# reps × soft_avgs into one accumulated draw). Only the IN-LOOP ladder
# realizes per-expt steps; out-of-loop blocks are decoded and validated but
# not realized.
const _WAVE_FIELDS = Dict("w0" => "freq", "w1" => "phase", "w2" => "env",
                          "w3" => "gain", "w4" => "length", "w5" => "conf")

# One ladder block: (wave idx 1-based, [(field, step)...], write P_ADDR).
function _ladder_block(insts, i::Int, n_waves::Int)
    inst = insts[i]
    addr = get(inst, "ADDR", nothing)
    addr isa AbstractString && startswith(addr, "&") || error(
        "read_payload: a wave-memory read (r_wave) carries ADDR $(repr(addr)) — " *
        "the CloseLoop ladder's form is REG_WR r_wave SRC=wmem ADDR=\"&<index>\"")
    widx = parse(Int, addr[2:end]) + 1        # the wave-table index, 1-based
    1 ≤ widx ≤ n_waves || error(
        "read_payload: the sweep ladder references wave $widx but the wave table " *
        "holds $n_waves")
    steps = Tuple{String,Int}[]
    j = i + 1
    while j ≤ length(insts) && get(insts[j], "CMD", "") != "WMEM_WR"
        nxt = insts[j]
        get(nxt, "CMD", "") == "REG_WR" || error(
            "read_payload: an instruction inside the CloseLoop ladder is not a " *
            "wave-field increment (CMD $(repr(get(nxt, "CMD", nothing)))) — v1 " *
            "decodes the read → increment → write block")
        dst = string(get(nxt, "DST", ""))
        haskey(_WAVE_FIELDS, dst) || error(
            "read_payload: the sweep ladder increments $(repr(dst)) — not a " *
            "wave-field register (qick's map: freq/phase/env/gain/length/conf)")
        op = string(get(nxt, "OP", ""))
        m = match(r"^(\w+) ([+-]) #(-?\d+)$", op)
        (m !== nothing && String(m[1]) == dst) || error(
            "read_payload: the sweep ladder's increment on $(repr(dst)) carries " *
            "OP $(repr(op)) — v1 decodes literal steps (\"w<k> ± #<step>\"), " *
            "not register arithmetic")
        push!(steps, (_WAVE_FIELDS[dst], (m[2] == "+" ? 1 : -1) * parse(Int, m[3])))
        j += 1
    end
    j ≤ length(insts) || error(
        "read_payload: a wave-memory read (r_wave) is never written back — the " *
        "CloseLoop ladder's form is read → increments → WMEM_WR")
    string(get(insts[j], "DST", "")) == "&$(widx - 1)" || error(
        "read_payload: the sweep ladder reads wave $widx but writes " *
        "$(repr(get(insts[j], "DST", nothing))) — the read and the write must " *
        "target the same wave-table entry")
    return (widx, steps, Int(get(insts[j], "P_ADDR", j)))
end

function _sweep_ladder(program::AbstractDict, n_waves::Int, expts::Union{Nothing,Int})
    insts = program["prog_list"]
    has_ladder = any(i -> get(i, "CMD", "") == "REG_WR" &&
                          get(i, "DST", "") == "r_wave" && get(i, "SRC", "") == "wmem",
                     insts) ||
                 any(i -> get(i, "CMD", "") == "WMEM_WR", insts)
    isempty_any = !has_ladder
    isempty_any && return Tuple{Int,String,Int}[]
    # the expts loop's back-edge anchors the ladder split: the TEST whose
    # literal counter is the DECLARED expts count − 1, followed by a
    # conditional JUMP (the loop's increment-carrying back-edge)
    expts isa Integer || error(
        "read_payload: the payload carries a CloseLoop sweep ladder but declares " *
        "no expts axis — a sweep needs a loop to ride")
    back_edge = 0
    for (i, inst) in enumerate(insts)
        get(inst, "CMD", "") == "TEST" || continue
        m = match(r"^r\d+ - #(\d+)$", string(get(inst, "OP", "")))
        m !== nothing && parse(Int, m[1]) == expts - 1 || continue
        i < length(insts) && get(insts[i+1], "CMD", "") == "JUMP" &&
            haskey(insts[i+1], "IF") || continue
        back_edge == 0 || error(
            "read_payload: $back_edge-plus back-edges carry the expts counter " *
            "#$(expts - 1) — the expts loop is not uniquely identifiable")
        back_edge = Int(get(inst, "P_ADDR", i))
    end
    back_edge > 0 || error(
        "read_payload: the payload carries a CloseLoop sweep ladder but no expts " *
        "back-edge (TEST against #$(expts - 1) + conditional JUMP) — the sweep " *
        "block cannot be located in the compiled program")
    blocks = Tuple{Int,Vector{Tuple{String,Int}},Int}[]
    for (i, inst) in enumerate(insts)
        get(inst, "CMD", "") == "REG_WR" || continue
        get(inst, "DST", "") == "r_wave" || continue
        get(inst, "SRC", "") == "wmem" || continue
        push!(blocks, _ladder_block(insts, i, n_waves))
    end
    # every wave-memory write must belong to a decoded ladder — an orphan
    # WMEM_WR mutates the wave table in a way v1 does not model
    write_paddrs = Set{Int}(b[3] for b in blocks)
    for (i, inst) in enumerate(insts)
        get(inst, "CMD", "") == "WMEM_WR" || continue
        Int(get(inst, "P_ADDR", i)) in write_paddrs || error(
            "read_payload: a wave-memory write (WMEM_WR) sits outside the decoded " *
            "CloseLoop ladder — v1 models the read → increment → write form only")
    end
    ladder = Tuple{Int,String,Int}[]
    seen_waves = Int[]
    for (widx, steps, write_paddr) in blocks
        write_paddr < back_edge || continue    # the restore ladder: not realized
        widx in seen_waves && error(
            "read_payload: the sweep ladder writes wave $widx twice inside the " *
            "expts loop — v1 decodes one ladder per wave")
        push!(seen_waves, widx)
        for (field, step) in steps
            push!(ladder, (widx, field, step))
        end
    end
    # v1 realizes GAIN steps only (the swept-amp form); anything else is named
    for (widx, field, step) in ladder
        field == "gain" || error(
            "read_payload: the sweep ladder steps wave $widx's $field — v1 realizes " *
            "gain steps only (the swept-amp form)")
    end
    return ladder
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
axis removed. The per-expt VALUES ride the CloseLoop ladder when the payload
carries one (`_sweep_ladder`): qick's encoding-A sweep block (read_wmem →
literal wave-field increments → write_wmem) is static data in the payload,
decoded — not register-simulated — into per-expt wave-field steps.
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
    # ── the CloseLoop sweep ladder (per-expt wave-field steps) ──
    ladder = _sweep_ladder(program, length(waves), derived_expts)
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
        ladder,
    )
end

# ──── The envelope-level translation ─────────────────────────────────────────
# The analog drive the DEVICE would play, reconstructed from the wave table:
# envelope samples scaled from DAC codes, gain applied per wave, the carrier
# phase rotated into the baseband quadratures, the carrier frequency validated
# against the declared Nyquist zone and carried as the frame definition.

"""One generator channel's reconstructed drive: the baseband quadrature
waveforms `uI`/`uQ` on the DAC-grid `times` (seconds), and the per-segment
`carriers_MHz` (validated, carried as the drive's frame definition — see the
module docstring for the v1 boundary)."""
struct GenDrive
    times::Vector{Float64}
    uI::Vector{Float64}
    uQ::Vector{Float64}
    carriers_MHz::Vector{Float64}
end

# The envelope segment a wave plays: wave.env is the envelope word address
# (samples // samps_per_clk); the wave plays `length` fabric cycles of the
# page that holds that address, starting at the word offset. flat_top's
# ramp-down (env pointing into the same page, later) resolves the same way.
function _wave_segment(payload::WirePayload, gen_ch::Int, wave::WireWave)
    facts = payload.gen_cfg[gen_ch]
    spc = facts.samps_per_clk
    nsamp = wave.length_cycles * spc
    nsamp > 0 || error(
        "translate_drive: wave $(repr(wave.name)) has length $(wave.length_cycles) " *
        "cycles — a played wave must have positive extent",
    )
    want_word = wave.env_addr
    for page in payload.envelopes[gen_ch]
        word_addr = page.addr ÷ spc
        word_end = (page.addr + length(page.idata)) ÷ spc
        word_addr <= want_word < word_end || continue
        off = (want_word * spc - page.addr) + 1        # 1-based sample offset into the page
        off + nsamp - 1 ≤ length(page.idata) || error(
            "translate_drive: wave $(repr(wave.name)) plays $nsamp samples " *
            "($((wave.length_cycles)) cycles x $spc) from envelope word $want_word " *
            "but page $(repr(page.name)) (addr $(page.addr), $(length(page.idata)) " *
            "samples) does not reach that far — the wave outruns its envelope",
        )
        return view(page.idata, off:(off+nsamp-1)), view(page.qdata, off:(off+nsamp-1))
    end
    return error(
        "translate_drive: wave $(repr(wave.name)) references envelope word " *
        "$(wave.env_addr) on generator $gen_ch but the payload's pages for that " *
        "channel hold no segment there — the wave table and the envelopes disagree",
    )
end

"""
    translate_drive(payload; expt = 1) -> Dict{gen_ch => GenDrive}

Reconstruct the analog drive per generator channel, at the envelope level, for
experiment point `expt` (1-based — the expts axis realized from the declared
loop structure).

Per wave (in the port plan's play order): the envelope segment is scaled from
DAC codes to fractions of full scale (`code/maxv`), the gain is applied as the
amplitude scale (`gain_code/maxv` — qick's "gain: −1.0 to 1.0 relative to max
amplitude"), the carrier phase rotates the baseband quadratures, and the
segments concatenate in play order (the flat-top shape; inter-wave TIMING is
the tProc's — control flow, the complementary lane). `outsel` is honored per
qick's cfg2reg semantics: "product" (envelope × gain, the DDS applied as the
frame), "dds" (a constant drive at the gain, no envelope — the const-pulse
path), "input" (the envelope's real part × gain), "zero" (silence for the
wave's extent).

The CloseLoop ladder (when the payload carries one) offsets the stepped wave's
gain code by `step × (expt − 1)` — the per-expt drive variation the compiled
sweep declares, decoded in `read_payload`. A payload with no ladder replays
the identical assignment for every `expt`.

The carrier frequency is validated against the declared Nyquist zone and
carried as the drive's frame definition. The v1 boundary (module docstring):
the twin's family systems are rotating-frame models at the drive frequency, so
the carrier enters the response as the frame; a family that carries absolute
transition frequencies would need the detuning, which is future record
surface, not v1.
"""
function translate_drive(payload::WirePayload; expt::Integer = 1)
    expt ≥ 1 || error("translate_drive: expt must be ≥ 1 (got $expt)")
    drives = Dict{Int,GenDrive}()
    for (gen_ch, wave_idxs) in payload.port_plan
        facts = payload.gen_cfg[gen_ch]
        uI_all = Float64[]
        uQ_all = Float64[]
        carriers = Float64[]
        for idx in wave_idxs
            wave = payload.waves[idx]
            # this expt's gain code: the wave-table value plus the CloseLoop
            # ladder's per-expt offsets (identical for every expt when absent)
            gain_code = wave.gain_code
            for (widx, field, step) in payload.sweep_ladder
                widx == idx && field == "gain" && (gain_code += step * (expt - 1))
            end
            # the Nyquist-zone band check (qick's freq2reg range contract)
            f = wave.freq_MHz
            fs = facts.f_dds_MHz
            band = facts.nqz == 1 ? (0.0, fs / 2) : (fs / 2, fs)
            (band[1] ≤ f ≤ band[2]) || error(
                "translate_drive: wave $(repr(wave.name)) decodes to $f MHz but " *
                "generator $gen_ch declares Nyquist zone $(facts.nqz) " *
                "($(band[1])–$(band[2]) MHz) — the DDS code does not land in the " *
                "declared zone",
            )
            push!(carriers, f)
            g = gain_code / facts.maxv
            nsamp = wave.length_cycles * facts.samps_per_clk
            if wave.outsel == "dds"
                φ = deg2rad(wave.phase_deg)
                append!(uI_all, fill(g * cos(φ), nsamp))
                append!(uQ_all, fill(g * sin(φ), nsamp))
            elseif wave.outsel == "zero"
                append!(uI_all, zeros(nsamp))
                append!(uQ_all, zeros(nsamp))
            else
                idata, qdata = _wave_segment(payload, gen_ch, wave)
                φ = deg2rad(wave.phase_deg)
                scale = 1.0 / facts.maxv
                if wave.outsel == "input"
                    append!(uI_all, g .* scale .* idata)
                    append!(uQ_all, zeros(nsamp))
                else   # "product": envelope x gain, the phase rotated in
                    c, s = cos(φ), sin(φ)
                    append!(uI_all, g .* scale .* (c .* idata .- s .* qdata))
                    append!(uQ_all, g .* scale .* (s .* idata .+ c .* qdata))
                end
            end
        end
        isempty(uI_all) && error(
            "translate_drive: generator $gen_ch has a port plan but no wave " *
            "segments — the drive reconstruction produced nothing",
        )
        dt = 1.0 / facts.fs_hz
        times = collect(0.0:dt:((length(uI_all)-1)*dt))
        drives[gen_ch] = GenDrive(times, uI_all, uQ_all, carriers)
    end
    return drives
end

# ──── The server: a soc-level actor over one twin face ───────────────────────

# The twin's soc type, reached LAZILY: it is defined by the sibling Piccolo
# extension, and extension load order between siblings is not guaranteed —
# the reach happens at construction time, when both triggers are loaded.
_twinsoc_type() = begin
    ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
    ext === nothing && error(
        "TwinJobServer: the twin soc type is not loaded — it is defined by " *
        "StrumentoPiccoloExt (load Piccolo together with JSON to attach " *
        "this extension's triggers)")
    return ext.TwinSoc
end

"""
    TwinJobServer(soc, soccfg; overlay_id="", overlays=(), dt=0.0)

A board-shaped job server fronting one `TwinSoc` (the twin face: family
system from the twin's truth, the record's readout confusion, binomial shot
sampling, the twin's own seeded rng). `soccfg` is the overlay's `dump_cfg()`
snapshot (a parsed JSON dict) — one overlay ⇔ one snapshot (D25), so the
server can decode a payload's envelope addressing and DDS codes. `overlay_id`
names the personality this board serves; `overlays` (when non-empty) is the
board's catalog — a named overlay outside it is a failed job, not a guess. `dt`
is the twin-time (days) advanced AFTER each job: the server is a soc-level
actor that serves many jobs against one twin, and the drift advances ACROSS
jobs — job *k* measures truth aged `(k-1)·dt`. Construct the soc with its own
per-acquire `dt = 0` and let the server own the clock.

Execution (see `execute_job`): read → translate → the soc's own
load/play/acquire path (the same seeded-response machinery, drift included)
→ the `RawAcquisition` wire form.
"""
mutable struct TwinJobServer
    soc                            # the TwinSoc (validated at construction)
    soccfg                         # the overlay's dump_cfg() snapshot (parsed JSON)
    overlay_id::String
    overlays::Tuple{Vararg{String}}
    dt::Float64
    jobs::Dict{String,Dict{String,Any}}   # job id => its record (status + payload)
    queue::Vector{String}                 # pending ids, FIFO — one worker owns the board
    n::Int                                # the next job id
end

function TwinJobServer(soc, soccfg::AbstractDict;
                       overlay_id::AbstractString = "",
                       overlays::Tuple{Vararg{String}} = (),
                       dt::Real = 0.0)
    TwinSocT = _twinsoc_type()
    soc isa TwinSocT || error(
        "TwinJobServer: the soc must be a TwinSoc (got $(typeof(soc))) — the " *
        "server fronts the twin face (family + confusion + seeded response)")
    dt ≥ 0 || error(
        "TwinJobServer: dt must be ≥ 0 — twin-time only runs forward (got $dt)")
    return TwinJobServer(soc, soccfg, String(overlay_id), overlays, Float64(dt),
                         Dict{String,Dict{String,Any}}(), String[], 0)
end

# The overlay personality (D25: one overlay ⇔ one snapshot). "" means whatever
# is loaded — the single-personality case; a named overlay this board does
# not have is a failed job (running a program compiled against a different
# soccfg is exactly the class of error the 1:1 rule exists to prevent).
function _select_overlay(server::TwinJobServer, overlay_id::AbstractString)
    (overlay_id == "" || overlay_id == server.overlay_id) && return nothing
    if !isempty(server.overlays) && overlay_id ∉ server.overlays
        error(
            "TwinJobServer: overlay $(repr(overlay_id)) is not available on this " *
            "board (have: $(isempty(server.overlays) ?
                "any (single-personality)" : join(server.overlays, ", ")))")
    end
    error(
        "TwinJobServer: job asks for overlay $(repr(overlay_id)) but this " *
        "server serves $(repr(server.overlay_id)) — one overlay is one soccfg " *
        "snapshot (D25); refusing to run a program against a different snapshot")
end

"""
    execute_job(server, job_wire) -> Dict   # the RawAcquisition wire form

Run one `CompiledJob` wire dict through the twin face and shape the response
per the acquire block: `{"iq" => [per readout channel]}` where each channel's
array is `(n_reads, [expts,] 2)` IQ — JSON-safe lists all the way down.

The execution path, per experiment point: the translated drive is loaded into
the soc (its own `load_envelope!`/`play_program!` verbs) and acquired (its own
`acquire` — the rollout over the family system built from the twin's CURRENT
truth, the record's confusion remap, the twin's seeded binomial shots). The
readout samples the state at the END of the played drive (the trigger
schedule is the tProc's lane — control flow, the complementary boundary).

Conventions this path owns (documented, the honest v1):

- **Quantum time.** The wire grid is seconds; the twin families speak quantum
  time in nanoseconds (the bosonic builder's unit table: rad·GHz ↔ ns rollout
  time; Piccolo's convention). The server hands the soc the DAC grid in ns —
  construct the soc with `dac_rate = fs` in samples PER NS.
- **Amplitude scale.** The wire's drive is a fraction of DAC full scale
  (envelope code × gain code, each over `maxv`); the v1 server passes that
  fraction to the family AS the drive coefficient in the family's own quantum
  units — full scale is 1.0 family unit (the toy's `drive_bound`). A
  calibrated rad/ns-per-full-scale mapping is future record surface, not v1.
- **Averaging depth.** The acquire block's `reps × soft_avgs` is the
  accumulated-buffer statistic: one rollout per (read, expt), with the shot
  draws batched to `soc.shots × reps × soft_avgs` — the sum over rounds of
  per-round counts over the total, exactly what an accumulating readout
  computes. All draws come from the twin's single seeded rng.
- **The IQ packing.** The twin's v1 response blob is the confusion-remapped
  outcome-frequency vector; a 2-outcome readout packs its two frequencies
  into the wire's `(I, Q)` slots in level order (lossless, invertible — the
  IQ-plane-per-state readout model is future record surface).
- **The expts axis.** Realized from the payload's declared loop structure
  (`loop_dims` minus the averaged axis); per-expt drive variation rides the
  payload's CloseLoop ladder (see `read_payload`) when it carries one.
- **The wire form.** Each channel's IQ is JSON-safe nested lists shaped
  `(n_reads, [expts,] 2)` — the expts level ABSENT when the payload declares
  no sweep — exactly what Python's `RawAcquisition.to_wire` (`.tolist()`)
  puts on the wire and its `from_wire` (`np.asarray`) reconstructs.
"""
function execute_job(server::TwinJobServer, job_wire::AbstractDict)
    _select_overlay(server, String(get(job_wire, "overlay_id", "")))
    payload = read_payload(server.soccfg, job_wire)
    # the v1 response model serves one readout channel (the record's single
    # confusion); a multi-channel board is future twin surface
    length(payload.ro_chs) == 1 || error(
        "execute_job: the acquire block declares $(length(payload.ro_chs)) readout " *
        "channels but the twin's v1 response model serves one (the record's " *
        "readout_confusion is a single readout's model)")
    n_reads = payload.reads_per_shot[1]
    n_reads ≥ 1 || error("execute_job: reads_per_shot must be ≥ 1 (got $n_reads)")
    expts = payload.expts === nothing ? 1 : payload.expts
    # per-expt rollout values, packed into the wire form at the end
    vals = Array{Float64}(undef, n_reads, expts, 2)

    # the averaging depth: reps x soft_avgs rounds of the soc's own shot
    # count, batched into one accumulated draw — the buffer statistic
    soc = server.soc
    shots_base = soc.shots
    try
        soc.shots = shots_base * payload.reps * payload.soft_avgs
        for e in 1:expts
            # this expt's drive: the same wave-table assignment replayed, with
            # the CloseLoop ladder's per-expt field offsets when the payload
            # carries one (all expts identical when it does not)
            drives = translate_drive(payload; expt = e)
            nsamp = maximum(length(d.times) for d in values(drives))
            gen_chs = sort(collect(keys(drives)))
            times = [1e9 * (i - 1) / payload.gen_cfg[gen_chs[1]].fs_hz for i in 1:nsamp]
            envelopes = Dict{Int,Tuple{Vector{Float64},Vector{Float64}}}()
            carriers = Dict{Int,Float64}()
            routing = Tuple{Int,Int,Union{Int,Nothing}}[]
            for (k, gen_ch) in enumerate(gen_chs)
                d = drives[gen_ch]
                pad = zeros(nsamp - length(d.times))
                envelopes[gen_ch] = (vcat(d.uI, pad), vcat(d.uQ, pad))
                carriers[gen_ch] = isempty(d.carriers_MHz) ? 0.0 : d.carriers_MHz[end]
                push!(routing, (gen_ch, 2k - 1, 2k))
            end
            program = QickProgram(times, envelopes, carriers, routing,
                                   2 * length(gen_chs), [nsamp])
            for (gen_ch, (uI, uQ)) in envelopes
                load_envelope!(soc, gen_ch, uI, uQ)
            end
            play_program!(soc, program)
            for r in 1:n_reads
                blob = acquire(soc, Int[])[1]   # one measurement index: the drive's end
                length(blob) == 2 || error(
                    "execute_job: the twin's response blob has $(length(blob)) " *
                    "outcomes but the wire's IQ slot is 2 wide — the v1 packing " *
                    "serves 2-outcome readouts (the record's confusion shape)")
                vals[r, e, 1] = real(blob[1])
                vals[r, e, 2] = real(blob[2])
            end
        end
    finally
        soc.shots = shots_base
    end
    # the soc-level actor's clock: drift advances ACROSS jobs, once per job
    server.dt > 0 && advance!(soc.twin, server.dt)
    # the RawAcquisition wire form: (n_reads, [expts,] 2) as JSON-safe nested
    # lists, one level per declared axis — the expts level ABSENT when the
    # payload declares no sweep (the Python client's np.asarray reconstructs
    # exactly these two shapes)
    iq = if payload.expts === nothing
        [[vals[r, 1, 1], vals[r, 1, 2]] for r in 1:n_reads]
    else
        [[[vals[r, e, 1], vals[r, e, 2]] for e in 1:expts] for r in 1:n_reads]
    end
    return Dict{String,Any}("iq" => Any[iq])
end

# ──── The job queue — the reference agent's shape (examples/jobserver) ───────
# submit enqueues; a poll is the single worker's turn (one board, one worker —
# hardware exclusivity is structural); the status dicts are exactly what the
# Python JobServerClient promises: {"status": "pending"} while queued,
# {"status": "done", "acquisition": {...}} on success, {"status": "error",
# "error": "..."} on failure. A failed job never takes the server down.

"TwinJobServer error strings mirror the reference agent's `{type}: {message}`."
_error_string(err) = err isa ErrorException ? string("ErrorException: ", err.msg) :
                     sprint(showerror, err)

"""    submit!(server, job_wire) -> String

Enqueue one `CompiledJob` wire dict; returns its job id (incrementing strings,
the reference agent's ids)."""
function submit!(server::TwinJobServer, job_wire::AbstractDict)
    id = string(server.n)
    server.n += 1
    server.jobs[id] = Dict{String,Any}("status" => "pending", "job" => job_wire)
    push!(server.queue, id)
    return id
end

"""    poll(server, job_id) -> Dict

The status dict for one job: pending (running the worker's turn first — a poll
is when the single worker gets its turn, the reference agent's discipline),
done with its `acquisition`, or error with the message. An unknown id is an
error dict, not an exception."""
function poll(server::TwinJobServer, job_id::AbstractString)
    haskey(server.jobs, job_id) || return Dict{String,Any}(
        "status" => "error", "error" => "unknown job \"$(job_id)\"")
    record = server.jobs[job_id]
    record["status"] == "pending" && work!(server)
    return Dict{String,Any}(k => v for (k, v) in record if k != "job")
end

"""    work!(server) -> Union{String,Nothing}

Run the job at the head of the queue (FIFO). Returns its id, or `nothing` when
idle. A failed job records `{"status": "error", "error": ...}` and the server
keeps serving."""
function work!(server::TwinJobServer)
    isempty(server.queue) && return nothing
    job_id = popfirst!(server.queue)
    record = server.jobs[job_id]
    try
        acquisition = execute_job(server, record["job"])
        record["status"] = "done"
        record["acquisition"] = acquisition
    catch err
        record["status"] = "error"
        record["error"] = _error_string(err)
    end
    return job_id
end

# ──── The HTTP layer — stdlib Sockets, the two wire routes ───────────────────
# POST /jobs  body = the CompiledJob wire JSON  -> {"job_id": "..."}
# GET  /jobs/<id>  -> the status dict (404 on unknown ids)
# One request per connection, HTTP/1.1, JSON bodies; a malformed connection or
# a failed job never takes the accept loop down.

"""The handle `serve_http` returns: the listener, its accept task, and the
server it fronts. `stop_http` closes the listener and joins the task."""
mutable struct TwinJobHttp
    server::TwinJobServer
    listener::Sockets.TCPServer
    task::Task
    host::IPAddr
    port::UInt16
end

"""    serve_http(server; host = ip"127.0.0.1", port = 0) -> TwinJobHttp

Serve the twin job server over HTTP — the wire protocol the Python
`JobServerClient`'s deployment speaks (two routes, one request per
connection). `port = 0` (the default) binds an ephemeral port; read the real
address with `http_address`. The accept loop runs in an `@async` task; each
connection is handled independently (a bad request costs its own connection,
never the server)."""
function serve_http(server::TwinJobServer; host::IPAddr = ip"127.0.0.1",
                    port::Integer = 0)
    tcp = listen(host, port)
    _, bound_port = getsockname(tcp)
    task = @async begin
        try
            while isopen(tcp)
                sock = accept(tcp)
                @async begin
                    try
                        _handle_connection(server, sock)
                    catch err           # a broken connection is that connection's problem
                        try
                            close(sock)
                        catch
                        end
                    end
                end
            end
        catch err                     # the listener closed (stop_http) or died
            isopen(tcp) && rethrow(err)
        end
    end
    return TwinJobHttp(server, tcp, task, host, UInt16(bound_port))
end

"`serve_http`'s bound address (the host it was asked for, the port actually bound)."
http_address(http::TwinJobHttp) = (http.host, Int(http.port))

"""    stop_http(http)

Close the listener and join the accept task. Queued jobs stay pending — a
stopped server is a stopped board; draining the queue is the operator's act."""
function stop_http(http::TwinJobHttp)
    close(http.listener)
    istaskdone(http.task) || wait(http.task)
    return nothing
end

function _handle_connection(server::TwinJobServer, sock)
    request = readline(sock)                       # "METHOD /path HTTP/1.1"
    parts = split(request; limit = 3)
    length(parts) == 3 && return _route_request(server, sock, String(parts[1]),
                                                String(parts[2]))
    return _respond_close!(sock, 400, Dict(
        "error" => "malformed request line $(repr(request))"))
end

function _route_request(server::TwinJobServer, sock, method::String, path::String)
    content_length = 0
    while (line = readline(sock)) != ""            # headers, then the blank line
        m = match(r"^Content-Length:\s*(\d+)\s*$"i, line)
        m === nothing || (content_length = parse(Int, m[1]))
    end
    body = content_length > 0 ? String(read(sock, content_length)) : ""
    if method == "POST" && path == "/jobs"
        job = try
            JSON.parse(body)
        catch err
            return _respond_close!(sock, 400, Dict(
                "error" => "the request body is not valid JSON ($(sprint(showerror, err)))"))
        end
        job isa AbstractDict || return _respond_close!(sock, 400, Dict(
            "error" => "the request body must be a JSON object (the CompiledJob wire form)"))
        return _respond_close!(sock, 200, Dict("job_id" => submit!(server, job)))
    elseif method == "GET" && (m = match(r"^/jobs/([^/]+)$", path)) !== nothing
        job_id = String(only(m.captures))
        # a failed job is still a KNOWN job (200, the error rides the status
        # dict); an unknown id is 404 — the deployment mapping the module
        # docstring promises
        return _respond_close!(sock, haskey(server.jobs, job_id) ? 200 : 404,
                               poll(server, job_id))
    end
    return _respond_close!(sock, 404, Dict(
        "error" => "no route $(repr(method)) $(repr(path)) — the wire protocol is " *
                   "POST /jobs and GET /jobs/<id>"))
end

function _respond_close!(sock, status::Int, body::AbstractDict)
    _respond!(sock, status, body)
    close(sock)                       # Connection: close — one request per connection
    return nothing
end

function _respond!(sock, status::Int, body::AbstractDict)
    payload = JSON.json(body)
    reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Not Found"
    write(sock, "HTTP/1.1 $status $reason\r\n" *
                "Content-Type: application/json\r\n" *
                "Content-Length: $(sizeof(payload))\r\n" *
                "Connection: close\r\n\r\n" * payload)
    return nothing
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

@testitem "translate_drive reconstructs the analog drive from the wave table" begin
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
        nosweep = JSON.parsefile(joinpath(fixtures, "compiled_job_nosweep.json"))

        # ── the golden: a zero-gain sweep start — the drive is identically zero
        # (the wave-table assignment is the envelope-level truth), 1152 samples
        # on the DAC grid (72 fabric cycles x 16 samples per cycle at fs 9.58464 GHz).
        drive = ext.translate_drive(ext.read_payload(soccfg, golden))
        @test length(drive) == 1
        g0 = drive[0]
        @test length(g0.times) == 1152
        @test g0.times[2] - g0.times[1] ≈ 1 / 9.58464e9
        @test all(iszero, g0.uI) && all(iszero, g0.uQ)

        # ── the no-sweep variant: the calibration pi pulse at gain 8192 — a
        # real drive. DAC-code normalization: (env/maxv) x (gain/maxv), so the
        # gaussian peaks at 8192/32766 ≈ 0.25 of full scale, Q identically 0
        # (the fixture's envelope is I-only), and the SHAPE follows the page.
        drive_pi = ext.translate_drive(ext.read_payload(soccfg, nosweep))
        gpi = drive_pi[0]
        @test length(gpi.times) == 1152
        peak = maximum(gpi.uI)
        @test peak ≈ (32766 / 32766) * (8192 / 32766) atol = 1e-12
        @test all(iszero, gpi.uQ)
        # the page's own samples, scaled: the drive IS the envelope (product outsel)
        payload = ext.read_payload(soccfg, nosweep)
        page = payload.envelopes[0][1]
        @test gpi.uI ≈ page.idata .* (8192 / 32766) / 32766
        # the carrier is carried as the frame definition (validated, not applied:
        # the v1 families are rotating-frame models — see the module docstring)
        @test length(gpi.carriers_MHz) == 1
        @test gpi.carriers_MHz[1] ≈ 4000.0 atol = 1e-3

        # ── the carrier phase rotates the baseband: phase 90 deg on an I-only
        # envelope moves the drive entirely into the Q quadrature.
        rotated = deepcopy(nosweep)
        w = Dict(rotated["program"]["waves"][1])
        w["phase"] = round(Int, 2^32 / 4)          # 90 degrees in phase-register codes
        rotated["program"]["waves"][1] = w
        gro = ext.translate_drive(ext.read_payload(soccfg, rotated))[0]
        @test all(x -> abs(x) < 1e-15, gro.uI)      # cos(π/2) residue only
        @test gro.uQ ≈ gpi.uI

        # ── outsel "dds" (the const-pulse path): no envelope — a constant drive
        # at the gain, for the wave's length in fabric cycles.
        dds = deepcopy(nosweep)
        w = Dict(dds["program"]["waves"][1])
        w["conf"] = 8 + 1                            # stdysel zero | oneshot | outsel dds
        dds["program"]["waves"][1] = w
        gdds = ext.translate_drive(ext.read_payload(soccfg, dds))[0]
        @test length(gdds.times) == 1152
        @test all(≈(8192 / 32766), gdds.uI)
        @test all(iszero, gdds.uQ)

        # ── multi-wave programs: the port plan concatenates the channel's
        # waves in play order (the flat-top shape; inter-wave TIMING is the
        # tProc's, the sequence is the wave table's).
        two = deepcopy(nosweep)
        push!(two["program"]["waves"], deepcopy(two["program"]["waves"][1]))
        wport = findfirst(i -> get(i, "CMD", "") == "WPORT_WR", two["program"]["prog_list"])
        inst = Dict(two["program"]["prog_list"][wport])
        inst["ADDR"] = "&1"
        push!(two["program"]["prog_list"], inst)
        gtwo = ext.translate_drive(ext.read_payload(soccfg, two))[0]
        @test length(gtwo.times) == 2304
        @test gtwo.uI[1:1152] ≈ gpi.uI
        @test gtwo.uI[1153:2304] ≈ gpi.uI

        # ── a wave whose declared length outruns its envelope page is named.
        overrun = deepcopy(nosweep)
        w = Dict(overrun["program"]["waves"][1])
        w["length"] = 200
        overrun["program"]["waves"][1] = w
        err = try
            ext.translate_drive(ext.read_payload(soccfg, overrun));
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("3200", sprint(showerror, err))      # 200 cycles x 16 samples

        # ── a frequency outside the declared Nyquist zone is refused.
        oob = deepcopy(nosweep)
        w = Dict(oob["program"]["waves"][1])
        w["freq"] = round(Int, 0.9 * 2^32)                # ~8.6 GHz in zone 1
        oob["program"]["waves"][1] = w
        err = try
            ext.translate_drive(ext.read_payload(soccfg, oob));
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("Nyquist", sprint(showerror, err))
    end
end

@testitem "execute_job runs the wire payload through the twin face and shapes RawAcquisition" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (job-server extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using LinearAlgebra
        ext = Base.get_extension(Strumento, :StrumentoJobServerExt)
        TwinSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).TwinSoc
        using Strumento: DriftPlan, instantiate, OrnsteinUhlenbeck
        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
        soccfg = JSON.parsefile(joinpath(fixtures, "soccfg_v2_testbench.json"))
        golden = JSON.parsefile(joinpath(fixtures, "compiled_job_golden.json"))
        nosweep = JSON.parsefile(joinpath(fixtures, "compiled_job_nosweep.json"))
        toy = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "toy.md")

        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        toy_family(truth) =
            QuantumSystem(truth[:omega] * σz, [σx, σx], [truth[:drive_bound], truth[:drive_bound]])
        # wire service: the soc speaks the families' quantum time (ns), so its
        # dac_rate is the generator's fs in samples PER NS (9584.64 MHz -> 9584.64/ns)
        soc(exact) = TwinSoc(instantiate(toy; drift = DriftPlan(), seed = 0xC0FFEE),
                             ComplexF64[1, 0], ComplexF64[0, 1];
                             families = Dict("toy" => toy_family), exact = exact,
                             dac_rate = 9584.64)

        server = ext.TwinJobServer(soc(true), soccfg; overlay_id = "testbench-v2")

        # ── the golden: 11 expts x 1 read x 2, the gain-0 drive leaving the
        # qubit in |g> — the exact confused response is the record's first
        # confusion column (semantic, computed from the record — no captures).
        out = ext.execute_job(server, golden)
        @test sort!(collect(keys(out))) == ["iq"]
        @test length(out["iq"]) == 1                       # one readout channel
        ch = out["iq"][1]
        # the wire form: (n_reads, expts, I/Q) as JSON-safe nested lists
        @test length(ch) == 1 && length(ch[1]) == 11 && all(v -> length(v) == 2, ch[1])
        C = [0.98 0.02; 0.04 0.96]                          # the toy record's confusion
        for e in 1:11
            @test ch[1][e][1] ≈ C[1, 1] atol = 1e-12   # |g> in: the confusion ROW is the outcome distribution
            @test ch[1][e][2] ≈ C[1, 2] atol = 1e-12
        end
        # JSON-safe all the way down (the wire contract)
        @test JSON.parse(JSON.json(out)) == out

        # ── the no-sweep variant: no expts axis — (n_reads, 2)
        out_ns = ext.execute_job(server, nosweep)
        ch_ns = out_ns["iq"][1]
        @test length(ch_ns) == 1 && length(ch_ns[1]) == 2     # (n_reads, I/Q), no expts level
        @test sum(ch_ns[1]) ≈ 1.0 atol = 1e-9
        # the pi pulse MOVED the state: more excited-state frequency than the
        # gain-0 golden's pure-|g⟩ confusion row (semantic scale, never a
        # captured literal). The toy's ω = 1.0 rad/ns drift detunes the wire's
        # fractional drive (peak 0.25 of full scale — the v1 amplitude
        # convention above), so the moved amount is small by construction.
        @test ch_ns[1][2] > C[1, 2]

        # ── the overlay personality: a named overlay this board does not have
        # is a failed job, not a guess (the reference agent's rule, D25)
        err = try
            ext.execute_job(server, merge(deepcopy(golden), Dict("overlay_id" => "other-v2")));
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("other-v2", sprint(showerror, err))

        # ── seeded replay, bit-exact: two FRESH servers (fresh twins, fresh
        # rngs) with the same seed — sampled responses (shots on) — produce
        # identical wire outputs, always. Different seeds differ.
        run_sampled(seed) = begin
            s = ext.TwinJobServer(
                TwinSoc(instantiate(toy; drift = DriftPlan(), seed = seed),
                        ComplexF64[1, 0], ComplexF64[0, 1];
                        families = Dict("toy" => toy_family),
                        shots = 64, dac_rate = 9584.64),
                soccfg; overlay_id = "testbench-v2")
            ext.execute_job(s, deepcopy(golden))
        end
        @test run_sampled(0x5EED) == run_sampled(0x5EED)
        @test run_sampled(0x5EED) != run_sampled(0xFEED)

        # ── the server is a soc-level actor: drift advances ACROSS JOBS
        # (twin time moves — the rehearsal point). Same payload, aged truth.
        plan = DriftPlan(:omega => [OrnsteinUhlenbeck(theta = 0.1, sigma = 0.2, mu = 1.0)])
        drifting = ext.TwinJobServer(
            TwinSoc(instantiate(toy; drift = plan, seed = 7),
                    ComplexF64[1, 0], ComplexF64[0, 1];
                    families = Dict("toy" => toy_family), exact = true, dac_rate = 9584.64),
            soccfg; overlay_id = "testbench-v2", dt = 1.0)
        r1 = ext.execute_job(drifting, deepcopy(nosweep))["iq"][1]
        r2 = ext.execute_job(drifting, deepcopy(nosweep))["iq"][1]
        @test r1 != r2                          # truth aged between jobs
        @test drifting.soc.twin.t == 2.0         # the twin clock moved once per job
        @test r1 == ext.execute_job(
            ext.TwinJobServer(
                TwinSoc(instantiate(toy; drift = plan, seed = 7),
                        ComplexF64[1, 0], ComplexF64[0, 1];
                        families = Dict("toy" => toy_family), exact = true,
                        dac_rate = 9584.64),
                soccfg; overlay_id = "testbench-v2", dt = 1.0),
            deepcopy(nosweep))["iq"][1]          # same seed replays the drift+response
    end
end

@testitem "the real-span sweep's IQ trends with the ladder-stepped gain" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (job-server extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        ext = Base.get_extension(Strumento, :StrumentoJobServerExt)
        TwinSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).TwinSoc
        using Strumento: DriftPlan, instantiate
        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
        soccfg = JSON.parsefile(joinpath(fixtures, "soccfg_v2_testbench.json"))
        realspan = JSON.parsefile(joinpath(fixtures, "compiled_job_realspan.json"))
        golden = JSON.parsefile(joinpath(fixtures, "compiled_job_golden.json"))
        nosweep = JSON.parsefile(joinpath(fixtures, "compiled_job_nosweep.json"))
        toy = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "toy.md")

        # the ladder is static data in the payload: the amp ladder steps the
        # wave's gain by +819 codes per expt (the declared 0..8191 span
        # register-rounded — the realized axis, what the tProc steps); the
        # compiler's out-of-loop restore ladder (−9009) is decoded but never
        # realized. Exact integers — no float goldens.
        payload = ext.read_payload(soccfg, realspan)
        @test payload.sweep_ladder == [(1, "gain", 819)]
        @test ext.read_payload(soccfg, golden).sweep_ladder == []    # zero-span golden
        @test ext.read_payload(soccfg, nosweep).sweep_ladder == []   # no sweep

        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        toy_family(truth) =
            QuantumSystem(truth[:omega] * σz, [σx, σx], [truth[:drive_bound], truth[:drive_bound]])
        soc(exact) = TwinSoc(instantiate(toy; drift = DriftPlan(), seed = 0xC0FFEE),
                             ComplexF64[1, 0], ComplexF64[0, 1];
                             families = Dict("toy" => toy_family), exact = exact,
                             dac_rate = 9584.64)
        server = ext.TwinJobServer(soc(true), soccfg; overlay_id = "testbench-v2")

        # the sweep axis: 11 expts from the declared loop structure, and the
        # IQ magnitude TRENDS with the ladder-stepped gain — the amp sweep's
        # whole point (semantic scale, never a captured cross-env literal).
        # The toy's ω = 1.0 rad/ns drift detunes the wire's fractional drive,
        # so the response is a resonance LOBE, not a monotone ramp: the rising
        # edge is the trend (deterministic, exact mode), the last expt rounds
        # the lobe's peak — the contract is the trend, not monotonicity.
        out = ext.execute_job(server, realspan)
        ch = out["iq"][1]
        @test length(ch) == 1 && length(ch[1]) == 11
        exc = [ch[1][e][2] for e in 1:11]
        @test all(diff(exc[1:10]) .> 0)           # the rising edge: gain → excitation
        @test maximum(exc) > exc[1] + 4e-4        # a real excursion, not rounding
        @test exc[end] > exc[1]                   # the sweep ends above its start
        # the trend is the DRIVE's doing: the first expt (gain 0) sits at the
        # pure-|g⟩ confusion row, the same value the zero-span golden pins
        @test exc[1] ≈ 0.02 atol = 1e-12
        # JSON-safe all the way down (the wire contract)
        @test JSON.parse(JSON.json(out)) == out
    end
end

@testitem "the HTTP contract: submit → poll → RawAcquisition, the JobServerClient way" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (job-server extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Sockets
        ext = Base.get_extension(Strumento, :StrumentoJobServerExt)
        TwinSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).TwinSoc
        using Strumento: DriftPlan, instantiate
        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
        soccfg = JSON.parsefile(joinpath(fixtures, "soccfg_v2_testbench.json"))
        golden = JSON.parsefile(joinpath(fixtures, "compiled_job_golden.json"))
        nosweep = JSON.parsefile(joinpath(fixtures, "compiled_job_nosweep.json"))
        toy = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "toy.md")

        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        toy_family(truth) =
            QuantumSystem(truth[:omega] * σz, [σx, σx], [truth[:drive_bound], truth[:drive_bound]])
        soc = TwinSoc(instantiate(toy; drift = DriftPlan(), seed = 0xC0FFEE),
                      ComplexF64[1, 0], ComplexF64[0, 1];
                      families = Dict("toy" => toy_family), exact = true,
                      dac_rate = 9584.64)
        server = ext.TwinJobServer(soc, soccfg; overlay_id = "testbench-v2")

        # a minimal JobServerClient over raw sockets: submit → poll, the same
        # two calls the Python JobServerSoc makes (HTTP details live here)
        submit(client_host, client_port, body::AbstractDict) = begin
            sock = connect(client_host, client_port)
            payload = JSON.json(body)
            write(sock, "POST /jobs HTTP/1.1\r\n" *
                        "Host: twin\r\nContent-Type: application/json\r\n" *
                        "Content-Length: $(sizeof(payload))\r\nConnection: close\r\n\r\n" *
                        payload)
            resp = read(sock, String)
            close(sock)
            head, rest = split(resp, "\r\n\r\n"; limit = 2)
            status = parse(Int, split(first(split(head, "\r\n")))[2])
            return status, JSON.parse(String(rest))
        end
        poll(client_host, client_port, job_id::AbstractString) = begin
            sock = connect(client_host, client_port)
            write(sock, "GET /jobs/$job_id HTTP/1.1\r\n" *
                        "Host: twin\r\nConnection: close\r\n\r\n")
            resp = read(sock, String)
            close(sock)
            head, rest = split(resp, "\r\n\r\n"; limit = 2)
            status = parse(Int, split(first(split(head, "\r\n")))[2])
            return status, JSON.parse(String(rest))
        end

        http = ext.serve_http(server)                     # an ephemeral port
        host, port = ext.http_address(http)

        # ── submit → poll: the golden comes back done, shaped, JSON-safe
        status, reply = submit(host, port, golden)
        @test status == 200
        @test haskey(reply, "job_id")
        job_id = reply["job_id"]
        pstatus, preply = poll(host, port, job_id)
        @test pstatus == 200
        @test preply["status"] == "done"
        iq = preply["acquisition"]["iq"]
        @test length(iq) == 1 && length(iq[1]) == 1 && length(iq[1][1]) == 11   # (n_reads, expts, I/Q)
        @test iq[1][1][1][1] ≈ 0.98 atol = 1e-12          # the |g⟩ confusion row
        @test JSON.parse(JSON.json(preply)) == preply     # JSON-safe all the way down

        # a poll of an already-run job is idempotent (the record persists)
        pstatus2, preply2 = poll(host, port, job_id)
        @test pstatus2 == 200 && preply2 == preply

        # ── the no-sweep variant: the expts axis absent — (n_reads, 2)
        status, reply = submit(host, port, nosweep)
        _, preply = poll(host, port, reply["job_id"])
        @test preply["status"] == "done"
        @test length(preply["acquisition"]["iq"][1]) == 1 &&
              length(preply["acquisition"]["iq"][1][1]) == 2

        # ── a malformed payload is a FAILED JOB, not a server crash: the
        # error rides the status dict (the reference agent's rule) and the
        # next submit still runs
        status, reply = submit(host, port, Dict("overlay_id" => "testbench-v2"))
        @test status == 200
        _, preply = poll(host, port, reply["job_id"])
        @test preply["status"] == "error"
        @test occursin("missing `program`", preply["error"])
        status, reply = submit(host, port, golden)        # the server survived
        _, preply = poll(host, port, reply["job_id"])
        @test preply["status"] == "done"

        # ── an unknown job id: 404, with the error as data
        status, preply = poll(host, port, "no-such-job")
        @test status == 404
        @test preply["status"] == "error"
        @test occursin("unknown job", preply["error"])

        # ── an unknown route: 404 with a named error
        sock = connect(host, port)
        write(sock, "GET /nope HTTP/1.1\r\nHost: twin\r\nConnection: close\r\n\r\n")
        resp = read(sock, String)
        close(sock)
        @test startswith(resp, "HTTP/1.1 404")

        ext.stop_http(http)
    end
end
