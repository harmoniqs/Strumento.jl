# bringup.jl — the rehearsal rig (issue #31, the M4a-1 keystone).
#
# THE RIG: (twin record + demo device + channel map + wire server), the
# registry concept made concrete. The rig composes:
#
#   - a `DigitalTwin` instantiated from a committed record fixture (drift +
#     seed — the twin contract; records never become code),
#   - the committed demo-class DEVICE instance (a cqed pack instance with
#     cavity modes — the same world the Python bring-up graph drives),
#   - a `TwinWiringMap` (the channel-map concept extended one rung down the
#     stack: which twin drive quadratures each device generator channel
#     feeds — declared wiring, so the twin job server routes each payload's
#     played generators onto exactly the drives the map names, and an
#     unmapped device line is a refused job, not a guess),
#   - a `TwinJobServer` over HTTP (the wire — the production shape; the same
#     procedure pointed at a real transport is the hardware bring-up).
#
# Everything is REHEARSAL and says so: results produced against the twin are
# twin-rehearsal evidence (the provenance marking).

# ──── The lazy sibling reaches (runtime, never top level) ──────────────────────

function _jobserver_ext()
    ext = Base.get_extension(Strumento, :StrumentoJobServerExt)
    ext === nothing && error(
        "RehearsalRig: the twin job server extension is not loaded — it " *
        "triggers on Piccolo + JSON (load both together with Strumento to " *
        "attach this extension's sibling)")
    return ext
end

function _piccolo_ext()
    ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
    ext === nothing && error(
        "RehearsalRig: the Piccolo extension is not loaded — it defines the " *
        "twin face (TwinSoc) and the family builders (load Piccolo together " *
        "with Strumento)")
    return ext
end

# ──── The wire client — the production transport's Julia side ─────────────────
# The two routes the Python `JobServerClient`'s deployment speaks: POST /jobs
# with the CompiledJob wire JSON, GET /jobs/<id> for the status dict. One
# request per connection, HTTP/1.1 — the same minimal contract the job
# server's own testitem drives. The RIG's procedure submits through THIS
# client (over the socket, never in-process server calls): the production
# shape from day one — Python compiles, the wire executes, Julia fits.

"""The rig's wire client: submit + poll over HTTP, the `JobServerClient`
contract (two routes, one request per connection)."""
struct TwinWireClient
    host::IPAddr
    port::Int
end

function _http_roundtrip(client::TwinWireClient, request::AbstractString,
                         body::Union{Nothing,AbstractString} = nothing)
    sock = connect(client.host, client.port)
    try
        payload = body === nothing ? "" : body
        write(sock, request *
                    "Host: bringup\r\nContent-Type: application/json\r\n" *
                    "Content-Length: $(sizeof(payload))\r\nConnection: close\r\n\r\n" *
                    payload)
        resp = read(sock, String)
        head, rest = split(resp, "\r\n\r\n"; limit = 2)
        status = parse(Int, split(first(split(head, "\r\n")))[2])
        return status, JSON.parse(String(rest))
    finally
        close(sock)
    end
end

"""Submit one `CompiledJob` wire dict; returns its job id."""
function submit_job(client::TwinWireClient, job_wire::AbstractDict)
    status, reply = _http_roundtrip(
        client,
        "POST /jobs HTTP/1.1\r\n", JSON.json(job_wire))
    status == 200 || error(
        "submit_job: the wire refused the submission (HTTP $status: " *
        "$(get(reply, "error", reply)))")
    haskey(reply, "job_id") || error(
        "submit_job: the wire's reply carries no job_id ($(reply))")
    return String(reply["job_id"])
end

"""Poll one job: its status dict (pending | done with its acquisition | error)."""
function poll_job(client::TwinWireClient, job_id::AbstractString)
    status, reply = _http_roundtrip(client, "GET /jobs/$job_id HTTP/1.1\r\n")
    status == 200 || error(
        "poll_job: the wire refused the poll (HTTP $status: " *
        "$(get(reply, "error", reply)))")
    return reply
end

"""Submit + poll to completion: the `RawAcquisition` wire dict. A failed job
(the server's actionable error — an unmapped channel, a malformed payload) is
an exception carrying the server's message, never a silent shape."""
function run_job(client::TwinWireClient, job_wire::AbstractDict)
    job_id = submit_job(client, job_wire)
    reply = poll_job(client, job_id)
    state = get(reply, "status", nothing)
    state == "done" && return reply["acquisition"]
    state == "error" && error(
        "run_job: the board rejected the job — $(get(reply, "error", "unknown error"))")
    state == "pending" && error(
        "run_job: job $job_id is still pending after its poll (the single " *
        "worker's turn) — poll again")
    error("run_job: unknown wire state $(repr(state)) for job $job_id")
end

# ──── The rig ──────────────────────────────────────────────────────────────────

"""
    RehearsalRig(record_path, device_path, soccfg_path, wiring;
                 drift = DriftPlan(), seed, overlay_id = "", shots = 3000,
                 exact = false, dt = 0.0, ψ_init = nothing, host, port = 0)

The rehearsal rig (issue #31): a twin record + a committed demo-class device
instance + the device-channel → twin-drive `wiring` + the twin job server,
served over HTTP.

- `record_path` — the committed twin record fixture (the record must be
  family `bosonic` in v1: the rig's family wiring is the bosonic builder +
  the ancilla marginal; the spin track is the parallel slice).
- `device_path` / `soccfg_path` — the committed demo-class device instance
  and its overlay snapshot. The rig carries them as PROVENANCE (the twin's
  record is the physics; the device instance is the Python world the bridge
  drives); the server consumes `soccfg` to decode payloads (one overlay ⇔ one
  snapshot, D25).
- `wiring` — the `TwinWiringMap` (device generator channels → twin drive
  quadratures). Validated against the family: the wired drive count must
  equal the family system's `n_drives`.
- `drift` / `seed` — the twin contract (truth drifts; the seeded rng drives
  every shot).
- `shots` — the soc's per-round shot count; a payload's `reps × soft_avgs`
  rounds batch into ONE accumulated draw of `shots × reps × soft_avgs` (the
  server's buffer statistic).
- `dt` — the twin-time (days) the SERVER advances after each job (the
  soc-level actor's clock). Default 0: the procedure measures the truth as
  it stands.
- `ψ_init` — the soc's prepared initial state (default: the joint ground
  state |g,0⟩ — the resonator sweep's comb preparation).

The rig owns its wire: `wire_address(rig)` is the bound `(host, port)`;
`stop!(rig)` closes it. Results produced through the rig are twin-rehearsal
evidence (the provenance marking) — never device results.
"""
struct RehearsalRig
    twin::DigitalTwin
    record_path::String
    device_path::String
    soccfg_path::String
    overlay_id::String
    seed::Any
    wiring::TwinWiringMap
    families::Dict{String,Function}
    measurement_fn::Function
    soc                            # TwinSoc (the sibling extension's type)
    server                         # TwinJobServer (the sibling extension's type)
    http                           # TwinJobHttp (the sibling extension's type)
    client::TwinWireClient
end

function RehearsalRig(record_path::AbstractString, device_path::AbstractString,
                     soccfg_path::AbstractString, wiring::TwinWiringMap;
                     drift = DriftPlan(),
                     seed,
                     overlay_id::AbstractString = "",
                     shots::Integer = 3000,
                     exact::Bool = false,
                     dt::Real = 0.0,
                     ψ_init = nothing,
                     host::IPAddr = ip"127.0.0.1",
                     port::Integer = 0)
    pc = _piccolo_ext()
    js = _jobserver_ext()

    record = load_record(record_path)
    record.family == "bosonic" || error(
        "RehearsalRig: the record $(repr(record.id)) has family " *
        "$(repr(record.family)) — the rig's family wiring is the bosonic " *
        "builder (the ancilla-marginal measurement); the spin track is the " *
        "parallel slice")
    isfile(device_path) || error(
        "RehearsalRig: the device instance $device_path does not exist — the " *
        "rig's device is a committed fixture (the Python bridge loads it)")
    isfile(soccfg_path) || error(
        "RehearsalRig: the overlay snapshot $soccfg_path does not exist — " *
        "one overlay is one snapshot (D25)")

    twin = instantiate(record_path; drift = drift, seed = seed)
    builder = pc.bosonic_system_builder(record)
    families = Dict{String,Function}("bosonic" => builder)

    # the wiring must match the family: the wired twin drives are exactly the
    # family system's control channels (an over- or under-wired map would
    # silently mis-drive the twin).
    n_t = Int(get(record.parameters, "N_transmon", 2))
    n_f = Int(get(record.parameters, "N_fock", 2))
    n_drives_family = builder(twin.truth).n_drives
    wiring.n_drives == n_drives_family || error(
        "RehearsalRig: the wiring declares $(wiring.n_drives) twin drives but " *
        "the bosonic family's system carries $n_drives_family control " *
        "channels — the map must wire every family drive exactly once")

    measurement_fn = pc.bosonic_ancilla_populations(n_t, n_f)
    ψ0 = ψ_init === nothing ? _bosonic_ground_state(n_t, n_f) : ψ_init
    soc = pc.TwinSoc(twin, ψ0, ψ0;
                     families = families,
                     measurement_fn = measurement_fn,
                     shots = shots, exact = exact, dt = 0.0,
                     dac_rate = _snapshot_dac_rate(soccfg_path))
    soccfg = JSON.parsefile(soccfg_path)
    server = js.TwinJobServer(soc, soccfg;
                             overlay_id = overlay_id, dt = dt, wiring = wiring)
    http = js.serve_http(server; host = host, port = port)
    host_addr, bound_port = js.http_address(http)
    return RehearsalRig(twin, abspath(record_path), abspath(device_path),
                        abspath(soccfg_path), String(overlay_id), seed, wiring,
                        families, measurement_fn, soc, server, http,
                        TwinWireClient(host_addr, bound_port))
end

# The joint ground state |g,0⟩ in the family's cavity-major basis
# (fock-major, transmon-minor — bosonic_ancilla_populations' convention).
function _bosonic_ground_state(n_t::Integer, n_f::Integer)
    ψ = zeros(ComplexF64, n_t * n_f)
    ψ[1] = 1.0
    return ψ
end

# The overlay's first generator's sample rate in samples/ns — the soc's
# dac_rate (informational on the wire path: the server owns the grid from the
# payload's own soccfg facts; the soc's rate is what execute! would sample at).
function _snapshot_dac_rate(soccfg_path::AbstractString)
    soccfg = JSON.parsefile(soccfg_path)
    gens = get(soccfg, "gens", nothing)
    (gens isa AbstractVector && !isempty(gens)) || error(
        "RehearsalRig: the overlay snapshot carries no generators (the " *
        "twin server decodes payloads against the gens' clocking facts)")
    fs_hz = Float64(gens[1]["fs"]) * 1e6
    return fs_hz * 1e-9          # Hz -> samples per ns
end

"""The rig's bound wire address (host, port)."""
wire_address(rig::RehearsalRig) = (rig.client.host, rig.client.port)

"""Close the rig's wire (queued jobs stay pending — a stopped board is a
stopped board)."""
function stop!(rig::RehearsalRig)
    _jobserver_ext().stop_http(rig.http)
    return rig
end

# ──── The rig's testitems ─────────────────────────────────────────────────────

@testitem "the rehearsal rig composes (twin + device + wiring + wire server)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Strumento: DriftPlan, instantiate, believed
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)
        @test ext !== nothing
        pc = Base.get_extension(Strumento, :StrumentoPiccoloExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        rig = ext.RehearsalRig(record, device, soccfg, wiring;
                               drift = DriftPlan(), seed = 0xC0FFEE,
                               overlay_id = "rehearsal-v2")
        try
            # the rig's composition: the twin (seeded, from the committed
            # record), the device + snapshot (committed fixtures), the
            # declared wiring, and a LIVE wire server
            @test rig.twin isa DigitalTwin
            @test rig.twin.record.id == "synthetic-bosonic"
            @test isfile(rig.device_path) && isfile(rig.soccfg_path)
            @test rig.server.wiring === wiring
            @test rig.server.overlay_id == "rehearsal-v2"
            host, port = ext.wire_address(rig)
            @test port > 0                          # an ephemeral bound port

            # the wiring validated against the family: the bosonic family's
            # 4 control channels
            @test rig.families["bosonic"](rig.twin.truth).n_drives == 4
            @test rig.measurement_fn isa Function

            # a wrong drive count in the map is named actionably
            err = try
                ext.RehearsalRig(record, device, soccfg,
                                 TwinWiringMap([TwinGenWiring(2, 1, 2)]; n_drives = 2);
                                 seed = 1); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("4", sprint(showerror, err))

            # a non-bosonic record is named (the rig's family wiring)
            err = try
                ext.RehearsalRig(joinpath(fixtures, "twins", "spin.md"), device,
                                 soccfg, wiring; seed = 1); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("spin", sprint(showerror, err))

            # a missing device/snapshot fixture is named
            err = try
                ext.RehearsalRig(record, joinpath(fixtures, "nope.yaml"), soccfg,
                                 wiring; seed = 1); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("device", sprint(showerror, err))
        finally
            ext.stop!(rig)
        end
    end
end

@testitem "the rig's wire client: submit → poll → RawAcquisition, the production shape" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Sockets
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)
        js = Base.get_extension(Strumento, :StrumentoJobServerExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        rig = ext.RehearsalRig(record, device, soccfg, wiring;
                               drift = DriftPlan(), seed = 0xC0FFEE,
                               overlay_id = "rehearsal-v2")
        try
            # a comb payload (committed fixture generation shape, exercised
            # here through the wire): the response must come back through
            # the SOCKET as the RawAcquisition wire form.
            comb = JSON.parsefile(joinpath(fixtures, "_fixtures",
                                           "comb_rehearsal_00.json"))
            acq = ext.run_job(rig.client, comb)
            @test sort!(collect(keys(acq))) == ["iq"]
            @test length(acq["iq"]) == 1                    # one readout channel
            @test length(acq["iq"][1]) == 1                 # one read
            @test length(acq["iq"][1][1]) == 2              # (I, Q) = the outcome pair
            @test sum(acq["iq"][1][1]) ≈ 1.0 atol = 1e-9     # a probability vector
        finally
            ext.stop!(rig)
        end
    end
end

@testitem "the rig's board rides the Piccolo+JSON extension; base gains nothing" begin
    using Strumento
    # UNguarded (the placement pin must hold in EVERY configuration): the
    # bring-up surface must never exist on the base module.
    @test !isdefined(Strumento, :RehearsalRig)
    @test !isdefined(Strumento, :TwinWireClient)
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping the extension side: no Piccolo + JSON in this environment"
        @test true
    else
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)
        @test ext !== nothing
        @test isdefined(ext, :RehearsalRig)
        @test isdefined(ext, :TwinWireClient)
    end
end

# ──── The bring-up procedure layer (issue #31, the M4a-1 keystone) ─────────────
#
# A bring-up procedure is (belief + schedule) -> proposed measurements ->
# results -> fit -> belief write-back. The seam points, named for the #38
# supervision layer (the BringupPlan runner) to wrap later:
#
#   propose(rig, design)          the belief + schedule -> the measurement
#                                grid (validated against the belief)
#   compile_jobs(rig, schedule)   the proposed measurements -> CompiledJob wire
#                                payloads (the bridge — in-process Python —
#                                or the committed fixture payloads)
#   run_over_wire(rig, ...)       submit -> poll -> RawAcquisition (the wire,
#                                the production shape)
#   fit(rig, design, result)     the certification fit class (weighted
#                                binomial-chi^2 against the belief-side model
#                                sweep; the Fisher tolerance discipline)
#   write_back!(rig, fit)        calibrate! — the fitted parameters land in
#                                the twin's BELIEF, never truth
#
# Rehearsal evidence marking: every result this layer produces carries
# `evidence_class = "twin-rehearsal"` — results on twins are twin-rehearsal,
# never device results.

"""
    ResonatorSweepDesign(; kwargs...) -> ResonatorSweepDesign

The resonator-sweep procedure's pinned design — the measurement geometry, the
sweep grid, and the fit's brackets (the certification machinery's fit
discipline: `BosonicCertDesign`'s comb precedent, restated for the wire).

The observable (stated, the implementer's design per the issue): **χ**, via
the **ancilla-probed photon-number comb** — the certification design's comb
observable, realized through the wire. The cavity is displaced to
`|β| = displacement_alpha` (mean photon number `displacement_alpha²`), then a
shaped π-pulse probes the ancilla at the swept frequency: the ancilla
transition at k photons sits at `χ·k` exactly (the cavity Kerr is
photon-number-independent and cancels in the transition difference), so the
response is a comb of lines whose spacing is χ — the dispersive signature,
Kerr-free by construction. The swept detuning rides the pulse ENVELOPE (the
v1 wire frame boundary: the twin's family systems are rotating-frame models,
so the payload's carrier is the frame and a carrier-swept const probe is
frame-invisible; see the bridge's `BRIDGE_FRAME_NOTE`).

The sweep grid is the schedule's declared measurement points (authored
belief-relative at design time); `propose` validates it against the twin's
CURRENT belief — the grid must span the believed k=1 and k=2 lines.

Fit: the certification fit class (the Piccolo extension's
`_CertModelCache` + `_cert_fit_1d` — one fitter home, no duplication):
weighted binomial χ² of the measured sweep against the belief-side model
sweep over a record-relative χ bracket, refined by golden section to
`fit_tol_kHz`; σ from the fit's observed information (the model Jacobian
against the measured binomial variances), the recovery tolerance
`BOSONIC_CERT_TOLERANCE_SIGMA`·σ (5σ, never a hand-picked number).

The geometry field values are the committed fixture set's constants
(`test/fixtures/_fixtures/generate_rehearsal_payloads.py` — the fixture
payloads are this geometry compiled); the bridge compiles the same geometry
live (`comb_geometry`).
"""
struct ResonatorSweepDesign
    # the measurement grid (kHz) — the schedule's declared sweep points
    freqs_kHz::Vector{Float64}
    # the comb geometry (the cert design's comb, restated for the wire)
    displacement_alpha::Float64
    T_disp_us::Float64
    T_spec_us::Float64
    probe_gain::Float64
    qubit_freq_mhz::Float64
    # the acquisition
    reps::Int
    soft_avgs::Int
    # the fit (the cert discipline)
    chi_halfbracket_kHz::Float64
    fit_grid_step_kHz::Float64
    fit_tol_kHz::Float64
end

function ResonatorSweepDesign(;
        freqs_kHz = vcat(collect(230.0:15.0:350.0), collect(520.0:15.0:640.0)),
        displacement_alpha = sqrt(2.0),
        T_disp_us = 4.0,
        T_spec_us = 10.0,
        probe_gain = 2π / 10000.0,
        qubit_freq_mhz = 4.0,
        reps = 50,
        soft_avgs = 1,
        chi_halfbracket_kHz = 12.0,
        fit_grid_step_kHz = 2.0,
        fit_tol_kHz = 0.02)
    freqs = Float64.(freqs_kHz)
    isempty(freqs) && error("ResonatorSweepDesign: freqs_kHz must be non-empty")
    for (name, v) in (("displacement_alpha", displacement_alpha),
                      ("T_disp_us", T_disp_us), ("T_spec_us", T_spec_us),
                      ("probe_gain", probe_gain), ("qubit_freq_mhz", qubit_freq_mhz),
                      ("chi_halfbracket_kHz", chi_halfbracket_kHz),
                      ("fit_grid_step_kHz", fit_grid_step_kHz))
        v > 0 || error("ResonatorSweepDesign: $name must be > 0 (got $v)")
    end
    0 < fit_tol_kHz ≤ fit_grid_step_kHz || error(
        "ResonatorSweepDesign: fit_tol_kHz ($fit_tol_kHz) must be in (0, " *
        "$fit_grid_step_kHz] — refinement below the cached model's resolution " *
        "is not a refinement")
    reps ≥ 1 || error("ResonatorSweepDesign: reps must be ≥ 1 (got $reps)")
    soft_avgs ≥ 1 || error("ResonatorSweepDesign: soft_avgs must be ≥ 1 (got $soft_avgs)")
    issorted(freqs) || error("ResonatorSweepDesign: freqs_kHz must be sorted")
    return ResonatorSweepDesign(freqs, Float64(displacement_alpha),
        Float64(T_disp_us), Float64(T_spec_us), Float64(probe_gain),
        Float64(qubit_freq_mhz), Int(reps), Int(soft_avgs),
        Float64(chi_halfbracket_kHz), Float64(fit_grid_step_kHz), Float64(fit_tol_kHz))
end

"""The design's comb geometry as the bridge's compile contract (the
`compile_comb_point` keyword block — the same constants the committed
fixture-generation script carries)."""
comb_geometry(design::ResonatorSweepDesign) = (
    displacement_alpha = design.displacement_alpha,
    T_disp_us = design.T_disp_us,
    T_spec_us = design.T_spec_us,
    probe_gain = design.probe_gain,
    qubit_freq_mhz = design.qubit_freq_mhz,
    reps = design.reps,
    soft_avgs = design.soft_avgs,
)

# ─── the skeleton types: the procedure's seam data ────────────────────────────

"""The proposed measurements (the `propose` seam's output): the procedure,
its sweep grid, and the provenance the supervision layer (#38) wraps."""
struct BringupSchedule
    procedure::String
    points_kHz::Vector{Float64}
    provenance::Dict{String,Any}
end

"""One proposed measurement, compiled to its `CompiledJob` wire payload,
with the accumulated shot count the fit's binomial weights consume
(`soc shots × payload reps × soft_avgs` — the server's buffer statistic)."""
struct BringupJob
    point_kHz::Float64
    job_wire::Dict{String,Any}
    shots::Int
end

"""The measured responses (the `run_over_wire` seam's output): the schedule,
its compiled jobs, the per-point response vector, and the rehearsal
provenance (evidence class twin-rehearsal, the twin's seed, the wire's
overlay)."""
struct BringupResult
    schedule::BringupSchedule
    jobs::Vector{BringupJob}
    responses::Vector{Float64}
    provenance::Dict{String,Any}
end

"""The resonator sweep's fit outcome: the fitted χ with its derived
information scale, the fit quality, the 5σ recovery tolerance, the
belief-agreement gate, and the rehearsal provenance (the promotion-relevant
shape mirrors `BosonicCertResult`)."""
struct ResonatorSweepFit
    chi_kHz::Float64
    chi_sigma_kHz::Float64
    chi_tolerance_kHz::Float64
    chi2_dof::Float64
    agrees_with_belief::Bool
    seed::Any
    record_id::String
    provenance::Dict{String,Any}
end

# ─── the seams ────────────────────────────────────────────────────────────────

"""The `propose` seam (#38 wraps here): (belief + schedule) -> the proposed
measurements. Validates the design's declared sweep grid against the twin's
CURRENT belief: the grid must span the believed comb's k=1 and k=2 lines
(the lines sit at `|χ_belief|·k` — a grid that misses them measures nothing)."""
function propose(rig::RehearsalRig, design::ResonatorSweepDesign)
    chi_belief = Float64(believed(rig.twin)["chi_kHz"])
    lines = abs(chi_belief) .* [1.0, 2.0]
    lo, hi = first(design.freqs_kHz), last(design.freqs_kHz)
    for (k, line) in enumerate(lines)
        (lo ≤ line ≤ hi) || error(
            "propose: the schedule's sweep grid [$(lo), $(hi)] kHz does not " *
            "span the believed comb's k=$k line at $(line) kHz (the belief's " *
            "chi_kHz = $chi_belief) — the belief and the schedule disagree; " *
            "re-author the grid or calibrate the belief")
    end
    return BringupSchedule(
        "resonator-sweep",
        copy(design.freqs_kHz),
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "overlay_id" => rig.overlay_id,
            "device_path" => rig.device_path,
            "evidence_class" => "twin-rehearsal",
        ),
    )
end

"""The compile seam's fixture lane: the committed wire payloads (the
Julia-only path — CI without Python `strumento` runs the whole procedure
against them; the bridge testitems pin that the live Python compile
reproduces them bit-exactly). The payloads carry their own acquire blocks;
the shot counts derive from the payload × the rig's soc."""
function fixture_comb_jobs(rig::RehearsalRig, schedule::BringupSchedule)
    pc = _piccolo_ext()
    fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
    jobs = BringupJob[]
    for (i, f) in enumerate(schedule.points_kHz)
        path = joinpath(fixtures, "comb_rehearsal_$(lpad(i - 1, 2, '0')).json")
        isfile(path) || error(
            "fixture_comb_jobs: the committed fixture $path is missing — the " *
            "fixture lane expects one payload per schedule point (regenerate " *
            "with test/fixtures/_fixtures/generate_rehearsal_payloads.py)")
        job = JSON.parsefile(path)
        shots = _job_shots(rig, job)
        push!(jobs, BringupJob(f, job, shots))
    end
    return jobs
end

# the accumulated shot count a payload's acquire block requests from the
# rig's soc (the server's buffer statistic: soc shots x reps x soft_avgs).
function _job_shots(rig::RehearsalRig, job::AbstractDict)
    acquire = get(job, "acquire", nothing)
    acquire isa AbstractDict || error(
        "_job_shots: the payload carries no acquire block (the D14 wire form " *
        "is {overlay_id, program, acquire})")
    for key in ("reps", "soft_avgs")
        haskey(acquire, key) || error("_job_shots: the acquire block carries no `$key`")
    end
    reps, soft = Int(acquire["reps"]), Int(acquire["soft_avgs"])
    (reps ≥ 1 && soft ≥ 1) || error(
        "_job_shots: the acquire block's reps ($reps) and soft_avgs ($soft) " *
        "must both be ≥ 1")
    return Int(rig.soc.shots) * reps * soft
end

"""The `run_over_wire` seam (#38 wraps here): submit each proposed
measurement over the wire (the production shape — the socket, never
in-process server calls), poll to completion, and reduce each
`RawAcquisition` to the per-point response (the e-outcome frequency — the
2-outcome IQ packing's Q slot)."""
function run_over_wire(rig::RehearsalRig, schedule::BringupSchedule,
                      jobs::Vector{BringupJob})
    length(jobs) == length(schedule.points_kHz) || error(
        "run_over_wire: $(length(jobs)) compiled jobs for " *
        "$(length(schedule.points_kHz)) schedule points — one payload per point")
    responses = Float64[]
    for job in jobs
        acq = run_job(rig.client, job.job_wire)
        iq = get(acq, "iq", nothing)
        (iq isa AbstractVector && length(iq) == 1) || error(
            "run_over_wire: the RawAcquisition carries " *
            "$(iq === nothing ? "no iq" : "$(length(iq)) channels") — the twin's " *
            "v1 response model serves one readout channel")
        ch = iq[1]
        (length(ch) == 1 && length(ch[1]) == 2) || error(
            "run_over_wire: the per-point acquisition must be one read's " *
            "(I, Q) pair (got $(length(ch)) reads)")
        push!(responses, Float64(ch[1][2]))
    end
    return BringupResult(schedule, jobs, responses,
        Dict{String,Any}(
            "schedule_provenance" => schedule.provenance,
            "evidence_class" => "twin-rehearsal",
            "seed" => rig.seed,
            "overlay_id" => rig.overlay_id,
            "twin_time_days" => rig.twin.t,
        ))
end

# ─── the belief-side forward model (payload-driven) ──────────────────────────
#
# The fit's model sweep must predict EXACTLY what the server executes: the
# same payload (read -> translate -> the wiring map's routing -> the
# flat-top envelope reconstruction) rolled through the family system at the
# CANDIDATE parameters, reduced by the family measurement and remapped by
# the same confusion the soc applies. The payload is the single source of
# truth on both sides — envelope quantization, gain codes, and played
# lengths cancel exactly.

function _wire_predict(rig::RehearsalRig, params::Dict{Symbol,Float64},
                       job::BringupJob)
    # the comb-era body, split so the calibration-set jobs (the Ramsey/T1/
    # confusion payloads — not BringupJobs) share the one belief-side wire
    # model (`_wire_predict_wire`, issue #37); this signature is unchanged.
    return _wire_predict_wire(rig, params, job.job_wire)
end

"""The `fit` seam (#38 wraps here): the certification fit class — weighted
binomial χ² of the measured sweep against the belief-side model sweep over
the belief-relative χ bracket (`_CertModelCache` + `_cert_fit_1d`, the
Piccolo extension's fit home — one fitter, no duplication), σ from the fit's
own observed information, the recovery tolerance
`BOSONIC_CERT_TOLERANCE_SIGMA`·σ."""
function fit(rig::RehearsalRig, design::ResonatorSweepDesign, result::BringupResult)
    pc = _piccolo_ext()
    belief = believed(rig.twin)
    bparams = Dict{Symbol,Float64}(
        Symbol(k) => Float64(v) for (k, v) in belief if v isa Real)
    haskey(bparams, :chi_kHz) || error(
        "fit: the twin's belief carries no chi_kHz — the resonator sweep fits " *
        "χ; the record must state it")
    χ_belief = bparams[:chi_kHz]

    # every job's accumulated shots (the binomial weights); constant by
    # construction of the schedule, and validated so.
    shots = unique([job.shots for job in result.jobs])
    length(shots) == 1 || error(
        "fit: the schedule's payloads carry different accumulated shot " *
        "counts ($(shots)) — the fit's binomial weights need one count")
    shots[1] ≥ 1 || error("fit: the accumulated shot count must be ≥ 1")

    # the belief-side model sweep at candidate χ: the payload-driven
    # prediction, one per schedule point (the payload's own envelopes rolled
    # at the candidate parameters)
    model_sweep_at(θ) =
        [_wire_predict(rig, merge(bparams, Dict{Symbol,Float64}(:chi_kHz => θ)),
                       job)[2] for job in result.jobs]
    cache = pc._CertModelCache(model_sweep_at,
                               χ_belief - design.chi_halfbracket_kHz,
                               χ_belief + design.chi_halfbracket_kHz,
                               design.fit_grid_step_kHz)
    # the certification fit class, carrying this design's refinement
    # tolerance (the only design field _cert_fit_1d consumes)
    fit_design = pc.BosonicCertDesign(fit_tol_kHz = design.fit_tol_kHz)
    χ̂, χ2min, σ, _ = pc._cert_fit_1d(cache, result.responses, shots[1], fit_design)

    tolerance = pc.BOSONIC_CERT_TOLERANCE_SIGMA * σ
    dof = max(length(result.responses) - 1, 1)
    return ResonatorSweepFit(χ̂, σ, tolerance, χ2min / dof,
        abs(χ̂ - χ_belief) ≤ tolerance, result.provenance["seed"],
        rig.twin.record.id,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "record_path" => rig.record_path,
            "design" => "$(length(design.freqs_kHz)) points x $(shots[1]) shots; " *
                        "bracket $(χ_belief - design.chi_halfbracket_kHz).." *
                        "$(χ_belief + design.chi_halfbracket_kHz) kHz",
            "tolerance_rule" => string(
                "recovery within $(pc.BOSONIC_CERT_TOLERANCE_SIGMA)·σ; σ from " *
                "the fit's observed binomial information (the model Jacobian " *
                "vs q̂(1−q̂)/N on the belief-side wire model sweep)"),
            "evidence_class" => "twin-rehearsal",
            "tool" => "Strumento v$(pkgversion(Strumento)), julia $(VERSION)",
        ))
end

"""The `write_back` seam (#38 wraps here): the fitted parameter lands in the
twin's BELIEF via `calibrate!` — never truth. The truth/belief invariant is
the twin contract's; the procedure asserts it live at the seam (see the
procedure testitem)."""
function write_back!(rig::RehearsalRig, fitres::ResonatorSweepFit)
    calibrate!(rig.twin, Dict{String,Any}("chi_kHz" => fitres.chi_kHz))
    return rig
end

"""
    run_resonator_sweep(rig, design; jobs = fixture_comb_jobs) -> ResonatorSweepFit

The keystone chain, one call: propose → compile → run over the wire → fit →
write back. `jobs` is the compile seam's source: the committed fixture
payloads (the default — the Julia-only lane) or a live bridge source (the
PythonCall extension's `compile_comb_point` over the design's
`comb_geometry` — the in-process Python path, exercised by the bridge
testitems).

Everything is a pure function of (rig, design, jobs, the twin's seed): a
procedure run replays bit-exactly from its seed across fresh processes (the
replay check: `test/configurations/bringup_replay_check.jl`).
"""
function run_resonator_sweep(rig::RehearsalRig, design::ResonatorSweepDesign;
                            jobs = fixture_comb_jobs)
    schedule = propose(rig, design)
    payloads = jobs isa Function ? jobs(rig, schedule) : jobs
    result = run_over_wire(rig, schedule, payloads)
    fitres = fit(rig, design, result)
    write_back!(rig, fitres)
    return fitres
end

"""The compile seam's live lane: a point compiler (anything `f_kHz -> wire
Dict` — the bridge's `compile_comb_point` over the design's `comb_geometry`)
wrapped into a job source for `run_resonator_sweep`."""
function point_jobs(compile_point, rig::RehearsalRig, schedule::BringupSchedule)
    jobs = BringupJob[]
    for f in schedule.points_kHz
        wire = compile_point(f)
        push!(jobs, BringupJob(f, wire, _job_shots(rig, wire)))
    end
    return jobs
end

# ─── The Rabi procedure (issue #33, the M4a-2 pi-gain calibration) ───────────────
#
# The amplitude-domain counterpart of the resonator sweep. ONE payload runs
# the whole sweep: the swept axis rides the payload's CloseLoop gain ladder
# (the v1-wire swept form the twin job server decodes — gain steps are the
# wire-realizable axis), the twin's ancilla oscillates Pe(gain), and the fit
# extracts the π-gain — the gain FRACTION whose pulse flips the ancilla. The
# entry lands in the twin's BELIEF as `pi_gain` (with `pi_rabi_mhz`, its
# PiPulseReference companion: the pair is the D17 amplitude ruler the pulse
# side consumes — `compile_ge_pi` compiles the factory at the believed
# fraction).
#
# The fit is the certification fit class, one fitter home: weighted binomial
# χ² of the measured oscillation against the payload-driven belief-side
# model sweep over a candidate π-gain bracket, refined by golden section,
# σ from the fit's observed information, tolerance
# `BOSONIC_CERT_TOLERANCE_SIGMA`·σ (5σ, never hand-picked). The model at
# candidate θ rolls the payload's own decoded envelopes per expt with the
# drive scaled by π/(θ·I_env) — I_env the payload's envelope integral — so
# the model equals the twin's execution exactly when θ is the twin's true
# π-gain (the degenerate cross-path pin below). The bracket is DATA-anchored:
# the first measured oscillation maximum locates it, the design's
# multipliers widen it (never a hand-picked absolute span).

"""
    RabiSweepDesign(; kwargs...) -> RabiSweepDesign

The Rabi procedure's pinned design — the gain-ladder sweep geometry and the
fit's data-anchored bracket parameters.

The sweep: the ge_pi gauss's gain swept in LAB-NATIVE int codes
`gains_start → gains_stop` over `points` points — the CloseLoop ladder steps
`(gains_stop − gains_start)/(points − 1)` codes per expt (an integer by
validation; a fractional step would quantize differently per point). The
committed default span (0 → 120 codes, 41 points, step 3) covers the
rehearsal twin's true π-gain (~43 codes) with the first oscillation maximum
well inside and ~3× margin on the far side.

The fit (all anchors DERIVED from the measured sweep, never absolute
hand-picked spans): the bracket is `[bracket_lo_frac, bracket_hi_frac] ×`
the FIRST measured oscillation maximum; the θ-model cache steps
`fit_grid_frac ×` that maximum (its nodes are interpolations of the
precomputed G-curve, so it is dense by construction — see `fit_rabi`);
the golden section refines to `fit_tol_frac ×` the maximum (finer than
the fit's own information scale).

The π-gain belief entry is a gain FRACTION (the v2 unit the cqed factories'
explicit `gain=` override consumes), and `pi_rabi_mhz` its mean-rate
companion over the payload's played window (the PiPulseReference pair).
"""
struct RabiSweepDesign
    gains_start::Int
    gains_stop::Int
    points::Int
    reps::Int
    soft_avgs::Int
    bracket_lo_frac::Float64
    bracket_hi_frac::Float64
    fit_grid_frac::Float64
    fit_tol_frac::Float64
end

function RabiSweepDesign(; gains_start = 0, gains_stop = 120, points = 41,
                         reps = 50, soft_avgs = 1,
                         bracket_lo_frac = 0.5, bracket_hi_frac = 1.5,
                         fit_grid_frac = 1 / 128, fit_tol_frac = 1 / 12000)
    gains_start ≥ 0 || error(
        "RabiSweepDesign: gains_start must be ≥ 0 (got $gains_start) — a Rabi " *
        "sweep starts at zero drive")
    gains_stop > gains_start || error(
        "RabiSweepDesign: gains_stop ($gains_stop) must exceed gains_start " *
        "($gains_start) — the sweep must rise")
    points ≥ 3 || error(
        "RabiSweepDesign: points must be at least 3 (got $points) — the " *
        "oscillation needs a rising flank, a maximum, and a falling flank")
    (gains_stop - gains_start) % (points - 1) == 0 || error(
        "RabiSweepDesign: the gain span ($gains_start → $gains_stop) does not " *
        "divide into $points points — the CloseLoop ladder steps integer " *
        "gain codes, and a fractional step would quantize differently per " *
        "point (the decoded axis would not be the declared one)")
    reps ≥ 1 || error("RabiSweepDesign: reps must be ≥ 1 (got $reps)")
    soft_avgs ≥ 1 || error("RabiSweepDesign: soft_avgs must be ≥ 1 (got $soft_avgs)")
    (0 < bracket_lo_frac < 1 < bracket_hi_frac) || error(
        "RabiSweepDesign: the bracket multipliers must straddle the first " *
        "maximum (0 < bracket_lo_frac < 1 < bracket_hi_frac; got " *
        "[$bracket_lo_frac, $bracket_hi_frac])")
    0 < fit_tol_frac ≤ fit_grid_frac || error(
        "RabiSweepDesign: fit_tol_frac ($fit_tol_frac) must be in (0, " *
        "$fit_grid_frac] — refinement below the cached model's resolution " *
        "is not a refinement")
    return RabiSweepDesign(Int(gains_start), Int(gains_stop), Int(points),
        Int(reps), Int(soft_avgs), Float64(bracket_lo_frac),
        Float64(bracket_hi_frac), Float64(fit_grid_frac), Float64(fit_tol_frac))
end

"""The design's declared gain axis: the lab-native int codes the ladder
steps through (the wave's gain at expt e is `gains_start + step·(e−1)`)."""
rabi_axis(design::RabiSweepDesign) =
    [design.gains_start + ((design.gains_stop - design.gains_start) ÷
                           (design.points - 1)) * (e - 1) for e in 1:design.points]

"""The design's sweep geometry as the bridge's compile contract (the
`compile_rabi_sweep` keyword block — the same constants the committed
fixture-generation script carries)."""
rabi_geometry(design::RabiSweepDesign) = (
    gains_start = design.gains_start,
    gains_stop = design.gains_stop,
    points = design.points,
    reps = design.reps,
    soft_avgs = design.soft_avgs,
)

"""The Rabi schedule (the `propose_rabi` seam's output): the declared gain
axis and the provenance the supervision layer (#38) wraps."""
struct RabiSchedule
    gains::Vector{Int}
    provenance::Dict{String,Any}
end

"""The Rabi procedure's compiled job: ONE wire payload (the swept axis rides
inside it — the CloseLoop ladder) with the accumulated per-expt shot count
(`soc shots × payload reps × soft_avgs`)."""
struct RabiJob
    job_wire::Dict{String,Any}
    shots::Int
end

"""The Rabi sweep's measured responses (the `run_rabi_over_wire` seam's
output): the schedule, its payload, the per-expt e-outcome frequencies on
the DECODED gain axis (the payload is the single source of truth), the
decoded payload itself, and the rehearsal provenance."""
struct RabiResult
    schedule::RabiSchedule
    job::RabiJob
    responses::Vector{Float64}
    axis_frac::Vector{Float64}
    payload                         # the decoded WirePayload (the sibling ext's type)
    shots::Int
    provenance::Dict{String,Any}
end

"""The Rabi fit's outcome: the π-gain (a gain FRACTION) with its derived
information scale, the 5σ recovery tolerance, the fit quality, the
belief-agreement gate (against a prior `pi_gain` belief when one exists —
the first calibration has nothing to disagree with), the mean-rate
companion, and the rehearsal provenance (mirrors `ResonatorSweepFit`)."""
struct RabiSweepFit
    pi_gain::Float64
    pi_gain_sigma::Float64
    pi_gain_tolerance::Float64
    chi2_dof::Float64
    agrees_with_belief::Bool
    pi_rabi_mhz::Float64
    seed::Any
    record_id::String
    provenance::Dict{String,Any}
end

"""The `propose_rabi` seam (#38 wraps here): (belief + schedule) -> the
declared gain axis, validated. The axis's shape must be ladder-realizable
(an integral per-expt step); on a RE-CALIBRATION (the belief already
carries `pi_gain`) the axis must span the believed π-gain — a sweep that
misses the believed operating point measures nothing useful. The first
calibration has no believed π-gain to span; the fit's own first-maximum
check (below) is what refuses a span that misses the truth."""
function propose_rabi(rig::RehearsalRig, design::RabiSweepDesign)
    prior = get(believed(rig.twin), "pi_gain", nothing)
    if prior isa Real
        # the believed fraction in the axis's lab-native codes (maxv from the
        # snapshot's first generator — uniform full-scale on this overlay)
        maxv = Int(rig.server.soccfg["gens"][1]["maxv"])
        lo = design.gains_start / maxv
        hi = design.gains_stop / maxv
        (lo ≤ Float64(prior) ≤ hi) || error(
            "propose_rabi: the declared gain axis [$lo, $hi] fraction does not " *
            "span the believed pi_gain $(Float64(prior)) (the belief and the " *
            "schedule disagree) — re-author the axis or recalibrate the belief " *
            "first")
    end
    return RabiSchedule(
        rabi_axis(design),
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "overlay_id" => rig.overlay_id,
            "device_path" => rig.device_path,
            "evidence_class" => "twin-rehearsal",
        ),
    )
end

"""The compile seam's fixture lane: the committed Rabi ladder payload (the
Julia-only path — CI without Python `strumento` runs the whole procedure
against it; the bridge testitem pins that the live Python compile reproduces
it bit-exactly)."""
function fixture_rabi_job(rig::RehearsalRig, schedule::RabiSchedule)
    path = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures",
                    "rabi_rehearsal.json")
    isfile(path) || error(
        "fixture_rabi_job: the committed fixture $path is missing — the fixture " *
        "lane expects the Rabi gain-ladder payload (regenerate with " *
        "test/fixtures/_fixtures/generate_rehearsal_payloads.py)")
    job = JSON.parsefile(path)
    return RabiJob(job, _job_shots(rig, job))
end

"""The `run_rabi_over_wire` seam (#38 wraps here): run the ONE swept payload
over the wire (the production shape — the socket, never in-process server
calls) and reduce the acquisition to the per-expt e-outcome frequency on the
DECODED gain axis. The decoded axis must match the declared one (the payload
is the single source of truth — the fit's axis is the decoded one, never
the declared), and the payload must be the Rabi form: one played generator,
one gain-stepped wave (the procedure's model is one stepped qubit drive)."""
function run_rabi_over_wire(rig::RehearsalRig, schedule::RabiSchedule, job::RabiJob)
    js = _jobserver_ext()
    payload = js.read_payload(rig.server.soccfg, job.job_wire)
    payload.expts !== nothing || error(
        "run_rabi_over_wire: the payload declares no expts axis — the Rabi " *
        "sweep's swept axis rides the CloseLoop gain ladder inside the " *
        "expts loop")
    length(payload.sweep_ladder) == 1 || error(
        "run_rabi_over_wire: the payload's ladder carries " *
        "$(length(payload.sweep_ladder)) steps — the Rabi sweep steps exactly " *
        "one wave's gain")
    widx = payload.sweep_ladder[1][1]
    step = payload.sweep_ladder[1][3]
    length(payload.port_plan) == 1 && length(payload.port_plan[1][2]) == 1 || error(
        "run_rabi_over_wire: the payload plays $(length(payload.port_plan)) " *
        "generators — the Rabi sweep's gain axis is one stepped qubit drive")
    payload.port_plan[1][2][1] == widx || error(
        "run_rabi_over_wire: the ladder steps a wave the port plan does not " *
        "play — the payload is malformed")

    # the decoded axis (codes), validated against the declared one — the
    # payload is the single source of truth (the fit's axis is the decoded
    # one, never the declared)
    wave = payload.waves[widx]
    decoded = [wave.gain_code + step * (e - 1) for e in 1:payload.expts]
    decoded == schedule.gains || error(
        "run_rabi_over_wire: the design's declared gain axis does not match " *
        "the payload's decoded ladder (declared $(length(schedule.gains)) " *
        "points, $(schedule.gains[1])..$(schedule.gains[end]) step " *
        "$(length(schedule.gains) > 1 ? schedule.gains[2] - schedule.gains[1] : 0); " *
        "decoded $(payload.expts) points, $(decoded[1])..$(decoded[end]) step " *
        "$step) — compile the design's own payload (the bridge lane) or " *
        "re-author the design to the committed geometry")

    acq = run_job(rig.client, job.job_wire)
    iq = get(acq, "iq", nothing)
    (iq isa AbstractVector && length(iq) == 1) || error(
        "run_rabi_over_wire: the RawAcquisition carries " *
        "$(iq === nothing ? "no iq" : "$(length(iq)) channels") — the twin's " *
        "v1 response model serves one readout channel")
    ch = iq[1]
    (length(ch) == 1 && length(ch[1]) == payload.expts &&
     all(v -> length(v) == 2, ch[1])) || error(
        "run_rabi_over_wire: the per-expt acquisition must be one read's " *
        "(I, Q) pair per expt ($(payload.expts) expected)")
    responses = [Float64(ch[1][e][2]) for e in 1:payload.expts]
    maxv = payload.gen_cfg[payload.port_plan[1][1]].maxv
    return RabiResult(schedule, job, responses, decoded ./ maxv, payload, job.shots,
        Dict{String,Any}(
            "schedule_provenance" => schedule.provenance,
            "evidence_class" => "twin-rehearsal",
            "seed" => rig.seed,
            "overlay_id" => rig.overlay_id,
            "twin_time_days" => rig.twin.t,
        ))
end

# The local-quadratic evaluator the Rabi model's G-curve reads (the same
# three-node Lagrangian the certification fit interpolates its cache with —
# one interpolation idiom).
function _quad_eval(nodes::Vector{Float64}, vals::Dict{Float64,Float64}, x::Real)
    n = length(nodes)
    j = clamp(searchsortedfirst(nodes, x) - 1, 1, n - 1)
    i1 = clamp(j, 1, n - 2)
    x1, x2, x3 = nodes[i1], nodes[i1 + 1], nodes[i1 + 2]
    L1 = (x - x2) * (x - x3) / ((x1 - x2) * (x1 - x3))
    L2 = (x - x1) * (x - x3) / ((x2 - x1) * (x2 - x3))
    L3 = (x - x1) * (x - x2) / ((x3 - x1) * (x3 - x2))
    return L1 * vals[x1] + L2 * vals[x2] + L3 * vals[x3]
end

# The payload-driven per-expt rollout (the Rabi model's forward path — the
# `_wire_predict` pattern, per expt, with the candidate π-gain's drive
# scale). The payload is the single source of truth: the same decoded
# envelopes the server executes, rolled through the family system at the
# BELIEF-side candidate parameters, reduced by the family measurement and
# remapped by the same confusion the soc applies. At drive scale 1 the
# arithmetic is the server's own (the degenerate cross-path pin).
function _wire_predict_rabi(rig::RehearsalRig, params::Dict{Symbol,Float64},
                           payload, expt::Integer, drive_scale::Real)
    js = _jobserver_ext()
    drives = js.translate_drive(payload; expt = expt)
    nsamp = maximum(length(d.times) for d in values(drives))
    gen_chs = sort(collect(keys(drives)))
    routing, n_drives = js._payload_routing(rig.server, gen_chs)
    times = [1e9 * (i - 1) / payload.gen_cfg[gen_chs[1]].fs_hz for i in 1:nsamp]
    ctrls = zeros(Float64, n_drives, nsamp)
    for (gen_ch, i_drive, q_drive) in routing
        d = drives[gen_ch]
        pad = zeros(nsamp - length(d.times))
        ctrls[i_drive, :] .= vcat(d.uI, pad)
        q_drive === nothing || (ctrls[q_drive, :] .= vcat(d.uQ, pad))
    end
    drive_scale == 1 || (ctrls .*= drive_scale)
    recon = LinearSplinePulse(ctrls, times)

    # the family system at the CANDIDATE (belief-side) parameters — the fit
    # never sees the twin's truth — with the soc's own confusion (the
    # record's readout model) and the soc's own remap arithmetic.
    system = rig.families[rig.twin.record.family](params)
    ψ = rig.soc.ψ_init
    ρ0 = ψ * ψ'
    qtraj = DensityTrajectory(system, recon, ρ0, ρ0)
    p = rig.measurement_fn(Piccolo.density_to_iso_vec(qtraj(times[end])))
    confusion = _piccolo_ext()._record_confusion(rig.twin)
    return [sum(confusion[i, j] * p[i] for i in eachindex(p)) for j in eachindex(p)]
end

"""The `fit_rabi` seam (#38 wraps here): the certification fit class —
weighted binomial χ² of the measured oscillation against the payload-driven
belief-side model sweep over the DATA-anchored π-gain bracket
(`_CertModelCache` + `_cert_fit_1d`, the Piccolo extension's fit home — one
fitter, no duplication), σ from the fit's own observed information, the
recovery tolerance `BOSONIC_CERT_TOLERANCE_SIGMA`·σ.

The model at candidate π-gain θ predicts the response at decoded gain
`g_e` as the payload's own envelope rolled at the drive scale
`π/(θ·I_env)` (I_env the payload's decoded envelope integral) — so the model
equals the twin's execution exactly when θ is the true π-gain. Because the
swept pulse's SHAPE is fixed (only the gain steps along the ladder), that
prediction is one response curve `G(gain)` read at θ-rescaled gains: the
fit evaluates G by payload-driven rollouts on a gain grid fine enough that
its local-quadratic interpolation is dust, and the θ-model cache reads it
by interpolation — its nodes are cheap, so the cache is DENSE. (The
oscillation's phase `π·g/θ` twists ever faster in θ at the sweep's far
points — a sparse uniform θ grid cannot serve them; the G-curve is what
makes the certification class's cached fit honest here.)

The bracket anchors on the FIRST measured oscillation maximum and widens
by the design's multipliers; a sweep that exhibits no maximum is refused
actionably (the span does not cover the π-gain)."""
function fit_rabi(rig::RehearsalRig, design::RabiSweepDesign, result::RabiResult)
    js = _jobserver_ext()
    pc = _piccolo_ext()
    belief = believed(rig.twin)
    bparams = Dict{Symbol,Float64}(
        Symbol(k) => Float64(v) for (k, v) in belief if v isa Real)
    payload = result.payload
    n = length(result.responses)
    n == length(result.axis_frac) || error(
        "fit_rabi: $(n) measured responses on a $(length(result.axis_frac))-point " *
        "axis — one response per decoded gain point")
    result.shots ≥ 1 || error("fit_rabi: the accumulated shot count must be ≥ 1")

    # the first measured oscillation maximum: the data anchor for the fit's
    # bracket (the π-gain sits at the oscillation's first peak; a sweep that
    # never peaks cannot yield one)
    e_peak = findfirst(e -> 2 <= e <= n - 1 &&
                            result.responses[e] > result.responses[e - 1] &&
                            result.responses[e] >= result.responses[e + 1],
                       1:n)
    e_peak === nothing && error(
        "fit_rabi: the measured sweep exhibits no oscillation maximum — the " *
        "declared gain span does not cover the pi-gain (the axis " *
        "[$(result.axis_frac[1]), $(result.axis_frac[end])] fraction rises and " *
        "falls without peaking); re-author the design's span")
    g_peak = result.axis_frac[e_peak]
    step_frac = n > 1 ? result.axis_frac[2] - result.axis_frac[1] : 0.0
    step_frac > 0 || error(
        "fit_rabi: the decoded gain axis does not step — a ladder sweep's " *
        "axis is strictly rising")

    # the payload's envelope integral I_env: the flip-per-fraction scale
    # fixed by the decoded envelope itself (the first expt whose decoded
    # gain is nonzero carries the unit-gain envelope)
    widx = payload.sweep_ladder[1][1]
    step = payload.sweep_ladder[1][3]
    wave = payload.waves[widx]
    gen_ch = payload.port_plan[1][1]
    maxv = payload.gen_cfg[gen_ch].maxv
    e0 = findfirst(e -> wave.gain_code + step * (e - 1) != 0, 1:n)
    e0 === nothing && error(
        "fit_rabi: the decoded axis is all-zero gain — the sweep starts at " *
        "zero and never steps")
    drive = js.translate_drive(payload; expt = e0)
    d = drive[gen_ch]
    g_e0 = (wave.gain_code + step * (e0 - 1)) / maxv
    I_env = sum(sqrt.(d.uI .^ 2 .+ d.uQ .^ 2)) * 1e9 * (d.times[2] - d.times[1]) / g_e0

    # ── the G-curve: the belief-side response at gain x, evaluated by
    # payload-driven rollouts on a gain grid. The grid must cover every
    # gain the candidate bracket rescales the axis to: the drive scale
    # pi/(θ·I) at the bracket's LOW edge is the widest, and the true
    # pi-gain sits within one axis step of the measured first maximum, so
    # the top is g_axis_end scaled by (1 + step/g_peak)/bracket_lo_frac
    # (a hair of margin for the float edges). The grid step is half the
    # ladder's own axis step — the local-quadratic interpolation error
    # ((k·h)³ with k = π/(2·θ) the phase slope in gain) is dust against
    # the shot noise.
    lo = design.bracket_lo_frac * g_peak
    hi = design.bracket_hi_frac * g_peak
    g_top = result.axis_frac[end] * (1 + step_frac / g_peak) / design.bracket_lo_frac
    g_grid_step = step_frac / 2
    n_g = Int(ceil(g_top / g_grid_step)) + 1
    g_nodes = collect(range(0.0, g_top; length = n_g))
    g_nodes[end] = g_top
    g_vals = Dict{Float64,Float64}(
        x => _wire_predict_rabi(rig, bparams, payload, e0, x / g_e0)[2]
        for x in g_nodes)

    # the belief-side model sweep at candidate pi-gain theta: the G-curve
    # read at the theta-rescaled decoded gains (pure interpolation — the
    # cache nodes are cheap, so the grid is dense)
    model_sweep_at(θ) =
        [_quad_eval(g_nodes, g_vals, result.axis_frac[e] * π / (θ * I_env))
         for e in 1:n]
    cache = pc._CertModelCache(model_sweep_at, lo, hi, design.fit_grid_frac * g_peak)
    fit_design = pc.BosonicCertDesign(fit_tol_kHz = design.fit_tol_frac * g_peak)
    θ̂, chi2min, σ, _ = pc._cert_fit_1d(cache, result.responses, result.shots, fit_design)

    tolerance = pc.BOSONIC_CERT_TOLERANCE_SIGMA * σ
    dof = max(n - 1, 1)
    prior = get(belief, "pi_gain", nothing)
    agrees = !(prior isa Real) || abs(θ̂ - Float64(prior)) ≤ tolerance

    # the PiPulseReference companion: the mean-rate convention over the
    # payload's own played window (a pi rotation over the played length)
    facts = payload.gen_cfg[gen_ch]
    played_us = wave.length_cycles * facts.samps_per_clk / (facts.fs_hz * 1e-6)

    return RabiSweepFit(θ̂, σ, tolerance, chi2min / dof, agrees, 0.5 / played_us,
        result.provenance["seed"], rig.twin.record.id,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "record_path" => rig.record_path,
            "design" => "$(n) gain points x $(result.shots) shots; bracket " *
                        "[$(lo), $(hi)] fraction (first max $(g_peak) at expt $e_peak)",
            "tolerance_rule" => string(
                "recovery within $(pc.BOSONIC_CERT_TOLERANCE_SIGMA)·σ; σ from " *
                "the fit's observed binomial information (the model Jacobian " *
                "vs q̂(1−q̂)/N on the payload-driven wire model sweep)"),
            "evidence_class" => "twin-rehearsal",
            "tool" => "Strumento v$(pkgversion(Strumento)), julia $(VERSION)",
        ))
end

"""The `write_back` seam (#38 wraps here): the π-gain lands in the twin's
BELIEF via `calibrate!` — never truth, and never a record parameter (the
belief dict is the calibration-store mirror; `pi_gain` is the first
calibration key beyond the record's parameter set, and the twin contract's
merge semantics admits it without extension — the base contract's
"new keys included" testitem pins the primitive)."""
function write_back!(rig::RehearsalRig, fitres::RabiSweepFit)
    calibrate!(rig.twin, Dict{String,Any}(
        "pi_gain" => fitres.pi_gain,
        "pi_rabi_mhz" => fitres.pi_rabi_mhz,
    ))
    return rig
end

"""
    run_rabi_sweep(rig, design; job = fixture_rabi_job) -> RabiSweepFit

The Rabi chain, one call: propose → compile → run over the wire → fit →
write back. `job` is the compile seam's source: the committed fixture
payload (the default — the Julia-only lane) or a live bridge source (the
PythonCall extension's `compile_rabi_sweep` over the design's
`rabi_geometry`).

Everything is a pure function of (rig, design, job, the twin's seed): a
procedure run replays bit-exactly from its seed across fresh processes (the
replay check: `test/configurations/rabi_replay_check.jl`).
"""
function run_rabi_sweep(rig::RehearsalRig, design::RabiSweepDesign;
                       job = fixture_rabi_job)
    schedule = propose_rabi(rig, design)
    payload_job = job isa Function ? job(rig, schedule) : job
    result = run_rabi_over_wire(rig, schedule, payload_job)
    fitres = fit_rabi(rig, design, result)
    write_back!(rig, fitres)
    return fitres
end

# ─── the procedure testitems (the Julia-only lane: committed fixtures) ───────

@testitem "the resonator sweep recovers chi through the wire within the DERIVED tolerance (the keystone chain)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Strumento: DriftPlan, instantiate, believed, advance!, OrnsteinUhlenbeck
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        # a DRIFTED twin: truth aged off the record (the rehearsal point —
        # the procedure must recover the AGED truth, not the record)
        plan = DriftPlan(:chi_kHz => [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0,
                                                       mu = -298.4)])
        make_rig(seed) = ext.RehearsalRig(record, device, soccfg, wiring;
                                         drift = plan, seed = seed,
                                         overlay_id = "rehearsal-v2")
        rig = make_rig(0xC0FFEE)
        try
            advance!(rig.twin, 3.0)
            truth_chi = rig.twin.truth[:chi_kHz]
            belief_chi = believed(rig.twin)["chi_kHz"]
            @test truth_chi != belief_chi            # the drift moved truth

            design = ext.ResonatorSweepDesign()
            fitres = ext.run_resonator_sweep(rig, design)   # the keystone chain

            # ── the fit is REAL and recovers the truth within the DERIVED
            # tolerance (never a hand-picked one): the tolerance is 5·σ with
            # σ from the fit's observed binomial information
            @test fitres.chi_kHz !== nothing
            @test abs(fitres.chi_kHz - truth_chi) < fitres.chi_tolerance_kHz
            pc = Base.get_extension(Strumento, :StrumentoPiccoloExt)
            @test fitres.chi_tolerance_kHz ≈ pc.BOSONIC_CERT_TOLERANCE_SIGMA *
                                             fitres.chi_sigma_kHz
            @test 0.01 < fitres.chi_sigma_kHz < 2.0   # a real information scale
            # the tolerance MEANS something: 5σ resolves the drift it must catch
            @test fitres.chi_tolerance_kHz < abs(truth_chi - belief_chi)

            # the fit is a real procedure, not a restatement of the generator:
            # the estimate sits off the truth (shot noise) with a sound residual
            @test fitres.chi_kHz != truth_chi
            @test 0.1 < fitres.chi2_dof < 4.0

            # the belief-agreement flag is its DEFINITION: |fit − belief| ≤ tol
            @test fitres.agrees_with_belief ==
                  (abs(fitres.chi_kHz - belief_chi) ≤ fitres.chi_tolerance_kHz)

            # ── the write-back: the fitted parameter lands in the twin's
            # BELIEF via calibrate!; the truth/belief invariant holds live
            @test believed(rig.twin)["chi_kHz"] == fitres.chi_kHz
            @test rig.twin.truth[:chi_kHz] == truth_chi   # truth never moved

            # drift moves truth ONLY: aging the twin leaves the calibrated
            # belief exactly where the write-back put it
            advance!(rig.twin, 1.0)
            @test believed(rig.twin)["chi_kHz"] == fitres.chi_kHz
            @test rig.twin.truth[:chi_kHz] != truth_chi

            # the rehearsal evidence marking: twin-rehearsal, never device results
            @test fitres.provenance["evidence_class"] == "twin-rehearsal"
            @test fitres.seed == 0xC0FFEE
            @test fitres.record_id == rig.twin.record.id

            # ── the propose seam's belief/schedule validation: a grid that
            # misses the believed comb lines is refused actionably
            bad = ext.ResonatorSweepDesign(freqs_kHz = collect(1000.0:10.0:1100.0))
            err = try
                ext.propose(rig, bad); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("does not span", sprint(showerror, err))
        finally
            ext.stop!(rig)
        end

        # ── seeded replay, in-process form: two FRESH rigs (fresh twins,
        # fresh rngs, fresh wires) with the same seed reproduce the whole
        # procedure bit-exactly; a different seed differs
        run_it(seed) = begin
            r = make_rig(seed)
            try
                advance!(r.twin, 3.0)
                ext.run_resonator_sweep(r, ext.ResonatorSweepDesign())
            finally
                ext.stop!(r)
            end
        end
        a = run_it(0x5EED)
        b = run_it(0x5EED)
        c = run_it(0xFEED)
        @test a.chi_kHz == b.chi_kHz && a.chi_sigma_kHz == b.chi_sigma_kHz
        @test a.chi_kHz != c.chi_kHz
    end
end

@testitem "the belief-side wire model == the server's execution (degenerate cross-path pin)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Strumento: DriftPlan, instantiate, believed
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)
        js = Base.get_extension(Strumento, :StrumentoJobServerExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        # EXACT mode: the degenerate case (belief == truth) must drive the
        # predict and the server through two computation paths that agree
        # bit-for-bit — the payload is the single source of truth on both sides.
        rig = ext.RehearsalRig(record, device, soccfg, wiring;
                               drift = DriftPlan(), seed = 0xC0FFEE,
                               overlay_id = "rehearsal-v2", exact = true)
        try
            jobs = ext.fixture_comb_jobs(rig, ext.propose(rig, ext.ResonatorSweepDesign()))
            bparams = Dict{Symbol,Float64}(
                Symbol(k) => Float64(v) for (k, v) in believed(rig.twin) if v isa Real)
            for job in jobs[1:3:end]                     # a stride keeps it quick
                q_pred = ext._wire_predict(rig, bparams, job)
                acq = ext.run_job(rig.client, job.job_wire)
                q_true = acq["iq"][1][1]
                @test [Float64(q_true[1]), Float64(q_true[2])] == collect(q_pred)
            end
        finally
            ext.stop!(rig)
        end
    end
end

@testitem "the seam's named target and the board's honest refusals, through the wire" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Strumento: DriftPlan, believed
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        rig = ext.RehearsalRig(record, device, soccfg, wiring;
                               drift = DriftPlan(), seed = 0xC0FFEE,
                               overlay_id = "rehearsal-v2", exact = true)
        try
            # ── the seam's named target: the stock CavitySpectroscopy payload
            # (compiled against the demo-class device) runs through the wire.
            # Its const cavity probe leaves the ancilla marginal untouched —
            # the honest flat response (cavity transmission is not a
            # v1-twin observable: the probe's carrier is the frame); the
            # resonator sweep's dispersive signature rides the comb.
            cavity = JSON.parsefile(joinpath(fixtures, "_fixtures",
                                             "cavity_rehearsal.json"))
            acq = ext.run_job(rig.client, cavity)
            C = rig.twin.record.noise["readout_confusion"]["value"]
            @test acq["iq"][1][1][1] ≈ C[1][1] atol = 1e-9   # the |g⟩ confusion row
            @test acq["iq"][1][1][2] ≈ C[1][2] atol = 1e-9

            # ── and the comb payload through the same wire: a real excursion
            # (the response is NOT the flat confusion row)
            comb = JSON.parsefile(joinpath(fixtures, "_fixtures",
                                           "comb_rehearsal_04.json"))
            acq_comb = ext.run_job(rig.client, comb)
            @test acq_comb["iq"][1][1][2] > C[1][2] + 0.1

            # ── an unmapped channel is a refused job over the wire: a rig
            # wiring only the qubit channel leaves gen 3 unmapped, and the
            # server's actionable error rides the poll as a failed job
            partial = TwinWiringMap([TwinGenWiring(2, 1, 2; line = "qubit.drive")];
                                    n_drives = 4)
            rig_p = ext.RehearsalRig(record, device, soccfg, partial;
                                     drift = DriftPlan(), seed = 1,
                                     overlay_id = "rehearsal-v2", exact = true)
            try
                err = try
                    ext.run_job(rig_p.client, comb); nothing
                catch e
                    e
                end
                @test err isa ErrorException
                msg = sprint(showerror, err)
                @test occursin("generator channel 3", msg)
                @test occursin("does not map", msg)
            finally
                ext.stop!(rig_p)
            end
        finally
            ext.stop!(rig)
        end
    end
end

# ─── The Rabi procedure (issue #33, the M4a-2 pi-gain calibration) ───────────────
#
# The amplitude-domain counterpart of the resonator sweep: the drive gain
# swept over the wire (ONE payload — the swept axis rides the payload's
# CloseLoop gain ladder, the v1-wire swept form), the ancilla oscillation
# Pe(gain) fitted against the payload-driven belief-side model, the π-gain
# extracted with a DERIVED tolerance, and the entry written back as the
# `pi_gain` BELIEF key — the first calibration beyond the record's
# parameter set (the D17 amplitude ruler: the entry the pulse side
# consumes).
#
# The belief-key contract decision (documented, issue #33's assumption
# verified): the twin's belief dict is the calibration-store MIRROR — it
# starts as the record's parameters and `calibrate!` MERGES, so a
# calibration key beyond the record's parameter set enters without any
# contract extension (the base contract's "new keys included" testitem pins
# the primitive). `pi_gain` is therefore a BELIEF entry, never a record
# parameter and never a truth key: records carry device truth templates;
# calibrations live in the store/belief.

@testitem "the Rabi procedure recovers the pi-gain through the wire within the DERIVED tolerance (the belief entry)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Strumento: DriftPlan, instantiate, believed, advance!, calibrate!,
                         OrnsteinUhlenbeck
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)
        js = Base.get_extension(Strumento, :StrumentoJobServerExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        # a DRIFTED twin (the rehearsal posture): truth aged off the record.
        # The pi-gain is the amplitude ruler — drift in chi does not move it
        # (the ancilla is driven in vacuum), but the aged twin is the honest
        # world the procedure runs against, and the invariants are asserted
        # live below.
        plan = DriftPlan(:chi_kHz => [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0,
                                                        mu = -298.4)])
        make_rig(seed) = ext.RehearsalRig(record, device, soccfg, wiring;
                                         drift = plan, seed = seed,
                                         overlay_id = "rehearsal-v2")
        rig = make_rig(0xC0FFEE)
        try
            advance!(rig.twin, 3.0)
            truth_chi = rig.twin.truth[:chi_kHz]
            n_truth = length(rig.twin.truth)
            design = ext.RabiSweepDesign()

            # the pi_gain entry is NOT on the record: the belief starts as the
            # record's 7 parameters, and no pi_gain exists yet (the first
            # calibration beyond the record's parameter set)
            @test !haskey(believed(rig.twin), "pi_gain")
            @test !any(==(Symbol("pi_gain")), keys(rig.twin.truth))

            fitres = ext.run_rabi_sweep(rig, design)   # propose -> wire -> fit -> write back

            # the fit's own analytic truth, DERIVED from the payload (never a
            # captured literal): the payload's decoded envelope fixes the
            # flip-per-fraction scale I, so the twin's pi-gain is exactly
            # pi/I (the model's drive-scale parameter equals 1 there)
            payload = js.read_payload(rig.server.soccfg,
                                      JSON.parsefile(joinpath(fixtures, "_fixtures",
                                                              "rabi_rehearsal.json")))
            drive = js.translate_drive(payload; expt = 2)
            gen = collect(keys(drive))[1]
            d = drive[gen]
            g2 = payload.waves[payload.sweep_ladder[1][1]].gain_code +
                 payload.sweep_ladder[1][3]
            I_env = sum(sqrt.(d.uI .^ 2 .+ d.uQ .^ 2)) * 1e9 *
                    (d.times[2] - d.times[1]) / (g2 / 32766)
            theta_true = π / I_env

            # ── the fit is REAL and recovers the truth within the DERIVED
            # tolerance (never a hand-picked one): 5·sigma, sigma from the
            # fit's observed binomial information
            pc = Base.get_extension(Strumento, :StrumentoPiccoloExt)
            @test fitres.pi_gain !== nothing
            @test abs(fitres.pi_gain - theta_true) < fitres.pi_gain_tolerance
            @test fitres.pi_gain_tolerance ≈ pc.BOSONIC_CERT_TOLERANCE_SIGMA *
                                             fitres.pi_gain_sigma
            @test 1e-9 < fitres.pi_gain_sigma < 1e-4      # a real information scale
            # the tolerance MEANS something: 5·sigma is far finer than the
            # ladder's own axis step (the fit interpolates inside a step)
            axis_step_frac = 3 / 32766
            @test fitres.pi_gain_tolerance < axis_step_frac

            # the fit is a real procedure, not a restatement of the geometry:
            # the estimate sits off the truth (shot noise) with a sound residual
            @test fitres.pi_gain != theta_true
            @test 0.1 < fitres.chi2_dof < 4.0

            # the belief-agreement flag is its DEFINITION: with no prior
            # pi_gain belief there is nothing to disagree with
            @test fitres.agrees_with_belief

            # ── the write-back: the belief entry lands via calibrate!;
            # believed reflects it; the truth/belief invariants hold live
            b = believed(rig.twin)
            @test b["pi_gain"] == fitres.pi_gain
            @test b["pi_rabi_mhz"] == fitres.pi_rabi_mhz
            # the PiPulseReference pair: the mean-rate convention over the
            # payload's own played window (the gauss's 50 cycles at fs)
            played_us = payload.waves[1].length_cycles *
                        payload.gen_cfg[collect(keys(payload.gen_cfg))[1]].samps_per_clk /
                        (payload.gen_cfg[collect(keys(payload.gen_cfg))[1]].fs_hz * 1e-6)
            @test fitres.pi_rabi_mhz ≈ 0.5 / played_us
            # pi_gain is a BELIEF key beyond the record's parameter set —
            # the extra-key contract: the belief grew past the record, the
            # truth did not (calibrations are not record truth)
            @test length(b) == 9                       # the record's 7 + the ruler pair
            @test length(rig.twin.truth) == n_truth    # truth keys untouched
            @test !any(==(Symbol("pi_gain")), keys(rig.twin.truth))
            @test !any(==(Symbol("pi_rabi_mhz")), keys(rig.twin.truth))
            @test rig.twin.truth[:chi_kHz] == truth_chi   # truth never moved

            # drift moves truth ONLY: aging the twin leaves the calibrated
            # belief exactly where the write-back put it
            advance!(rig.twin, 1.0)
            @test believed(rig.twin)["pi_gain"] == fitres.pi_gain
            @test rig.twin.truth[:chi_kHz] != truth_chi

            # the rehearsal evidence marking: twin-rehearsal, never device results
            @test fitres.provenance["evidence_class"] == "twin-rehearsal"
            @test fitres.seed == 0xC0FFEE
            @test fitres.record_id == rig.twin.record.id

            # ── the propose seam's validation: a design whose declared axis
            # is degenerate or mismatched is refused actionably
            err = try
                ext.propose_rabi(rig, ext.RabiSweepDesign(gains_stop = 0)); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("exceed", sprint(showerror, err))
            err = try
                ext.propose_rabi(rig, ext.RabiSweepDesign(points = 2)); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("at least 3", sprint(showerror, err))

            # the declared-vs-decoded axis check: a design whose declared
            # span differs from the payload the wire actually runs is refused
            # (the payload is the single source of truth — the fit's axis is
            # the DECODED one). This design passes propose (an integral 3-code
            # step over 31 points) but is not the fixture's geometry.
            err = try
                ext.run_rabi_sweep(rig, ext.RabiSweepDesign(gains_stop = 90, points = 31));
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("does not match", sprint(showerror, err))

            # ── a RE-CALIBRATION against the prior belief: the second run's
            # agrees_with_belief is computed against the written-back entry
            fit2 = ext.run_rabi_sweep(rig, design)
            @test fit2.agrees_with_belief ==
                  (abs(fit2.pi_gain - fitres.pi_gain) ≤ fit2.pi_gain_tolerance)
            @test fit2.agrees_with_belief          # a sound recalibration agrees

            # ── the propose seam's belief-span validation (recalibration
            # support): once the belief carries pi_gain, a sweep that does
            # not span it is refused — the belief and the schedule disagree
            # (an integral 1-code step, so the shape checks pass and the
            # span check is what fires)
            err = try
                ext.propose_rabi(rig, ext.RabiSweepDesign(gains_stop = 40, points = 41));
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("does not span", sprint(showerror, err))
        finally
            ext.stop!(rig)
        end

        # ── seeded replay, in-process form: two FRESH rigs with the same
        # seed reproduce the whole procedure bit-exactly; a different seed
        # differs (the shot draws)
        run_it(seed) = begin
            r = make_rig(seed)
            try
                advance!(r.twin, 3.0)
                ext.run_rabi_sweep(r, ext.RabiSweepDesign())
            finally
                ext.stop!(r)
            end
        end
        a = run_it(0x5EED)
        b_replay = run_it(0x5EED)
        c = run_it(0xFEED)
        @test a.pi_gain == b_replay.pi_gain && a.pi_gain_sigma == b_replay.pi_gain_sigma
        @test a.pi_rabi_mhz == b_replay.pi_rabi_mhz
        @test a.pi_gain != c.pi_gain
    end
end

@testitem "the Rabi belief-side wire model == the server's execution (degenerate cross-path pin)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Strumento: DriftPlan, believed
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)
        js = Base.get_extension(Strumento, :StrumentoJobServerExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        # EXACT mode: the degenerate case (belief == truth, drive scale 1)
        # must drive the predict and the server through two computation
        # paths that agree bit-for-bit — the payload is the single source of
        # truth on both sides, per expt on the whole ladder.
        rig = ext.RehearsalRig(record, device, soccfg, wiring;
                               drift = DriftPlan(), seed = 0xC0FFEE,
                               overlay_id = "rehearsal-v2", exact = true)
        try
            wire = JSON.parsefile(joinpath(fixtures, "_fixtures", "rabi_rehearsal.json"))
            payload = js.read_payload(rig.server.soccfg, wire)
            bparams = Dict{Symbol,Float64}(
                Symbol(k) => Float64(v) for (k, v) in believed(rig.twin) if v isa Real)
            for e in 1:5:length(payload.expts)             # a stride keeps it quick
                q_pred = ext._wire_predict_rabi(rig, bparams, payload, e, 1.0)
                acq = ext.run_job(rig.client, wire)
                q_true = acq["iq"][1][1][e]
                @test [Float64(q_true[1]), Float64(q_true[2])] == collect(q_pred)
            end
        finally
            ext.stop!(rig)
        end
    end
end

@testitem "the calibrated pi_gain beats the uncalibrated baseline through the wire (the paired downstream proof, python-optional)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing ||
       Base.identify_package("PythonCall") === nothing
        @info "skipping: the downstream proof needs Piccolo + JSON + PythonCall in this environment"
        @test true
    else
        using PythonCall
        ENV["PYTHONUTF8"] = "1"
        st = try
            pyimport("strumento")
        catch e
            @info "skipping: Python `strumento` not importable in this environment ($e)"
            nothing
        end
        if st === nothing
            @test true   # vacuous pass: the pure-Julia CI lane carries no Python strumento
        else
            using Piccolo
            using JSON
            using Strumento: DriftPlan, believed, advance!, OrnsteinUhlenbeck
            ext = Base.get_extension(Strumento, :StrumentoBringupExt)
            pext = Base.get_extension(Strumento, :StrumentoPythonCallExt)
            js = Base.get_extension(Strumento, :StrumentoJobServerExt)

            fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
            record = joinpath(fixtures, "twins", "bosonic.md")
            device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
            soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
            wiring = TwinWiringMap([
                TwinGenWiring(2, 1, 2; line = "qubit.drive"),
                TwinGenWiring(3, 3, 4; line = "manipulate.main"),
            ]; n_drives = 4)

            # ── first: the fit's honest refusal on a sweep that never peaks
            # (a short live ladder below the pi-gain — the span does not
            # cover it; needs the LIVE compile because the fixture carries
            # the committed 0..120 geometry)
            rig_short = ext.RehearsalRig(record, device, soccfg, wiring;
                                         drift = DriftPlan(), seed = 7,
                                         overlay_id = "rehearsal-v2")
            try
                bridge = pext.BringupBridge(device; overlay_id = "rehearsal-v2")
                short_design = ext.RabiSweepDesign(gains_stop = 30, points = 11)
                live_job(r, s) = begin
                    wire = pext.compile_rabi_sweep(bridge;
                                                  ext.rabi_geometry(short_design)...)
                    ext.RabiJob(wire, ext._job_shots(r, wire))
                end
                err = try
                    ext.run_rabi_sweep(rig_short, short_design; job = live_job); nothing
                catch e
                    e
                end
                @test err isa ErrorException
                @test occursin("no oscillation maximum", sprint(showerror, err))
            finally
                ext.stop!(rig_short)
            end

            # ── THE PAIRED PROOF. Two FRESH rigs, the SAME seed, the SAME
            # drift path, aged identically — everything but the gain
            # calibration is shared. The calibrated rig runs the Rabi
            # procedure (the LIVE bridge lane: Python compiles the sweep,
            # the wire executes, Julia fits and writes the belief); the
            # baseline rig gets no calibration at all. Then the same
            # downstream compile — the ge_pi factory — runs through both
            # wires: at the BELIEVED pi_gain on the calibrated side, at the
            # device calibration's own stale gain on the baseline side.
            plan = DriftPlan(:chi_kHz => [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0,
                                                            mu = -298.4)])
            make_rig(seed; exact = false) =
                ext.RehearsalRig(record, device, soccfg, wiring;
                                drift = plan, seed = seed, overlay_id = "rehearsal-v2",
                                exact = exact)
            bridge2 = pext.BringupBridge(device; overlay_id = "rehearsal-v2")
            design = ext.RabiSweepDesign()

            rig_cal = make_rig(0xBEEF)
            rig_base = make_rig(0xBEEF)
            rig_cal_x = make_rig(0xBEEF; exact = true)
            rig_base_x = make_rig(0xBEEF; exact = true)
            try
                for r in (rig_cal, rig_base, rig_cal_x, rig_base_x)
                    advance!(r.twin, 3.0)
                end
                # the PAIRING invariant: same seed, same drift path — the
                # four twins carry one truth
                @test rig_cal.twin.truth == rig_base.twin.truth ==
                      rig_cal_x.twin.truth == rig_base_x.twin.truth
                @test !haskey(believed(rig_base.twin), "pi_gain")   # no calibration yet

                # the calibrated side: the whole loop — live sweep compile
                # -> wire -> fit -> belief
                live_design_job(r, s) = begin
                    wire = pext.compile_rabi_sweep(bridge2; ext.rabi_geometry(design)...)
                    ext.RabiJob(wire, ext._job_shots(r, wire))
                end
                fitres = ext.run_rabi_sweep(rig_cal, design; job = live_design_job)
                @test believed(rig_cal.twin)["pi_gain"] == fitres.pi_gain
                @test fitres.provenance["evidence_class"] == "twin-rehearsal"

                # the downstream compiles: the ge_pi factory at the believed
                # gain (the belief-scaled path — the fraction the
                # calibration store carries) vs the uncalibrated baseline
                # (the device calibration's own stale gain)
                cal_wire = pext.compile_ge_pi(bridge2;
                                              gain_frac = believed(rig_cal.twin)["pi_gain"],
                                              reps = 50, soft_avgs = 1)
                base_wire = pext.compile_ge_pi(bridge2; reps = 50, soft_avgs = 1)
                @test base_wire == JSON.parsefile(joinpath(fixtures, "_fixtures",
                                                          "gepi_baseline_rehearsal.json"))

                # the belief lands on the true pi DAC CODE: the payload's
                # own envelope fixes the flip-per-fraction scale I_env, so
                # the twin's true pi-gain is pi/I_env — and the believed
                # fraction quantizes onto its code (the calibration is
                # REAL at wire resolution)
                payload = js.read_payload(rig_cal.server.soccfg,
                                          JSON.parsefile(joinpath(fixtures, "_fixtures",
                                                                 "rabi_rehearsal.json")))
                drive = js.translate_drive(payload; expt = 2)
                d = drive[collect(keys(drive))[1]]
                g2 = payload.waves[payload.sweep_ladder[1][1]].gain_code +
                     payload.sweep_ladder[1][3]
                I_env = sum(sqrt.(d.uI .^ 2 .+ d.uQ .^ 2)) * 1e9 *
                        (d.times[2] - d.times[1]) / (g2 / 32766)
                theta_true = π / I_env
                cal_code = only([w["gain"] for w in cal_wire["program"]["waves"]])
                @test cal_code == Int(round(theta_true * 32766))

                # the paired responses, sampled (the measurement world) and
                # exact (the deterministic truth of the same pair)
                pe(rig, wire) = begin
                    acq = ext.run_job(rig.client, wire)
                    return Float64(acq["iq"][1][1][2])
                end
                Pe_cal = pe(rig_cal, cal_wire)
                Pe_base = pe(rig_base, base_wire)
                Pe_cal_x = pe(rig_cal_x, cal_wire)
                Pe_base_x = pe(rig_base_x, base_wire)

                # the CALIBRATED one wins — sampled and exact, and the win
                # is decisive against the paired shot noise
                @test Pe_cal > Pe_base
                @test Pe_cal_x > Pe_base_x
                shots = rig_cal.soc.shots * 50
                σ_pair = sqrt(max(Pe_cal * (1 - Pe_cal), 1e-9) / shots +
                              max(Pe_base * (1 - Pe_base), 1e-9) / shots)
                @test Pe_cal - Pe_base > 10 * σ_pair

                # the calibrated flip reaches the readout's own ceiling
                # (the record's confusion row for |e⟩ — semantic, computed
                # from the record, never captured) within 5 points, and the
                # baseline mis-flips by a decisive margin
                C = rig_cal.twin.record.noise["readout_confusion"]["value"]
                @test Pe_cal_x ≥ C[2][2] - 0.05
                @test Pe_base_x ≤ Pe_cal_x - 0.25

                # the sampled pair agrees with its exact truth (the
                # measurement is the deterministic response plus noise)
                @test abs(Pe_cal - Pe_cal_x) < 5 *
                      sqrt(max(Pe_cal * (1 - Pe_cal), 1e-9) / shots)
                @test abs(Pe_base - Pe_base_x) < 5 *
                      sqrt(max(Pe_base * (1 - Pe_base), 1e-9) / shots)

                # the calibration moved belief only: the calibrated twin's
                # truth is the baseline twin's truth, still
                @test rig_cal.twin.truth == rig_base.twin.truth
            finally
                for r in (rig_cal, rig_base, rig_cal_x, rig_base_x)
                    ext.stop!(r)
                end
            end
        end
    end
end

@testitem "the resonator sweep through the LIVE bridge: Python compile -> wire -> fit -> write-back (python-optional)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing ||
       Base.identify_package("PythonCall") === nothing
        @info "skipping: the bridge-driven chain needs Piccolo + JSON + PythonCall in this environment"
        @test true
    else
        using PythonCall
        ENV["PYTHONUTF8"] = "1"
        st = try
            pyimport("strumento")
        catch e
            @info "skipping: Python `strumento` not importable in this environment ($e)"
            nothing
        end
        if st === nothing
            @test true   # vacuous pass: the pure-Julia CI lane carries no Python strumento
        else
            using Piccolo
            using JSON
            using Strumento: DriftPlan, believed, advance!, OrnsteinUhlenbeck
            ext = Base.get_extension(Strumento, :StrumentoBringupExt)
            pext = Base.get_extension(Strumento, :StrumentoPythonCallExt)

            fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
            record = joinpath(fixtures, "twins", "bosonic.md")
            device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
            soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
            wiring = TwinWiringMap([
                TwinGenWiring(2, 1, 2; line = "qubit.drive"),
                TwinGenWiring(3, 3, 4; line = "manipulate.main"),
            ]; n_drives = 4)

            plan = DriftPlan(:chi_kHz => [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0,
                                                           mu = -298.4)])
            rig = ext.RehearsalRig(record, device, soccfg, wiring;
                                   drift = plan, seed = 0x1234,
                                   overlay_id = "rehearsal-v2")
            try
                advance!(rig.twin, 2.0)
                truth_chi = rig.twin.truth[:chi_kHz]
                design = ext.ResonatorSweepDesign()

                # the compile seam's LIVE lane: every schedule point compiled
                # in-process through the bridge (the cqed pack's own factories
                # + the core compile path), submitted over the wire — never
                # Python-side execution
                bridge = pext.BringupBridge(device; overlay_id = "rehearsal-v2")
                jobs = (r, s) -> ext.point_jobs(
                    f -> pext.compile_comb_point(bridge; ext.comb_geometry(design)...,
                                                 f_kHz = f), r, s)
                fitres = ext.run_resonator_sweep(rig, design; jobs = jobs)

                # the recovery holds through the live-compiled payloads: the
                # AGED truth, within the DERIVED tolerance
                @test abs(fitres.chi_kHz - truth_chi) < fitres.chi_tolerance_kHz
                @test fitres.provenance["evidence_class"] == "twin-rehearsal"

                # the write-back landed in the belief
                @test believed(rig.twin)["chi_kHz"] == fitres.chi_kHz
                @test rig.twin.truth[:chi_kHz] == truth_chi

                # the live payloads ARE the committed fixtures (the fixture
                # lane and the bridge lane are one code path): the recovery
                # through the fixtures matches within the fit's own
                # resolution-scale — both lanes fit the same twin
                rig2 = ext.RehearsalRig(record, device, soccfg, wiring;
                                        drift = plan, seed = 0x1234,
                                        overlay_id = "rehearsal-v2")
                try
                    advance!(rig2.twin, 2.0)
                    fitres2 = ext.run_resonator_sweep(rig2, design)
                    @test abs(fitres.chi_kHz - fitres2.chi_kHz) <
                          3 * max(fitres.chi_sigma_kHz, fitres2.chi_sigma_kHz)
                finally
                    ext.stop!(rig2)
                end
            finally
                ext.stop!(rig)
            end
        end
    end
end

# ─── The Ramsey procedure (issue #37, the M4a-3 calibration set) ────────────────
#
# The detuning calibration: the ancilla π/2–delay–π/2 fringe vs delay over the
# wire, the detuning fit, and the `detuning_kHz` belief entry — the frame
# offset no prior procedure measures. THE ENVELOPE-RIDE LAW (verified against
# the pack's own T1/T2Ramsey experiments, read-only): a swept DELAY compiles to
# tProc TIME/register arithmetic (REG_WR r_k + #step inside the expts loop —
# the compiler's swept-Delay "time-param" site), which the M3a payload reader
# DEFERS: the expts axis is realized from the declared loop structure, but
# per-expt VALUES ride the CloseLoop wave-memory ladder, which v1 realizes for
# GAIN steps only — a swept-delay payload replays the identical envelope every
# expt and the delay is invisible. The wire-realizable form of a swept time
# axis is the ENVELOPE ITSELF: each delay point is ONE payload whose single
# wave carries [half-π arm, in-wave silence gap of `delay_samples` zeros,
# half-π arm] — time-domain, not carrier (the frame law governs: the carrier is
# the frame; delays ride the envelope) — one job per schedule point, the comb
# precedent.
#
# The fringe: the twin's detuning truth (the optional `:detuning_kHz` family
# key, issue #37 — the record's frame is nominal, so the hidden truth is seeded
# into truth directly, the certify_parameter_recovery perturbation idiom
# extended to a key the record does not carry) precesses the ancilla during the
# gap, and the second half-π maps the accumulated phase onto the e-frequency.
# The precession during the ARM time shifts the fringe's minimum off
# 1/(2Δτ) — the fit never assumes the analytic phase: the model sweep rolls
# the DECODED payload envelopes at the candidate detuning (the payload-driven
# discipline — the model predicts exactly what the server executes).
#
# The G-curve applicability call (the issue asks; documented either way): the
# idiom does NOT apply here. The Rabi G-curve worked because the swept pulse's
# shape is FIXED and the candidate enters as a linear drive scale — one
# response curve read at θ-rescaled gains, exactly. The Ramsey response is
# not one curve read at Δ-rescaled delays: each delay point is a DIFFERENT
# payload (the gap rides the envelope — there is no single probe response
# curve to rescale), and the candidate detuning enters as a Hamiltonian term
# that also tilts the half-π arms' rotation axes (Δ/Ω), so
# response(τ; Δ) ≠ G(Δτ) — the pulse unitaries carry Δ. The honest fit is the
# certification class's per-point payload-driven model cache (the comb
# pattern), one rollout per (node × delay point).
#
# The fit: the certification fit class (`_CertModelCache` + `_cert_fit_1d`,
# one fitter home), weighted binomial χ² against the payload-driven
# belief-side model sweep over a DATA-anchored detuning bracket — the anchor
# is the fringe's first measured minimum, parabolic-refined on the DECODED
# delay axis, Δ_anchor = 1/(2·τ_min) — widened by the design's multipliers (the
# arm-time precession shifts τ_min, so the multipliers must straddle generously).
# σ from the fit's observed information, the recovery tolerance
# `BOSONIC_CERT_TOLERANCE_SIGMA`·σ (5σ, never hand-picked).
#
# The belief key: `detuning_kHz` — a calibration BEYOND the record's parameter
# set (the pi_gain precedent; calibrate! merges new keys), never a record
# parameter (the record's frame is nominal — it carries no detuning), never
# truth. THE COMPOSITION ORDER this motivates: the detuned twin shifts every
# ancilla transition by Δ, so the comb's χ-fit (whose model would carry a
# stale-frame belief) is biased until the detuning lands in belief — the
# calibration set runs Ramsey FIRST (the Ramsey is the one procedure
# insensitive to the others: the cavity sits in vacuum, and its arms are
# envelope-authored, not gain-calibrated). See `run_calibration_set`.

"""
    RamseyDesign(; kwargs...) -> RamseyDesign

The Ramsey procedure's pinned design — the arm geometry, the delay grid, and
the fit's data-anchored bracket parameters.

The arms: envelope-authored sin² half-π pulses of length `T_hp_us` (peak drive
fraction `probe_gain = π/(T_hp_us·1000)`, the comb probe's by-construction
flip convention: ∫A·sin²dτ = π/2) on the ancilla quadratures at the fixed
carrier `qubit_freq_mhz` (the frame).

The delay grid: `delays_samples` — the schedule's swept axis in the wire's
lab-native unit, ENVELOPE SAMPLES (integer by construction: the decoded axis
is exactly the declared one; the fixture payloads are compiled at the
rehearsal overlay's 12.5 samples/μs). The committed default (9 points,
0:64:512 samples = 0..40.96 μs in 5.12-μs steps) resolves the fringe at the
rehearsal twin's detuning scale (tens of kHz: the first minimum sits near
25 μs) with ≥5 points per fringe half-period.

The fit (all anchors DERIVED from the measured fringe, never absolute
hand-picked spans): the bracket is `[bracket_lo_frac, bracket_hi_frac] ×`
Δ_anchor (the parabolic-refined first minimum; the arm-time precession biases
the anchor high by ~20%, so the multipliers straddle wider than the Rabi's) —
the θ-model cache steps `fit_grid_step_kHz`; the golden section refines to
`fit_tol_frac ×` Δ_anchor.

The π/2–delay–π/2 probe shape is FIXED (only the gap length steps along the
schedule), but the G-curve idiom does NOT apply — see the section docstring:
each point is a different payload and the detuning tilts the arms, so the fit
evaluates the payload-driven model sweep per node (the comb pattern), not one
rescaled response curve.
"""
struct RamseyDesign
    T_hp_us::Float64
    delays_samples::Vector{Int}
    probe_gain::Float64
    qubit_freq_mhz::Float64
    reps::Int
    soft_avgs::Int
    bracket_lo_frac::Float64
    bracket_hi_frac::Float64
    fit_grid_step_kHz::Float64
    fit_tol_frac::Float64
end

function RamseyDesign(; T_hp_us = 4.0, delays_samples = collect(0:64:512),
                      probe_gain = π / (4.0 * 1000.0), qubit_freq_mhz = 4.0,
                      reps = 50, soft_avgs = 1,
                      bracket_lo_frac = 0.55, bracket_hi_frac = 1.35,
                      fit_grid_step_kHz = 0.6, fit_tol_frac = 1 / 20000)
    T_hp_us > 0 || error("RamseyDesign: T_hp_us must be > 0 (got $T_hp_us)")
    probe_gain > 0 || error("RamseyDesign: probe_gain must be > 0 (got $probe_gain)")
    qubit_freq_mhz > 0 || error(
        "RamseyDesign: qubit_freq_mhz must be > 0 (got $qubit_freq_mhz)")
    isempty(delays_samples) && error("RamseyDesign: delays_samples must be non-empty")
    all(>=(0), delays_samples) || error(
        "RamseyDesign: delays_samples must be ≥ 0 (the fringe's first point " *
        "is the zero-delay reference)")
    issorted(delays_samples) || error("RamseyDesign: delays_samples must be sorted")
    allunique(delays_samples) || error(
        "RamseyDesign: delays_samples must be unique (the decoded axis steps)")
    length(delays_samples) ≥ 5 || error(
        "RamseyDesign: the delay grid needs at least 5 points (a maximum, the " *
        "fringe's falling flank, a minimum, its rising flank, and resolution)")
    reps ≥ 1 || error("RamseyDesign: reps must be ≥ 1 (got $reps)")
    soft_avgs ≥ 1 || error("RamseyDesign: soft_avgs must be ≥ 1 (got $soft_avgs)")
    (0 < bracket_lo_frac < 1 < bracket_hi_frac) || error(
        "RamseyDesign: the bracket multipliers must straddle the first " *
        "minimum's anchor (0 < bracket_lo_frac < 1 < bracket_hi_frac; got " *
        "[$bracket_lo_frac, $bracket_hi_frac])")
    fit_grid_step_kHz > 0 || error(
        "RamseyDesign: fit_grid_step_kHz must be > 0 (got $fit_grid_step_kHz)")
    0 < fit_tol_frac || error("RamseyDesign: fit_tol_frac must be > 0 (got $fit_tol_frac)")
    return RamseyDesign(Float64(T_hp_us), Int.(delays_samples), Float64(probe_gain),
        Float64(qubit_freq_mhz), Int(reps), Int(soft_avgs), Float64(bracket_lo_frac),
        Float64(bracket_hi_frac), Float64(fit_grid_step_kHz), Float64(fit_tol_frac))
end

"""The design's declared delay axis in microseconds (decoded from the wire's
lab-native envelope samples at the rig's fabric rate)."""
ramsey_axis_us(rig::RehearsalRig, design::RamseyDesign) =
    [s / (rig.soc.dac_rate * 1000.0) for s in design.delays_samples]

"""The design's arm + delay geometry as the bridge's compile contract (the
`compile_ramsey_point` keyword block — the same constants the committed
fixture-generation script carries)."""
ramsey_geometry(design::RamseyDesign) = (
    T_hp_us = design.T_hp_us,
    probe_gain = design.probe_gain,
    qubit_freq_mhz = design.qubit_freq_mhz,
    reps = design.reps,
    soft_avgs = design.soft_avgs,
)

"""The Ramsey schedule (the `propose_ramsey` seam's output): the declared
delay axis (μs, decoded at the rig's fabric rate) and the provenance the
supervision layer (#38) wraps."""
struct RamseySchedule
    delays_us::Vector{Float64}
    provenance::Dict{String,Any}
end

"""One Ramsey point's compiled job: its wire payload (the single wave carrying
half-π arm, the in-wave silence gap, half-π arm — the envelope-ride law) with
the accumulated shot count (`soc shots × payload reps × soft_avgs`)."""
struct RamseyJob
    delay_samples::Int
    job_wire::Dict{String,Any}
    shots::Int
end

"""The Ramsey fringe's measured responses (the `run_ramsey_over_wire` seam's
output): the schedule, its jobs, the per-point e-outcome frequency on the
DECODED delay axis, and the rehearsal provenance."""
struct RamseyResult
    schedule::RamseySchedule
    jobs::Vector{RamseyJob}
    responses::Vector{Float64}
    delays_us::Vector{Float64}
    provenance::Dict{String,Any}
end

"""The Ramsey fit's outcome: the fitted detuning (kHz) with its derived
information scale, the 5σ recovery tolerance, the fit quality, the
belief-agreement gate (against a prior `detuning_kHz` belief when one exists
— the first calibration has nothing to disagree with), and the rehearsal
provenance (mirrors `ResonatorSweepFit`)."""
struct RamseyFit
    detuning_kHz::Float64
    detuning_sigma_kHz::Float64
    detuning_tolerance_kHz::Float64
    chi2_dof::Float64
    agrees_with_belief::Bool
    seed::Any
    record_id::String
    provenance::Dict{String,Any}
end

"""The `propose_ramsey` seam (#38 wraps here): (belief + schedule) -> the
declared delay axis, validated. On a RE-CALIBRATION (the belief already
carries `detuning_kHz`) the grid must RESOLVE the believed detuning's fringe:
the window must reach its first minimum (`Δ·τ_max ≥ ½ cycle`) and the grid
must step finer than a sixth of its period (the first calibration has no
believed detuning to resolve; the fit's own first-minimum check is what
refuses a window that misses the truth)."""
function propose_ramsey(rig::RehearsalRig, design::RamseyDesign)
    delays_us = ramsey_axis_us(rig, design)
    prior = get(believed(rig.twin), "detuning_kHz", nothing)
    if prior isa Real
        Δ = Float64(prior)
        τmax = delays_us[end]
        Δ * τmax * 1e-3 ≥ 0.5 || error(
            "propose_ramsey: the declared delay window [0, $(τmax) μs] does not " *
            "reach the believed detuning's first fringe minimum (the belief's " *
            "detuning_kHz = $Δ wants τ ≈ $(1 / (2Δ * 1e-3)) μs) — the belief and " *
            "the schedule disagree; re-author the grid or recalibrate the belief")
        step = length(delays_us) > 1 ? delays_us[2] - delays_us[1] : 0.0
        step > 0 && Δ * step * 1e-3 ≤ 1 / 6 || error(
            "propose_ramsey: the declared delay grid steps $(step) μs — coarser " *
            "than a sixth of the believed detuning's fringe period " *
            "($(1 / (Δ * 1e-3)) μs at detuning_kHz = $Δ); the fringe would alias")
    end
    return RamseySchedule(
        delays_us,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "overlay_id" => rig.overlay_id,
            "device_path" => rig.device_path,
            "evidence_class" => "twin-rehearsal",
        ),
    )
end

"""The compile seam's fixture lane: the committed Ramsey payloads (the
Julia-only path — CI without Python `strumento` runs the whole procedure
against them; the bridge testitem pins that the live Python compile reproduces
them bit-exactly). One payload per schedule point, index-ordered — the
committed grid's own order."""
function fixture_ramsey_jobs(rig::RehearsalRig, schedule::RamseySchedule)
    fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
    jobs = RamseyJob[]
    for i in 1:length(schedule.delays_us)
        path = joinpath(fixtures, "ramsey_rehearsal_$(lpad(i - 1, 2, '0')).json")
        isfile(path) || error(
            "fixture_ramsey_jobs: the committed fixture $path is missing — the " *
            "fixture lane expects one payload per delay point (regenerate with " *
            "test/fixtures/_fixtures/generate_rehearsal_payloads.py)")
        job = JSON.parsefile(path)
        push!(jobs, RamseyJob(0, job, _job_shots(rig, job)))
    end
    return jobs
end

"""The `run_ramsey_over_wire` seam (#38 wraps here): run each delay point's
payload over the wire (the production shape — the socket, never in-process
server calls) and reduce each `RawAcquisition` to the per-point e-outcome
frequency. The payload is the single source of truth on the DELAY AXIS: one
played generator (the ancilla drive), one wave whose envelope carries the
whole sequence, and its decoded length must equal the declared arm+gap
geometry — a payload compiled against a different grid is refused (the fit's
axis is the DECODED one, never the declared)."""
function run_ramsey_over_wire(rig::RehearsalRig, schedule::RamseySchedule,
                              design::RamseyDesign, jobs::Vector{RamseyJob})
    js = _jobserver_ext()
    length(jobs) == length(schedule.delays_us) || error(
        "run_ramsey_over_wire: $(length(jobs)) compiled jobs for " *
        "$(length(schedule.delays_us)) schedule points — one payload per point")
    n_hp = round(Int, design.T_hp_us * rig.soc.dac_rate * 1000.0)
    n_hp ≥ 1 || error(
        "run_ramsey_over_wire: the arm geometry T_hp_us = $(design.T_hp_us) " *
        "decodes to $n_hp envelope samples at the rig's fabric rate — a played " *
        "arm must have positive extent")
    responses = Float64[]
    delays_us = Float64[]
    for (i, job) in enumerate(jobs)
        payload = js.read_payload(rig.server.soccfg, job.job_wire)
        payload.expts === nothing || error(
            "run_ramsey_over_wire: the payload declares an expts axis — the " *
            "Ramsey delay axis is the ENVELOPE (one payload per point; a swept " *
            "delay is wire-deferred in v1 — see the section docstring)")
        length(payload.port_plan) == 1 && length(payload.port_plan[1][2]) == 1 || error(
            "run_ramsey_over_wire: the payload plays $(length(payload.port_plan)) " *
            "generators — the Ramsey probe is one ancilla drive wave")
        wave = payload.waves[payload.port_plan[1][2][1]]
        nsamp = wave.length_cycles * payload.gen_cfg[payload.port_plan[1][1]].samps_per_clk
        # the decoded delay: the wave's whole played length minus the two arms
        # — validated against the declared grid (the payload is the single
        # source of truth on the axis)
        delay_samples = nsamp - 2 * n_hp
        delay_samples == design.delays_samples[i] || error(
            "run_ramsey_over_wire: the design's declared delay " *
            "$(design.delays_samples[i]) samples does not match the payload's " *
            "decoded gap ($delay_samples samples, wave length $nsamp = " *
            "$(2 * n_hp) arm + gap) — compile the design's own grid (the bridge " *
            "lane) or re-author the design to the committed geometry")
        acq = run_job(rig.client, job.job_wire)
        iq = get(acq, "iq", nothing)
        (iq isa AbstractVector && length(iq) == 1 && length(iq[1]) == 1 &&
         length(iq[1][1]) == 2) || error(
            "run_ramsey_over_wire: the per-point acquisition must be one read's " *
            "(I, Q) pair (the twin's v1 one-readout response)")
        push!(responses, Float64(iq[1][1][2]))
        push!(delays_us, delay_samples / (rig.soc.dac_rate * 1000.0))
    end
    return RamseyResult(schedule, jobs, responses, delays_us,
        Dict{String,Any}(
            "schedule_provenance" => schedule.provenance,
            "evidence_class" => "twin-rehearsal",
            "seed" => rig.seed,
            "overlay_id" => rig.overlay_id,
            "twin_time_days" => rig.twin.t,
        ))
end

# The belief-side wire model over a raw wire payload (the `_wire_predict`
# body, split so the Ramsey jobs — which are not BringupJobs — share it; the
# comb's original signature is a thin wrapper, unchanged).
function _wire_predict_wire(rig::RehearsalRig, params::Dict{Symbol,Float64},
                            job_wire::AbstractDict)
    js = _jobserver_ext()
    payload = js.read_payload(rig.server.soccfg, job_wire)
    drives = js.translate_drive(payload)
    nsamp = maximum(length(d.times) for d in values(drives))
    gen_chs = sort(collect(keys(drives)))
    routing, n_drives = js._payload_routing(rig.server, gen_chs)
    times = [1e9 * (i - 1) / payload.gen_cfg[gen_chs[1]].fs_hz for i in 1:nsamp]
    ctrls = zeros(Float64, n_drives, nsamp)
    for (gen_ch, i_drive, q_drive) in routing
        d = drives[gen_ch]
        pad = zeros(nsamp - length(d.times))
        ctrls[i_drive, :] .= vcat(d.uI, pad)
        q_drive === nothing || (ctrls[q_drive, :] .= vcat(d.uQ, pad))
    end
    recon = LinearSplinePulse(ctrls, times)

    # the family system at the CANDIDATE (belief-side) parameters — the fit
    # never sees the twin's truth — with the soc's own confusion (the record's
    # readout model) and the soc's own remap arithmetic (the degenerate
    # belief == truth case must reproduce the server's exact response
    # BIT-for-bit, and the two accumulation orders differ in the last ulp).
    system = rig.families[rig.twin.record.family](params)
    ψ = rig.soc.ψ_init
    ρ0 = ψ * ψ'
    qtraj = DensityTrajectory(system, recon, ρ0, ρ0)
    p = rig.measurement_fn(Piccolo.density_to_iso_vec(qtraj(times[end])))
    confusion = _piccolo_ext()._record_confusion(rig.twin)
    return [sum(confusion[i, j] * p[i] for i in eachindex(p)) for j in eachindex(p)]
end

"""The `fit_ramsey` seam (#38 wraps here): the certification fit class —
weighted binomial χ² of the measured fringe against the payload-driven
belief-side model sweep over the DATA-anchored detuning bracket
(`_CertModelCache` + `_cert_fit_1d`, the Piccolo extension's fit home — one
fitter, no duplication), σ from the fit's own observed information, the
recovery tolerance `BOSONIC_CERT_TOLERANCE_SIGMA`·σ.

The bracket anchors on the fringe's FIRST measured minimum — the π/2–π/2
fringe starts at its maximum, so the first minimum sits at the half-period —
parabolic-refined on the decoded delay axis, `Δ_anchor = 1/(2·τ_min)`. The
arm-time precession shifts the minimum (the analytic 1/(2Δ) does NOT hold
exactly), so the anchor is a bracket-centering heuristic only (the design's
multipliers straddle generously); the FIT itself is payload-driven and
assumes nothing about the phase. A fringe that never dips is refused
actionably (the window does not resolve the detuning)."""
function fit_ramsey(rig::RehearsalRig, design::RamseyDesign, result::RamseyResult)
    pc = _piccolo_ext()
    belief = believed(rig.twin)
    bparams = Dict{Symbol,Float64}(
        Symbol(k) => Float64(v) for (k, v) in belief if v isa Real)
    n = length(result.responses)
    n == length(result.delays_us) || error(
        "fit_ramsey: $(n) measured responses on a $(length(result.delays_us))—" *
        "point axis — one response per decoded delay point")

    # every job's accumulated shots (the binomial weights); constant by
    # construction of the schedule, and validated so
    shots = unique([job.shots for job in result.jobs])
    length(shots) == 1 || error(
        "fit_ramsey: the schedule's payloads carry different accumulated shot " *
        "counts ($(shots)) — the fit's binomial weights need one count")
    shots[1] ≥ 1 || error("fit_ramsey: the accumulated shot count must be ≥ 1")

    # the data anchor: the fringe's first measured minimum, parabolic-refined
    # on the decoded delay axis
    e_min = findfirst(e -> 2 <= e <= n - 1 &&
                            result.responses[e] < result.responses[e - 1] &&
                            result.responses[e] <= result.responses[e + 1],
                       1:n)
    e_min === nothing && error(
        "fit_ramsey: the measured fringe exhibits no minimum — the declared " *
        "delay window [0, $(result.delays_us[end])] μs does not resolve the " *
        "detuning's half-period; re-author the grid (lengthen the window)")
    τ = result.delays_us
    y = result.responses
    denom = y[e_min - 1] - 2y[e_min] + y[e_min + 1]
    off = abs(denom) < 1e-12 ? 0.0 : 0.5 * (y[e_min - 1] - y[e_min + 1]) / denom
    τ_min = τ[e_min] + off * (τ[e_min + 1] - τ[e_min - 1]) / 2
    τ_min > 0 || error(
        "fit_ramsey: the fringe's first minimum sits at τ ≤ 0 — the measured " *
        "response is not a Ramsey fringe on this axis")
    anchor_kHz = 1 / (2τ_min * 1e-3)
    lo = design.bracket_lo_frac * anchor_kHz
    hi = design.bracket_hi_frac * anchor_kHz

    # the belief-side model sweep at candidate detuning: the payload-driven
    # prediction, one per schedule point (each point's own envelope — the
    # arms AND the gap — rolled at the candidate parameters)
    model_sweep_at(θ) =
        [_wire_predict_wire(rig, merge(bparams, Dict{Symbol,Float64}(:detuning_kHz => θ)),
                            job.job_wire)[2] for job in result.jobs]
    cache = pc._CertModelCache(model_sweep_at, lo, hi, design.fit_grid_step_kHz)
    fit_design = pc.BosonicCertDesign(fit_tol_kHz = design.fit_tol_frac * anchor_kHz)
    Δ̂, chi2min, σ, _ = pc._cert_fit_1d(cache, result.responses, shots[1], fit_design)

    tolerance = pc.BOSONIC_CERT_TOLERANCE_SIGMA * σ
    dof = max(n - 1, 1)
    prior = get(belief, "detuning_kHz", nothing)
    agrees = !(prior isa Real) || abs(Δ̂ - Float64(prior)) ≤ tolerance
    return RamseyFit(Δ̂, σ, tolerance, chi2min / dof, agrees,
        result.provenance["seed"], rig.twin.record.id,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "record_path" => rig.record_path,
            "design" => "$(n) delay points x $(shots[1]) shots; bracket " *
                        "[$(lo), $(hi)] kHz (first min $(round(τ_min; digits=2)) μs)",
            "tolerance_rule" => string(
                "recovery within $(pc.BOSONIC_CERT_TOLERANCE_SIGMA)·σ; σ from " *
                "the fit's observed binomial information (the model Jacobian " *
                "vs q̂(1−q̂)/N on the payload-driven wire model sweep)"),
            "evidence_class" => "twin-rehearsal",
            "tool" => "Strumento v$(pkgversion(Strumento)), julia $(VERSION)",
        ))
end

"""The `write_back` seam (#38 wraps here): the fitted detuning lands in the
twin's BELIEF via `calibrate!` — never truth, and never a record parameter
(the record's frame is nominal: it carries no detuning key; the entry is the
first frame calibration beyond the record's parameter set, the pi_gain
precedient's merge contract)."""
function write_back!(rig::RehearsalRig, fitres::RamseyFit)
    calibrate!(rig.twin, Dict{String,Any}("detuning_kHz" => fitres.detuning_kHz))
    return rig
end

"""
    run_ramsey_sweep(rig, design; jobs = fixture_ramsey_jobs) -> RamseyFit

The Ramsey chain, one call: propose → compile → run over the wire → fit →
write back. `jobs` is the compile seam's source: the committed fixture
payloads (the default — the Julia-only lane) or a live bridge source (the
PythonCall extension's `compile_ramsey_point` over the design's
`ramsey_geometry`, one payload per delay point).

Everything is a pure function of (rig, design, jobs, the twin's seed): a
procedure run replays bit-exactly from its seed across fresh processes (the
replay check: `test/configurations/calibration_replay_check.jl`).
"""
function run_ramsey_sweep(rig::RehearsalRig, design::RamseyDesign;
                         jobs = fixture_ramsey_jobs)
    schedule = propose_ramsey(rig, design)
    payloads = jobs isa Function ? jobs(rig, schedule) : jobs
    result = run_ramsey_over_wire(rig, schedule, design, payloads)
    fitres = fit_ramsey(rig, design, result)
    write_back!(rig, fitres)
    return fitres
end

# the live bridge lane's job source: a per-point compiler (delay samples ->
# wire Dict — the bridge's `compile_ramsey_point` over the design's geometry)
# wrapped into a job source for `run_ramsey_sweep`.
function ramsey_point_jobs(compile_point, rig::RehearsalRig,
                           schedule::RamseySchedule, design::RamseyDesign)
    jobs = RamseyJob[]
    for (i, s) in enumerate(design.delays_samples)
        wire = compile_point(s)
        push!(jobs, RamseyJob(s, wire, _job_shots(rig, wire)))
    end
    return jobs
end

@testitem "the Ramsey procedure recovers the detuning through the wire within the DERIVED tolerance (the frame belief entry)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Strumento: DriftPlan, instantiate, believed, advance!, calibrate!,
                         OrnsteinUhlenbeck
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)
        js = Base.get_extension(Strumento, :StrumentoJobServerExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        # a DRIFTED twin (the rehearsal posture) whose truth also carries the
        # seeded DETUNING — the hidden-truth discipline: the record's frame
        # is nominal (it carries no detuning parameter; the family's optional
        # key defaults to 0), so the truth is seeded directly, exactly the
        # certify_parameter_recovery perturbation idiom extended to a key
        # the record does not carry. The calibration must find it.
        plan = DriftPlan(:chi_kHz => [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0,
                                                        mu = -298.4)])
        make_rig(seed) = ext.RehearsalRig(record, device, soccfg, wiring;
                                         drift = plan, seed = seed,
                                         overlay_id = "rehearsal-v2")
        rig = make_rig(0xC0FFEE)
        try
            advance!(rig.twin, 3.0)
            rig.twin.truth[:detuning_kHz] = 20.0        # the hidden frame offset
            truth_chi = rig.twin.truth[:chi_kHz]
            n_truth = length(rig.twin.truth)
            design = ext.RamseyDesign()

            # the detuning entry is NOT on the record: the belief starts as
            # the record's 7 parameters (the frame is nominal — nothing to
            # disagree with), and the truth carries the seeded key
            @test !haskey(believed(rig.twin), "detuning_kHz")
            @test !any(==(Symbol("detuning_kHz")), keys(rig.twin.record.parameters))

            fitres = ext.run_ramsey_sweep(rig, design)   # propose -> wire -> fit -> write back

            # ── the fit is REAL and recovers the seeded truth within the
            # DERIVED tolerance (never a hand-picked one): 5·σ, σ from the
            # fit's observed binomial information
            pc = Base.get_extension(Strumento, :StrumentoPiccoloExt)
            @test fitres.detuning_kHz !== nothing
            @test abs(fitres.detuning_kHz - 20.0) < fitres.detuning_tolerance_kHz
            @test fitres.detuning_tolerance_kHz ≈ pc.BOSONIC_CERT_TOLERANCE_SIGMA *
                                             fitres.detuning_sigma_kHz
            @test 1e-5 < fitres.detuning_sigma_kHz < 0.5  # a real information scale
            # the fit is a real procedure, not a restatement of the truth: the
            # estimate sits off the truth (shot noise) with a sound residual
            @test fitres.detuning_kHz != 20.0
            @test 0.1 < fitres.chi2_dof < 4.0

            # the belief-agreement flag is its DEFINITION: with no prior
            # detuning belief there is nothing to disagree with
            @test fitres.agrees_with_belief

            # ── the write-back: the belief entry lands via calibrate!;
            # believed reflects it; the truth/belief invariants hold live
            @test believed(rig.twin)["detuning_kHz"] == fitres.detuning_kHz
            # the detuning is a BELIEF key beyond the record's parameter set
            # (the pi_gain precedent); truth is untouched by the calibration
            @test length(believed(rig.twin)) == 8       # the record's 7 + the frame
            @test length(rig.twin.truth) == n_truth     # truth keys untouched
            @test rig.twin.truth[:detuning_kHz] == 20.0
            @test rig.twin.truth[:chi_kHz] == truth_chi

            # drift moves truth ONLY: aging the twin leaves the calibrated
            # belief exactly where the write-back put it
            advance!(rig.twin, 1.0)
            @test believed(rig.twin)["detuning_kHz"] == fitres.detuning_kHz
            @test rig.twin.truth[:chi_kHz] != truth_chi

            # the rehearsal evidence marking: twin-rehearsal, never device results
            @test fitres.provenance["evidence_class"] == "twin-rehearsal"
            @test fitres.seed == 0xC0FFEE
            @test fitres.record_id == rig.twin.record.id

            # ── a RE-CALIBRATION against the prior belief: the second run's
            # agrees_with_belief is computed against the written-back entry
            fit2 = ext.run_ramsey_sweep(rig, design)
            @test fit2.agrees_with_belief ==
                  (abs(fit2.detuning_kHz - fitres.detuning_kHz) ≤
                       fit2.detuning_tolerance_kHz)
            @test fit2.agrees_with_belief          # a sound recalibration agrees

            # ── the propose seam's belief/schedule validation: once the belief
            # carries the detuning, a window that cannot resolve its fringe
            # is refused — the belief and the schedule disagree (a SHORT grid:
            # the shape checks pass, the resolvability check is what fires)
            err = try
                ext.propose_ramsey(rig, ext.RamseyDesign(
                    delays_samples = collect(0:8:32))); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("first fringe minimum", sprint(showerror, err))

            # ── the run seam's decoded-axis refusal: a design whose declared
            # grid differs from the payloads the wire actually runs is refused
            # (the payload is the single source of truth — the fit's axis is
            # the DECODED one). This grid is sample-integral and sorted (the
            # shape checks pass) but is not the committed geometry.
            err = try
                ext.run_ramsey_sweep(rig, ext.RamseyDesign(
                    delays_samples = collect(0:48:384))); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("does not match", sprint(showerror, err))
            # (the fit's honest "no minimum" refusal on a fringe that never
            # dips needs a live compile of a short window — the fixture lane
            # runs the committed geometry only; it is pinned in the bridge
            # testitem, the Rabi short-ladder precedent)
        finally
            ext.stop!(rig)
        end

        # ── seeded replay, in-process form: two FRESH rigs (fresh twins,
        # fresh rngs, fresh wires) with the same seed reproduce the whole
        # procedure bit-exactly; a different seed differs (the shot draws)
        run_it(seed) = begin
            r = make_rig(seed)
            try
                advance!(r.twin, 3.0)
                r.twin.truth[:detuning_kHz] = 20.0
                ext.run_ramsey_sweep(r, ext.RamseyDesign())
            finally
                ext.stop!(r)
            end
        end
        a = run_it(0x5EED)
        b = run_it(0x5EED)
        c = run_it(0xFEED)
        @test a.detuning_kHz == b.detuning_kHz
        @test a.detuning_sigma_kHz == b.detuning_sigma_kHz
        @test a.detuning_kHz != c.detuning_kHz
    end
end

@testitem "the Ramsey belief-side wire model == the server's execution (degenerate cross-path pin)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Strumento: DriftPlan, believed
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)
        js = Base.get_extension(Strumento, :StrumentoJobServerExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        # EXACT mode: the degenerate case (belief == truth, the seeded
        # detuning included) must drive the predict and the server through
        # two computation paths that agree bit-for-bit — the payload is the
        # single source of truth on both sides, per delay point.
        rig = ext.RehearsalRig(record, device, soccfg, wiring;
                               drift = DriftPlan(), seed = 0xC0FFEE,
                               overlay_id = "rehearsal-v2", exact = true)
        try
            rig.twin.truth[:detuning_kHz] = 20.0
            schedule = ext.propose_ramsey(rig, ext.RamseyDesign())
            jobs = ext.fixture_ramsey_jobs(rig, schedule)
            bparams = Dict{Symbol,Float64}(
                Symbol(k) => Float64(v) for (k, v) in believed(rig.twin) if v isa Real)
            merge!(bparams, Dict{Symbol,Float64}(:detuning_kHz => 20.0))
            for job in jobs[1:3:end]                     # a stride keeps it quick
                q_pred = ext._wire_predict_wire(rig, bparams, job.job_wire)
                acq = ext.run_job(rig.client, job.job_wire)
                q_true = acq["iq"][1][1]
                @test [Float64(q_true[1]), Float64(q_true[2])] == collect(q_pred)
            end
        finally
            ext.stop!(rig)
        end
    end
end

# ─── The T1 procedure (issue #37, the M4a-3 calibration set) ────────────────────
#
# The decay calibration: the ancilla π–delay–measure decay curve over the
# wire, the exponential fit, and the `T1_q_us` belief entry. The same
# envelope-ride law as the Ramsey (swept delays are wire-deferred in v1): one
# payload per delay point, the by-construction π excitation and the in-wave
# silence gap both inside ONE wave's envelope.
#
# THE FIT IS A JUSTIFIED SIBLING of the certification class (the issue's
# one-fitter-home rule: the certification class where it fits, justified
# siblings in the same module otherwise), and the justification is exact:
# for this payload class the response model is a CLOSED FORM. The window is
# [π excitation, silence]: during the silence the family's Hamiltonian is
# diagonal on the ancilla (the cavity sits in vacuum — the χ and Kerr terms
# vanish — and the detuning, when the truth carries one, commutes with
# populations), so the excited population decays at EXACTLY the ancilla T1
# rate: p_e(τ) = F·e^(−τ/T1), with F the pulse-end transfer (the flip and its
# during-pulse decay — τ-independent, a free nuisance). Through the believed
# readout confusion's second column the measured e-frequency is
#
#     q_e(τ) = C₁₂ + (C₂₂ − C₁₂) · F · e^(−τ/T1)
#
# with C the BELIEVED confusion (the record's placeholder until the
# confusion procedure lands its entry — the composed pass runs T1 first,
# where both are the record's and the form is exact; a re-run after the
# confusion calibration carries the measured rows, the honest loop). The
# model is linear in F: the fit profiles F analytically (weighted linear
# least squares per candidate T1) and golden-sections T1 over a data-anchored
# bracket. σ(T1) comes from the profiled 2×2 observed information (the same
# Fisher discipline as the certification class — per-point binomial weights
# q̂(1−q̂)/shots against the analytic model's numeric Jacobian), the recovery
# tolerance `BOSONIC_CERT_TOLERANCE_SIGMA`·σ. The exactness is pinned by the
# testitem: the wire's exact-mode response matches the closed form to the
# integrator's tolerance on every delay point.
#
# THE BELIEF KEY and the record's estimate-flagged placeholder: `T1_q_us` is
# a belief entry beyond the record's PARAMETER set (the record carries T1 in
# its NOISE map, wrapped {value, estimate: true, note} — a synthetic
# typical-of-class PLACEHOLDER nothing could ever replace; the noise map does
# not enter the twin's belief at instantiate). The procedure's write-back
# supersedes the placeholder IN BELIEF ONLY — the calibrate! merge lands the
# measured value in the belief store; the RECORD itself is never edited
# (records change by vault commit, never by procedure — the twin contract),
# and the twin's TRUTH keeps rolling on the record's value (decay is a
# static-from-record device property in v1: drift plans move Hamiltonian
# truth only — the family builder closes over the record's noise at factory
# time). The calibration is therefore exact in v1 and the recovery assertion
# is against the record's value; on a device whose T1 had aged, the belief
# would carry the measured value while the twin's truth kept the record's —
# the drift-aware scheduling (M4a-4) is the slice that owns that gap.

"""
    T1Design(; kwargs...) -> T1Design

The T1 procedure's pinned design — the excitation geometry, the delay grid,
and the fit's data-anchored bracket parameters.

The excitation: an envelope-authored sin² π pulse of length `T_pi_us` (peak
drive fraction `probe_gain = 2π/(T_pi_us·1000)`, the comb probe's
by-construction flip convention) on the ancilla quadratures at the fixed
carrier `qubit_freq_mhz` (the frame).

The delay grid: `delays_samples` — the swept axis in the wire's lab-native
unit, ENVELOPE SAMPLES (integer by construction: the decoded axis is exactly
the declared one). The committed default (9 points, 0..240 μs at the record's
T1_q_us scale: 0, 20, 40, 60, 90, 120, 160, 200, 240 μs at the rehearsal
overlay's 12.5 samples/μs) spans the decay's information range (~2·T1).

The fit (the anchor DERIVED from the measured decay, never a hand-picked
span): the bracket is `[bracket_lo_frac, bracket_hi_frac] ×` T1_anchor, the
anchor from the measured half-excursion — the first delay whose response
falls below half the first point's excursion above the believed g-row
asymptote, T1_anchor = τ_half/ln(2). The analytic model makes the bracket's
grid cost zero (no model cache: the fit evaluates the closed form), so the
multipliers straddle generously.
"""
struct T1Design
    T_pi_us::Float64
    delays_samples::Vector{Int}
    probe_gain::Float64
    qubit_freq_mhz::Float64
    reps::Int
    soft_avgs::Int
    bracket_lo_frac::Float64
    bracket_hi_frac::Float64
    fit_tol_frac::Float64
end

function T1Design(; T_pi_us = 4.0,
                   delays_samples = [0, 250, 500, 750, 1125, 1500, 2000, 2500, 3000],
                   probe_gain = 2π / (4.0 * 1000.0), qubit_freq_mhz = 4.0,
                   reps = 50, soft_avgs = 1,
                   bracket_lo_frac = 0.5, bracket_hi_frac = 2.0,
                   fit_tol_frac = 1 / 10000)
    T_pi_us > 0 || error("T1Design: T_pi_us must be > 0 (got $T_pi_us)")
    probe_gain > 0 || error("T1Design: probe_gain must be > 0 (got $probe_gain)")
    qubit_freq_mhz > 0 || error(
        "T1Design: qubit_freq_mhz must be > 0 (got $qubit_freq_mhz)")
    isempty(delays_samples) && error("T1Design: delays_samples must be non-empty")
    all(>=(0), delays_samples) || error(
        "T1Design: delays_samples must be ≥ 0 (the decay's first point is " *
        "the zero-delay reference)")
    issorted(delays_samples) || error("T1Design: delays_samples must be sorted")
    allunique(delays_samples) || error(
        "T1Design: delays_samples must be unique (the decoded axis steps)")
    length(delays_samples) ≥ 4 || error(
        "T1Design: the delay grid needs at least 4 points (the transfer, the " *
        "decay's flank, its tail, and resolution)")
    reps ≥ 1 || error("T1Design: reps must be ≥ 1 (got $reps)")
    soft_avgs ≥ 1 || error("T1Design: soft_avgs must be ≥ 1 (got $soft_avgs)")
    (0 < bracket_lo_frac < 1 < bracket_hi_frac) || error(
        "T1Design: the bracket multipliers must straddle the half-excursion " *
        "anchor (0 < bracket_lo_frac < 1 < bracket_hi_frac; got " *
        "[$bracket_lo_frac, $bracket_hi_frac])")
    0 < fit_tol_frac || error("T1Design: fit_tol_frac must be > 0 (got $fit_tol_frac)")
    return T1Design(Float64(T_pi_us), Int.(delays_samples), Float64(probe_gain),
        Float64(qubit_freq_mhz), Int(reps), Int(soft_avgs), Float64(bracket_lo_frac),
        Float64(bracket_hi_frac), Float64(fit_tol_frac))
end

"""The design's declared delay axis in microseconds (decoded from the wire's
lab-native envelope samples at the rig's fabric rate)."""
t1_axis_us(rig::RehearsalRig, design::T1Design) =
    [s / (rig.soc.dac_rate * 1000.0) for s in design.delays_samples]

"""The design's excitation geometry as the bridge's compile contract (the
`compile_t1_point` keyword block — the same constants the committed
fixture-generation script carries)."""
t1_geometry(design::T1Design) = (
    T_pi_us = design.T_pi_us,
    probe_gain = design.probe_gain,
    qubit_freq_mhz = design.qubit_freq_mhz,
    reps = design.reps,
    soft_avgs = design.soft_avgs,
)

"""The T1 schedule (the `propose_t1` seam's output): the declared delay axis
(μs, decoded at the rig's fabric rate) and the provenance the supervision
layer (#38) wraps."""
struct T1Schedule
    delays_us::Vector{Float64}
    provenance::Dict{String,Any}
end

"""One T1 point's compiled job: its wire payload (the single wave carrying
the π excitation and the in-wave silence gap) with the accumulated shot
count."""
struct T1Job
    delay_samples::Int
    job_wire::Dict{String,Any}
    shots::Int
end

"""The T1 decay's measured responses (the `run_t1_over_wire` seam's output):
the schedule, its jobs, the per-point e-outcome frequency on the DECODED
delay axis, and the rehearsal provenance."""
struct T1Result
    schedule::T1Schedule
    jobs::Vector{T1Job}
    responses::Vector{Float64}
    delays_us::Vector{Float64}
    provenance::Dict{String,Any}
end

"""The T1 fit's outcome: the fitted T1 (μs) with its derived information
scale, the 5σ recovery tolerance, the fit quality, the belief-agreement gate
(against a prior `T1_q_us` belief when one exists — the record's noise
placeholder does not enter belief, so the first calibration has nothing to
disagree with), and the rehearsal provenance."""
struct T1Fit
    T1_us::Float64
    T1_sigma_us::Float64
    T1_tolerance_us::Float64
    chi2_dof::Float64
    agrees_with_belief::Bool
    seed::Any
    record_id::String
    provenance::Dict{String,Any}
end

"""The `propose_t1` seam (#38 wraps here): (belief + schedule) -> the
declared delay axis, validated. On a RE-CALIBRATION (the belief carries
`T1_q_us`) the window must reach the believed T1's half-decay
(`τ_max ≥ ln(2)·T1` — the fit's data anchor is the half-excursion point); the
first calibration has no believed T1 to reach, and the fit's own
half-excursion check refuses a window that misses the decay."""
function propose_t1(rig::RehearsalRig, design::T1Design)
    delays_us = t1_axis_us(rig, design)
    prior = get(believed(rig.twin), "T1_q_us", nothing)
    if prior isa Real
        T1 = Float64(prior)
        T1 > 0 || error(
            "propose_t1: the believed T1_q_us must be > 0 (got $T1) — a decay " *
            "time is positive")
        delays_us[end] ≥ log(2) * T1 || error(
            "propose_t1: the declared delay window [0, $(delays_us[end])] μs does " *
            "not reach the believed T1's half-decay (ln(2)·T1 ≈ " *
            "$(round(log(2) * T1; digits = 2)) μs at T1_q_us = $T1) — the belief " *
            "and the schedule disagree; re-author the grid or recalibrate")
    end
    return T1Schedule(
        delays_us,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "overlay_id" => rig.overlay_id,
            "device_path" => rig.device_path,
            "evidence_class" => "twin-rehearsal",
        ),
    )
end

"""The compile seam's fixture lane: the committed T1 payloads (the Julia-only
path; the bridge testitem pins the live compile against them bit-exactly)."""
function fixture_t1_jobs(rig::RehearsalRig, schedule::T1Schedule)
    fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
    jobs = T1Job[]
    for i in 1:length(schedule.delays_us)
        path = joinpath(fixtures, "t1_rehearsal_$(lpad(i - 1, 2, '0')).json")
        isfile(path) || error(
            "fixture_t1_jobs: the committed fixture $path is missing — the " *
            "fixture lane expects one payload per delay point (regenerate with " *
            "test/fixtures/_fixtures/generate_rehearsal_payloads.py)")
        job = JSON.parsefile(path)
        push!(jobs, T1Job(0, job, _job_shots(rig, job)))
    end
    return jobs
end

"""The `run_t1_over_wire` seam (#38 wraps here): run each delay point's
payload over the wire and reduce to the per-point e-outcome frequency, with
the same decoded-axis validation as the Ramsey (the payload is the single
source of truth — the fit's axis is the DECODED one)."""
function run_t1_over_wire(rig::RehearsalRig, schedule::T1Schedule,
                          design::T1Design, jobs::Vector{T1Job})
    js = _jobserver_ext()
    length(jobs) == length(schedule.delays_us) || error(
        "run_t1_over_wire: $(length(jobs)) compiled jobs for " *
        "$(length(schedule.delays_us)) schedule points — one payload per point")
    n_pi = round(Int, design.T_pi_us * rig.soc.dac_rate * 1000.0)
    n_pi ≥ 1 || error(
        "run_t1_over_wire: the excitation geometry T_pi_us = $(design.T_pi_us) " *
        "decodes to $n_pi envelope samples at the rig's fabric rate — a played " *
        "pulse must have positive extent")
    responses = Float64[]
    delays_us = Float64[]
    for (i, job) in enumerate(jobs)
        payload = js.read_payload(rig.server.soccfg, job.job_wire)
        payload.expts === nothing || error(
            "run_t1_over_wire: the payload declares an expts axis — the T1 " *
            "delay axis is the ENVELOPE (one payload per point; a swept delay " *
            "is wire-deferred in v1 — see the Ramsey section)")
        length(payload.port_plan) == 1 && length(payload.port_plan[1][2]) == 1 || error(
            "run_t1_over_wire: the payload plays $(length(payload.port_plan)) " *
            "generators — the T1 excitation is one ancilla drive wave")
        wave = payload.waves[payload.port_plan[1][2][1]]
        nsamp = wave.length_cycles * payload.gen_cfg[payload.port_plan[1][1]].samps_per_clk
        delay_samples = nsamp - n_pi
        delay_samples == design.delays_samples[i] || error(
            "run_t1_over_wire: the design's declared delay " *
            "$(design.delays_samples[i]) samples does not match the payload's " *
            "decoded gap ($delay_samples samples, wave length $nsamp = " *
            "$n_pi pulse + gap) — compile the design's own grid (the bridge " *
            "lane) or re-author the design to the committed geometry")
        acq = run_job(rig.client, job.job_wire)
        iq = get(acq, "iq", nothing)
        (iq isa AbstractVector && length(iq) == 1 && length(iq[1]) == 1 &&
         length(iq[1][1]) == 2) || error(
            "run_t1_over_wire: the per-point acquisition must be one read's " *
            "(I, Q) pair (the twin's v1 one-readout response)")
        push!(responses, Float64(iq[1][1][2]))
        push!(delays_us, delay_samples / (rig.soc.dac_rate * 1000.0))
    end
    return T1Result(schedule, jobs, responses, delays_us,
        Dict{String,Any}(
            "schedule_provenance" => schedule.provenance,
            "evidence_class" => "twin-rehearsal",
            "seed" => rig.seed,
            "overlay_id" => rig.overlay_id,
            "twin_time_days" => rig.twin.t,
        ))
end

# The T1 sibling fit's closed form (the justified sibling — see the section
# docstring): q_e(τ) = c₁ + (c₂ − c₁)·F·e^(−τ/T1), evaluated per delay point
# on the DECODED axis. c₁, c₂ are the believed confusion's second-column
# entries (the g-row and e-row e-outcome frequencies).
function _t1_model(c1::Real, c2::Real, F::Real, T1::Real, τ::AbstractVector)
    return [c1 + (c2 - c1) * F * exp(-t / T1) for t in τ]
end

"""The `fit_t1` seam (#38 wraps here): the JUSTIFIED SIBLING of the
certification class — the exponential fit (weighted binomial χ² of the
measured decay against the closed-form response model, see the section
docstring), the transfer F profiled analytically per candidate T1, golden
section over the data-anchored bracket, σ(T1) from the profiled 2×2 observed
information (the same Fisher discipline), the recovery tolerance
`BOSONIC_CERT_TOLERANCE_SIGMA`·σ."""
function fit_t1(rig::RehearsalRig, design::T1Design, result::T1Result)
    pc = _piccolo_ext()
    belief = believed(rig.twin)
    # the believed confusion's second column (the record's placeholder until
    # the confusion procedure lands its entry — one read path, the cert
    # machinery's own belief-side confusion reader)
    C = pc._cert_belief_confusion(rig.twin)
    size(C) == (2, 2) || error(
        "fit_t1: the believed readout confusion is $(size(C)) — the T1 " *
        "response model serves the 2-outcome ancilla readout")
    c1, c2 = C[1, 2], C[2, 2]
    c2 > c1 || error(
        "fit_t1: the believed confusion's e-outcome column is monotone " *
        "(C₁₂ = $c1 ≥ C₂₂ = $c2) — the decay contrast is negative; the belief's " *
        "readout confusion is inconsistent with an excited-state decay")
    n = length(result.responses)
    n == length(result.delays_us) || error(
        "fit_t1: $(n) measured responses on a $(length(result.delays_us))-point " *
        "axis — one response per decoded delay point")
    shots = unique([job.shots for job in result.jobs])
    length(shots) == 1 || error(
        "fit_t1: the schedule's payloads carry different accumulated shot " *
        "counts ($(shots)) — the fit's binomial weights need one count")
    shots[1] ≥ 1 || error("fit_t1: the accumulated shot count must be ≥ 1")
    N = shots[1]

    τ = result.delays_us
    y = result.responses
    σ² = [max(q * (1 - q), 1e-9) / N for q in y]     # the measured binomial variances

    # the data anchor: the measured half-excursion — the first delay whose
    # response falls below half the FIRST point's excursion above the
    # believed g-row asymptote (τ = 0 is the transfer reference; the
    # excursion above c₁ decays as e^(−τ/T1))
    y0 = y[1] - c1
    y0 > 0 || error(
        "fit_t1: the measured response at the first delay sits at or below " *
        "the believed g-row asymptote (q̂ = $(y[1]) vs C₁₂ = $c1) — no decay " *
        "excursion to fit; is the excitation landing?")
    k_half = findfirst(k -> y[k] - c1 < y0 / 2, 1:n)
    k_half === nothing && error(
        "fit_t1: the measured decay never halves its excursion within the " *
        "declared window [0, $(τ[end])] μs — the delay grid does not reach the " *
        "decay's half-time; re-author the grid")
    # interpolate the half-excursion crossing between the bracketing points
    frac = ((y[k_half - 1] - c1) - y0 / 2) / ((y[k_half - 1] - c1) - (y[k_half] - c1))
    frac = clamp(frac, 0.0, 1.0)     # the crossing sits between the bracketing points
    τ_half = τ[k_half - 1] + frac * (τ[k_half] - τ[k_half - 1])
    anchor_us = τ_half / log(2)
    lo = design.bracket_lo_frac * anchor_us
    hi = design.bracket_hi_frac * anchor_us
    fit_tol = design.fit_tol_frac * anchor_us

    # χ²(T1) with the transfer profiled analytically: the model is LINEAR in
    # the contrast-absorbed transfer G = (C₂₂−C₁₂)·F (q_e = C₁₂ + G·x), so
    # per candidate T1 the weighted linear least squares Ĝ is closed-form
    function chi2_profiled(T1)
        T1 > 0 || return Inf, 0.0
        x = [exp(-t / T1) for t in τ]
        sw = sum(x[k]^2 / σ²[k] for k in 1:n)
        sw > 0 || return Inf, 0.0
        Ĝ = sum(x[k] * (y[k] - c1) / σ²[k] for k in 1:n) / sw
        return sum((y[k] - (c1 + Ĝ * x[k]))^2 / σ²[k] for k in 1:n), Ĝ
    end
    gr = (sqrt(5) - 1) / 2
    a, b = lo, hi
    c = b - gr * (b - a); d = a + gr * (b - a)
    fc = first(chi2_profiled(c)); fd = first(chi2_profiled(d))
    while (b - a) > fit_tol
        if fc < fd
            b, d, fd = d, c, fc
            c = b - gr * (b - a); fc = first(chi2_profiled(c))
        else
            a, c, fc = c, d, fd
            d = a + gr * (b - a); fd = first(chi2_profiled(d))
        end
    end
    T̂1 = (a + b) / 2
    chi2min, Ĝ = chi2_profiled(T̂1)
    # the reported transfer is the pulse-end population F (the contrast-
    # absorbed G unwound through the believed confusion's column contrast)
    F̂ = Ĝ / (c2 - c1)

    # the profiled 2×2 observed information at the optimum: the analytic
    # model's numeric Jacobian against the measured binomial variances (in
    # the G parameterization — the marginal σ(T1) is invariant to the
    # nuisance's scale), the marginal σ(T1) from the inverse Fisher's T1
    # entry (the nuisance profiled out by the 2×2 marginal)
    m(δG, δT) = [(c1 + (Ĝ + δG) * exp(-t / (T̂1 + δT))) for t in τ]
    ε = max(1e-6 * Ĝ, 1e-12)
    dG = (m(ε, 0.0) .- m(-ε, 0.0)) ./ (2ε)
    εT = max(1e-6 * T̂1, 1e-12)
    dT = (m(0.0, εT) .- m(0.0, -εT)) ./ (2εT)
    IGG = sum(dG .^ 2 ./ σ²)
    ITT = sum(dT .^ 2 ./ σ²)
    IGT = sum(dG .* dT ./ σ²)
    det = IGG * ITT - IGT^2
    σ_T1 = det > 0 ? sqrt(IGG / det) : Inf

    tolerance = pc.BOSONIC_CERT_TOLERANCE_SIGMA * σ_T1
    dof = max(n - 2, 1)
    prior = get(belief, "T1_q_us", nothing)
    agrees = !(prior isa Real) || abs(T̂1 - Float64(prior)) ≤ tolerance
    return T1Fit(T̂1, σ_T1, tolerance, chi2min / dof, agrees,
        result.provenance["seed"], rig.twin.record.id,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "record_path" => rig.record_path,
            "design" => "$(n) delay points x $(N) shots; bracket " *
                        "[$(round(lo; digits=2)), $(round(hi; digits=2))] μs " *
                        "(half-excursion at $(round(τ_half; digits=2)) μs)",
            "transfer_F" => F̂,
            "tolerance_rule" => string(
                "recovery within $(pc.BOSONIC_CERT_TOLERANCE_SIGMA)·σ; σ(T1) from " *
                "the profiled 2×2 observed binomial information (the analytic " *
                "decay model's Jacobian vs q̂(1−q̂)/N, the transfer F " *
                "profiled analytically)"),
            "evidence_class" => "twin-rehearsal",
            "tool" => "Strumento v$(pkgversion(Strumento)), julia $(VERSION)",
        ))
end

"""The `write_back` seam (#38 wraps here): the fitted T1 lands in the twin's
BELIEF via `calibrate!` — never truth, and never the record: the record's
noise.T1_q_us is an estimate-flagged PLACEHOLDER the twin keeps rolling on
(the family builder closes over the record's noise at factory time; decay is
a static-from-record device property in v1). The entry supersedes the
placeholder IN BELIEF ONLY — records change by vault commit, never by
procedure."""
function write_back!(rig::RehearsalRig, fitres::T1Fit)
    calibrate!(rig.twin, Dict{String,Any}("T1_q_us" => fitres.T1_us))
    return rig
end

"""
    run_t1_sweep(rig, design; jobs = fixture_t1_jobs) -> T1Fit

The T1 chain, one call: propose → compile → run over the wire → fit → write
back. `jobs` is the compile seam's source: the committed fixture payloads
(the default — the Julia-only lane) or a live bridge source (the PythonCall
extension's `compile_t1_point` over the design's `t1_geometry`, one payload
per delay point).

Everything is a pure function of (rig, design, jobs, the twin's seed): a
procedure run replays bit-exactly from its seed across fresh processes (the
replay check: `test/configurations/calibration_replay_check.jl`).
"""
function run_t1_sweep(rig::RehearsalRig, design::T1Design; jobs = fixture_t1_jobs)
    schedule = propose_t1(rig, design)
    payloads = jobs isa Function ? jobs(rig, schedule) : jobs
    result = run_t1_over_wire(rig, schedule, design, payloads)
    fitres = fit_t1(rig, design, result)
    write_back!(rig, fitres)
    return fitres
end

@testitem "the T1 procedure recovers the decay time through the wire within the DERIVED tolerance (the belief supersedes the record's placeholder)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (bring-up extension surface)"
        @test true
    else
        using Piccolo
        using JSON
        using Strumento: DriftPlan, instantiate, believed, advance!, calibrate!,
                         OrnsteinUhlenbeck
        ext = Base.get_extension(Strumento, :StrumentoBringupExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        # a DRIFTED twin (the rehearsal posture): the drift moves Hamiltonian
        # truth only — the record's T1 (the noise placeholder the twin's decay
        # actually rolls on, a static-from-record device property in v1) is
        # what the procedure must recover.
        plan = DriftPlan(:chi_kHz => [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0,
                                                        mu = -298.4)])
        make_rig(seed) = ext.RehearsalRig(record, device, soccfg, wiring;
                                         drift = plan, seed = seed,
                                         overlay_id = "rehearsal-v2")
        rig = make_rig(0xC0FFEE)
        try
            advance!(rig.twin, 3.0)
            truth_chi = rig.twin.truth[:chi_kHz]
            n_truth = length(rig.twin.truth)
            T1_record = rig.twin.record.noise["T1_q_us"]["value"]
            design = ext.T1Design()

            # the record's noise placeholder is ESTIMATE-flagged, and it does
            # NOT enter the twin's belief (instantiate seeds belief with the
            # record's PARAMETERS only) — nothing has ever superseded it
            @test rig.twin.record.noise["T1_q_us"]["estimate"] == true
            @test !haskey(believed(rig.twin), "T1_q_us")

            fitres = ext.run_t1_sweep(rig, design)   # propose -> wire -> fit -> write back

            # ── the fit is REAL and recovers the record's T1 (the value the
            # twin's decay rolls on, static in v1) within the DERIVED
            # tolerance (never a hand-picked one): 5·σ, σ from the profiled
            # observed information
            pc = Base.get_extension(Strumento, :StrumentoPiccoloExt)
            @test fitres.T1_us !== nothing
            @test abs(fitres.T1_us - T1_record) < fitres.T1_tolerance_us
            @test fitres.T1_tolerance_us ≈ pc.BOSONIC_CERT_TOLERANCE_SIGMA *
                                        fitres.T1_sigma_us
            @test 1e-3 < fitres.T1_sigma_us < 5.0   # a real information scale (μs)
            # the fit is a real procedure, not a restatement of the record:
            # the estimate sits off the truth (shot noise) with a sound residual
            @test fitres.T1_us != T1_record
            @test 0.1 < fitres.chi2_dof < 4.0

            # the belief-agreement flag is its DEFINITION: with no prior T1
            # belief (the record's noise placeholder never entered belief)
            # there is nothing to disagree with
            @test fitres.agrees_with_belief

            # ── the write-back supersedes the record's estimate-flagged
            # placeholder IN BELIEF ONLY: the belief entry lands via
            # calibrate!, the RECORD is untouched, and the twin's truth keeps
            # rolling on the record's value
            @test believed(rig.twin)["T1_q_us"] == fitres.T1_us
            @test rig.twin.record.noise["T1_q_us"]["value"] == T1_record
            @test rig.twin.record.noise["T1_q_us"]["estimate"] == true
            # T1_q_us is a BELIEF key beyond the record's parameter set (the
            # noise map never entered belief); truth keys untouched
            @test length(believed(rig.twin)) == 8       # the record's 7 + T1
            @test length(rig.twin.truth) == n_truth
            @test !any(==(Symbol("T1_q_us")), keys(rig.twin.truth))
            @test rig.twin.truth[:chi_kHz] == truth_chi

            # drift moves truth ONLY: aging the twin leaves the calibrated
            # belief exactly where the write-back put it
            advance!(rig.twin, 1.0)
            @test believed(rig.twin)["T1_q_us"] == fitres.T1_us
            @test rig.twin.truth[:chi_kHz] != truth_chi

            # the rehearsal evidence marking: twin-rehearsal, never device results
            @test fitres.provenance["evidence_class"] == "twin-rehearsal"
            @test fitres.seed == 0xC0FFEE
            @test fitres.record_id == rig.twin.record.id

            # ── a RE-CALIBRATION against the prior belief: the second run's
            # agrees_with_belief is computed against the written-back entry
            fit2 = ext.run_t1_sweep(rig, design)
            @test fit2.agrees_with_belief ==
                  (abs(fit2.T1_us - fitres.T1_us) ≤ fit2.T1_tolerance_us)
            @test fit2.agrees_with_belief          # a sound recalibration agrees

            # ── the propose seam's belief/schedule validation: once the belief
            # carries T1, a window that cannot reach its half-decay is refused
            err = try
                ext.propose_t1(rig, ext.T1Design(delays_samples = [0, 100, 200, 300]));
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("half-decay", sprint(showerror, err))

            # ── the run seam's decoded-axis refusal: a declared grid that
            # differs from the payloads the wire actually runs is refused
            err = try
                ext.run_t1_sweep(rig, ext.T1Design(
                    delays_samples = [0, 200, 400, 600, 800, 1200, 1600, 2000, 2400]));
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("does not match", sprint(showerror, err))
        finally
            ext.stop!(rig)
        end

        # ── the exactness pin (the sibling's justification): through the wire
        # in EXACT mode (belief == truth, no detuning — the degenerate frame),
        # the closed form predicts every delay point's response to the
        # integrator's tolerance: F from the zero-delay point, then the decay
        # at the record's T1 — the response model is EXACTLY exponential
        # (the justification for the sibling fit class, pinned)
        rig_x = ext.RehearsalRig(record, device, soccfg, wiring;
                                 drift = DriftPlan(), seed = 0xC0FFEE,
                                 overlay_id = "rehearsal-v2", exact = true)
        try
            schedule = ext.propose_t1(rig_x, ext.T1Design())
            jobs = ext.fixture_t1_jobs(rig_x, schedule)
            result = ext.run_t1_over_wire(rig_x, schedule, ext.T1Design(), jobs)
            C = rig_x.twin.record.noise["readout_confusion"]["value"]
            c1, c2 = C[1][2], C[2][2]
            T1 = rig_x.twin.record.noise["T1_q_us"]["value"]
            F = (result.responses[1] - c1) / (c2 - c1)
            for k in 1:length(result.delays_us)
                model = c1 + (c2 - c1) * F * exp(-result.delays_us[k] / T1)
                @test result.responses[k] ≈ model atol = 1e-5
            end
        finally
            ext.stop!(rig_x)
        end

        # ── seeded replay, in-process form: two FRESH rigs with the same seed
        # reproduce the whole procedure bit-exactly; a different seed differs
        run_it(seed) = begin
            r = make_rig(seed)
            try
                advance!(r.twin, 3.0)
                ext.run_t1_sweep(r, ext.T1Design())
            finally
                ext.stop!(r)
            end
        end
        a = run_it(0x5EED)
        b = run_it(0x5EED)
        c = run_it(0xFEED)
        @test a.T1_us == b.T1_us && a.T1_sigma_us == b.T1_sigma_us
        @test a.T1_us != c.T1_us
    end
end
