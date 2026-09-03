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
    js = _jobserver_ext()
    payload = js.read_payload(rig.server.soccfg, job.job_wire)
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

    # the family system at the CANDIDATE parameters (the belief's parameter
    # view — the fit never sees the twin's truth), the same rollout and
    # measurement the soc performs, and the soc's own confusion (the record's
    # — the v1 response model's readout). The remap is the soc's own arithmetic
    # (`_respond`'s explicit sum, not a BLAS product): the degenerate
    # belief == truth case must reproduce the server's exact response
    # BIT-for-bit, and the two accumulation orders differ in the last ulp.
    system = rig.families[rig.twin.record.family](params)
    ψ = rig.soc.ψ_init
    ρ0 = ψ * ψ'
    qtraj = DensityTrajectory(system, recon, ρ0, ρ0)
    p = rig.measurement_fn(Piccolo.density_to_iso_vec(qtraj(times[end])))
    confusion = _piccolo_ext()._record_confusion(rig.twin)
    return [sum(confusion[i, j] * p[i] for i in eachindex(p)) for j in eachindex(p)]
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
