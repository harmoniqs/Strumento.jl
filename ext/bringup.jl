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

function _wire_predict(rig::RehearsalRig, params::Dict{Symbol,Float64}, job)
    # duck-typed on the job's wire payload: the comb's BringupJob, the Ramsey
    # job, the T1 job — every procedure job type carries `job_wire`
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

# ─── The Ramsey procedure (issue #37, the ancilla-detuning calibration) ────────
#
# The time-domain estimator of the ancilla transition's detuning from its
# believed position. The fringe (stated, the implementer's design per the
# issue): the cavity displaced to the comb operating point |β| =
# displacement_alpha (mean photon number n̄ = α²), then π/2 – delay – π/2 on
# the ancilla (the second pulse at +90° — the quadrature fringe, and the
# distinct phase that gives the second pulse its own wave-table entry). The
# delay is the wire's TIME param (the literal advance), and during it the
# |e,n⟩ component accumulates phase at χ·n per photon — the ONLY in-frame
# ancilla precession the v1 family carries — so the fringe's collapse-revival
# structure (period 1/|χ| — the coherent-state revival) carries the transition
# frequency. The fit recovers the detuning
#
#     δ = n̄ · (χ_true − χ_belief),
#
# the ancilla transition's detuning from its believed position AT THE
# CALIBRATION PHOTON NUMBER — the number a drive-frame correction consumes.
# The model at candidate δ rolls the family at χ' = χ_belief + δ/n̄ (the
# builder's own parameter — the model is exact: photon-number smearing, the
# pulses' photon-detuned flip dynamics, decay, all of it), the certification
# fit class over the δ bracket, σ from the fit's observed binomial
# information, the recovery tolerance 5σ.
#
# THE G-CURVE, HONESTLY: the M4a-2 G-curve reduction (one response curve read
# at candidate-rescaled sweep points) does NOT apply here — the candidate
# detuning moves the PULSE-time dynamics too (the π/2's flip is
# photon-transition-detuned by χ′n, not only the idle phase), so the response
# is not a function of a single δ·τ product. The model cache therefore runs
# per-node payload rollouts (the certification class's own cached-fit shape;
# the cache nodes are the expensive part and the bracket is belief-relative,
# as in the comb). The issue's "where the fixed-probe-shape condition holds"
# hedge resolves: it does not hold for the Ramsey; its degenerate case is the
# T1 exponential below (response = G(τ/T1), the one-curve form the analytic
# fit already is).

"""The design's committed half-pi gain and phase constants — the same
constants the committed fixture-generation script carries (the fixture
payloads are this geometry compiled)."""
const RAMSEY_HPI_GAIN_FRAC = 0.0007
const RAMSEY_SECOND_PHASE_DEG = 90.0

"""
    RamseyFringeDesign(; kwargs...) -> RamseyFringeDesign

The Ramsey procedure's pinned design — the delay grid, the fringe geometry,
and the fit's belief-relative bracket.

The sweep: `delays_us` (µs, strictly increasing — the wire's literal TIME
advances; one committed per-point payload per delay). The committed default
grid (0.0:0.4:6.8 µs) spans two revival periods of the record-class χ.

The geometry: `displacement_alpha` (the comb operating point, n̄ = α²),
`hpi_gain_frac` / `second_phase_deg` (the committed operating constants).

The fit: the certification fit class over the detuning bracket
`±halfbracket_kHz` on a `fit_grid_step_kHz` grid, refined to
`fit_tol_kHz` — the comb's belief-relative bracket discipline.
"""
struct RamseyFringeDesign
    delays_us::Vector{Float64}
    displacement_alpha::Float64
    hpi_gain_frac::Float64
    second_phase_deg::Float64
    reps::Int
    soft_avgs::Int
    halfbracket_kHz::Float64
    fit_grid_step_kHz::Float64
    fit_tol_kHz::Float64
end

function RamseyFringeDesign(; delays_us = collect(0.0:0.4:6.8),
                            displacement_alpha = sqrt(2.0),
                            hpi_gain_frac = RAMSEY_HPI_GAIN_FRAC,
                            second_phase_deg = RAMSEY_SECOND_PHASE_DEG,
                            reps = 50, soft_avgs = 1,
                            halfbracket_kHz = 15.0,
                            fit_grid_step_kHz = 2.5,
                            fit_tol_kHz = 0.05)
    delays = Float64.(delays_us)
    isempty(delays) && error("RamseyFringeDesign: delays_us must be non-empty")
    all(≥(0), delays) || error(
        "RamseyFringeDesign: delays_us must be ≥ 0 (got $(minimum(delays))) — " *
        "a Ramsey fringe starts at zero delay")
    issorted(delays) && all(diff(delays) .> 0) || error(
        "RamseyFringeDesign: delays_us must be strictly increasing")
    for (name, v) in (("displacement_alpha", displacement_alpha),
                      ("hpi_gain_frac", hpi_gain_frac),
                      ("second_phase_deg", second_phase_deg),
                      ("halfbracket_kHz", halfbracket_kHz),
                      ("fit_grid_step_kHz", fit_grid_step_kHz))
        v > 0 || error("RamseyFringeDesign: $name must be > 0 (got $v)")
    end
    0 < fit_tol_kHz ≤ fit_grid_step_kHz || error(
        "RamseyFringeDesign: fit_tol_kHz ($fit_tol_kHz) must be in (0, " *
        "$fit_grid_step_kHz] — refinement below the cached model's resolution " *
        "is not a refinement")
    reps ≥ 1 || error("RamseyFringeDesign: reps must be ≥ 1 (got $reps)")
    soft_avgs ≥ 1 || error("RamseyFringeDesign: soft_avgs must be ≥ 1 (got $soft_avgs)")
    return RamseyFringeDesign(delays, Float64(displacement_alpha),
        Float64(hpi_gain_frac), Float64(second_phase_deg), Int(reps),
        Int(soft_avgs), Float64(halfbracket_kHz), Float64(fit_grid_step_kHz),
        Float64(fit_tol_kHz))
end

"""The design's fringe geometry as the bridge's compile contract (the
`compile_ramsey_point` keyword block — the same constants the committed
fixture-generation script carries)."""
ramsey_geometry(design::RamseyFringeDesign) = (
    displacement_alpha = design.displacement_alpha,
    hpi_gain_frac = design.hpi_gain_frac,
    second_phase_deg = design.second_phase_deg,
    reps = design.reps,
    soft_avgs = design.soft_avgs,
)

"""The Ramsey schedule (the `propose_ramsey` seam's output): the declared
delay grid and the provenance the supervision layer (#38) wraps."""
struct RamseySchedule
    delays_us::Vector{Float64}
    provenance::Dict{String,Any}
end

"""One proposed Ramsey measurement: its delay and its compiled payload, with
the accumulated shot count the fit's binomial weights consume."""
struct RamseyJob
    delay_us::Float64
    job_wire::Dict{String,Any}
    shots::Int
end

"""The Ramsey sweep's measured responses: the schedule, its jobs, the
per-delay e-outcome frequency on the DECODED delay axis (the payload is the
single source of truth), and the rehearsal provenance."""
struct RamseyResult
    schedule::RamseySchedule
    jobs::Vector{RamseyJob}
    responses::Vector{Float64}
    delays_us::Vector{Float64}
    shots::Int
    provenance::Dict{String,Any}
end

"""The Ramsey fit's outcome: the ancilla-detuning entry (kHz — the transition
detuned from its believed position at the calibration photon number) with its
derived information scale, the 5σ recovery tolerance, the fit quality, the
belief-agreement gate, and the rehearsal provenance (mirrors
`ResonatorSweepFit`)."""
struct RamseyFringeFit
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
declared delay grid, validated. The grid must span one believed fringe
period (the coherent-state revival 1/|χ_belief| — a grid that misses the
revival structure measures noise), and on a RE-CALIBRATION (the belief
already carries `detuning_kHz`) the fit's bracket must span the believed
detuning — a bracket that cannot return the believed value has the belief and
the schedule disagreeing."""
function propose_ramsey(rig::RehearsalRig, design::RamseyFringeDesign)
    χ_bel = Float64(believed(rig.twin)["chi_kHz"])
    revival_us = 1000.0 / abs(χ_bel)     # 1/|χ| — the revival period, µs
    (last(design.delays_us) - first(design.delays_us)) ≥ revival_us || error(
        "propose_ramsey: the declared delay span [$(first(design.delays_us)), " *
        "$(last(design.delays_us))] µs does not span one believed fringe period " *
        "($revival_us µs, the revival at χ_kHz = $χ_bel) — the grid cannot " *
        "resolve the fringe; re-author the grid or calibrate the belief")
    prior = get(believed(rig.twin), "detuning_kHz", nothing)
    if prior isa Real
        abs(Float64(prior)) ≤ design.halfbracket_kHz || error(
            "propose_ramsey: the fit's bracket [−$(design.halfbracket_kHz), " *
            "$(design.halfbracket_kHz)] kHz does not span the believed " *
            "detuning_kHz $(Float64(prior)) (the belief and the schedule " *
            "disagree) — re-author the bracket or recalibrate the belief first")
    end
    return RamseySchedule(
        copy(design.delays_us),
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "overlay_id" => rig.overlay_id,
            "device_path" => rig.device_path,
            "evidence_class" => "twin-rehearsal",
        ),
    )
end

"""The compile seam's fixture lane: the committed per-delay Ramsey payloads
(the Julia-only path). The design's delays must land on the committed grid
(0.4 µs steps — the fixtures are that grid compiled)."""
function fixture_ramsey_jobs(rig::RehearsalRig, schedule::RamseySchedule)
    fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
    jobs = RamseyJob[]
    for τ in schedule.delays_us
        idx = round(Int, τ / 0.4)
        abs(idx * 0.4 - τ) > 1e-9 && error(
            "fixture_ramsey_jobs: the declared delay $τ µs is not on the " *
            "committed fixture grid (0.4 µs steps — the geometry the fixtures " *
            "carry); compile the design's own payload (the bridge lane) or " *
            "re-author the design to the committed grid")
        path = joinpath(fixtures, "ramsey_rehearsal_$(lpad(idx, 2, '0')).json")
        isfile(path) || error(
            "fixture_ramsey_jobs: the committed fixture $path is missing — the " *
            "fixture lane expects one payload per schedule point (regenerate " *
            "with test/fixtures/_fixtures/generate_rehearsal_payloads.py)")
        job = JSON.parsefile(path)
        push!(jobs, RamseyJob(τ, job, _job_shots(rig, job)))
    end
    return jobs
end

"""The `run_ramsey_over_wire` seam (#38 wraps here): run each per-delay
payload over the wire and reduce to the e-outcome frequency on the DECODED
delay axis (the literal idle ticks the payload itself carries — the payload is
the single source of truth, never the declared grid)."""
function run_ramsey_over_wire(rig::RehearsalRig, schedule::RamseySchedule,
                              jobs::Vector{RamseyJob})
    length(jobs) == length(schedule.delays_us) || error(
        "run_ramsey_over_wire: $(length(jobs)) compiled jobs for " *
        "$(length(schedule.delays_us)) schedule points — one payload per point")
    js = _jobserver_ext()
    responses = Float64[]
    delays = Float64[]
    for job in jobs
        acq = run_job(rig.client, job.job_wire)
        iq = get(acq, "iq", nothing)
        (iq isa AbstractVector && length(iq) == 1 &&
         length(iq[1]) == 1 && length(iq[1][1]) == 2) || error(
            "run_ramsey_over_wire: the per-point acquisition must be one " *
            "read's (I, Q) pair")
        payload = js.read_payload(rig.server.soccfg, job.job_wire)
        isempty(payload.idle_ticks) && error(
            "run_ramsey_over_wire: the Ramsey payload carries no decoded idle — " *
            "the delay rides the literal TIME advance")
        push!(responses, Float64(iq[1][1][2]))
        # the decoded delay: the total literal idle of the payload (the
        # between-pulses idle — the only nonzero one in the fringe geometry)
        push!(delays, sum(payload.idle_ticks) / payload.f_time_hz * 1e6)
    end
    return RamseyResult(schedule, jobs, responses, delays, jobs[1].shots,
        Dict{String,Any}(
            "schedule_provenance" => schedule.provenance,
            "evidence_class" => "twin-rehearsal",
            "seed" => rig.seed,
            "overlay_id" => rig.overlay_id,
            "twin_time_days" => rig.twin.t,
        ))
end

"""The `fit_ramsey` seam (#38 wraps here): the certification fit class —
weighted binomial χ² of the measured fringe against the payload-driven
belief-side model sweep over the belief-relative detuning bracket
(`_CertModelCache` + `_cert_fit_1d`, the Piccolo extension's fit home — one
fitter, no duplication). The model at candidate detuning δ rolls the payload
at χ′ = χ_belief + δ/n̄ (the belief's parameter view — the fit never sees the
twin's truth), σ from the fit's own observed information, the recovery
tolerance `BOSONIC_CERT_TOLERANCE_SIGMA`·σ."""
function fit_ramsey(rig::RehearsalRig, design::RamseyFringeDesign,
                    result::RamseyResult)
    pc = _piccolo_ext()
    belief = believed(rig.twin)
    bparams = Dict{Symbol,Float64}(
        Symbol(k) => Float64(v) for (k, v) in belief if v isa Real)
    haskey(bparams, :chi_kHz) || error(
        "fit_ramsey: the twin's belief carries no chi_kHz — the Ramsey model " *
        "rolls the family at the believed χ plus the candidate detuning; the " *
        "record must state it")
    χ_bel = bparams[:chi_kHz]
    n̄ = design.displacement_alpha^2

    shots = unique([job.shots for job in result.jobs])
    length(shots) == 1 || error(
        "fit_ramsey: the schedule's payloads carry different accumulated shot " *
        "counts ($(shots)) — the fit's binomial weights need one count")
    shots[1] ≥ 1 || error("fit_ramsey: the accumulated shot count must be ≥ 1")

    # the belief-side model sweep at candidate detuning δ: the family at
    # χ′ = χ_belief + δ/n̄ — the payload-driven wire model (the fit never
    # sees the twin's truth)
    model_sweep_at(δ) =
        [_wire_predict(rig, merge(bparams, Dict{Symbol,Float64}(
            :chi_kHz => χ_bel + δ / n̄)), job)[2] for job in result.jobs]
    cache = pc._CertModelCache(model_sweep_at, -design.halfbracket_kHz,
                               design.halfbracket_kHz, design.fit_grid_step_kHz)
    fit_design = pc.BosonicCertDesign(fit_tol_kHz = design.fit_tol_kHz)
    δ̂, chi2min, σ, _ = pc._cert_fit_1d(cache, result.responses, shots[1], fit_design)

    tolerance = pc.BOSONIC_CERT_TOLERANCE_SIGMA * σ
    dof = max(length(result.responses) - 1, 1)
    prior = get(belief, "detuning_kHz", nothing)
    agrees = !(prior isa Real) || abs(δ̂ - Float64(prior)) ≤ tolerance

    return RamseyFringeFit(δ̂, σ, tolerance, chi2min / dof, agrees,
        result.provenance["seed"], rig.twin.record.id,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "record_path" => rig.record_path,
            "design" => "$(length(result.delays_us)) delay points x $(shots[1]) " *
                        "shots; bracket ±$(design.halfbracket_kHz) kHz at n̄ = $n̄",
            "tolerance_rule" => string(
                "recovery within $(pc.BOSONIC_CERT_TOLERANCE_SIGMA)·σ; σ from " *
                "the fit's observed binomial information (the model Jacobian " *
                "vs q̂(1−q̂)/N on the payload-driven wire model sweep)"),
            "observable" => string(
                "the ancilla transition's detuning from its believed position " *
                "at the calibration photon number n̄ = $n̄ (the delay fringe " *
                "through the displaced cavity — δ = n̄·(χ_true − χ_belief))"),
            "evidence_class" => "twin-rehearsal",
            "tool" => "Strumento v$(pkgversion(Strumento)), julia $(VERSION)",
        ))
end

"""The `write_back` seam (#38 wraps here): the fitted detuning lands in the
twin's BELIEF via `calibrate!` — never truth, and never a record parameter
(the `pi_gain` precedent: the belief dict is the calibration-store mirror and
admits calibration keys beyond the record's parameter set without
extension)."""
function write_back!(rig::RehearsalRig, fitres::RamseyFringeFit)
    calibrate!(rig.twin, Dict{String,Any}("detuning_kHz" => fitres.detuning_kHz))
    return rig
end

"""
    run_ramsey_sweep(rig, design; jobs = fixture_ramsey_jobs) -> RamseyFringeFit

The Ramsey chain, one call: propose → compile → run over the wire → fit →
write back. `jobs` is the compile seam's source: the committed fixture
payloads (the default — the Julia-only lane) or a live bridge source (the
PythonCall extension's `compile_ramsey_point` over the design's
`ramsey_geometry`, one payload per delay point).

Everything is a pure function of (rig, design, jobs, the twin's seed): a
procedure run replays bit-exactly from its seed across fresh processes (the
replay check: `test/configurations/calibration_replay_check.jl`).
"""
function run_ramsey_sweep(rig::RehearsalRig, design::RamseyFringeDesign;
                          jobs = fixture_ramsey_jobs)
    schedule = propose_ramsey(rig, design)
    payloads = jobs isa Function ? jobs(rig, schedule) : jobs
    result = run_ramsey_over_wire(rig, schedule, payloads)
    fitres = fit_ramsey(rig, design, result)
    write_back!(rig, fitres)
    return fitres
end

# ─── The T1 procedure (issue #37, the decay-constant calibration) ───────────────
#
# π at the operating-point gain, a literal TIME delay, measure: the ancilla
# population decays at 1/T1 through the idle (the family's Lindblad wiring —
# the record's own noise.T1_q_us placeholder is what the twin actually decays
# at in v1, the builder's static device property). The response is EXACTLY the
# exponential q_e(τ) = c + a·e^(−τ/T1) (the measurement is the diagonal, so
# coherences never enter; the played window's constant extra decay is an
# amplitude rescale the fit's nuisance parameters absorb), and the fit is a
# weighted binomial least-squares on (c, a, T1) — the justified sibling of the
# certification class (a 3-parameter exponential NLS, not a cached 1-D model
# sweep: the exponential IS the belief-side model, and its G-curve form
# response = G(τ/T1) is the one-curve idiom the issue's hedge names). σ from
# the 3×3 observed Fisher (binomial weights against the model Jacobian),
# marginalized to T1; the recovery tolerance 5σ.

"""The design's committed operating-point π gain — the same constant the
committed fixture-generation script carries (the fixture payloads are this
geometry compiled)."""
const CAL_PI_GAIN_FRAC = 43 / 32766

"""
    T1DecayDesign(; kwargs...) -> T1DecayDesign

The T1 procedure's pinned design — the delay grid (µs, strictly increasing)
and the acquisition. The committed default grid (0:40:280 µs) spans ~2.3× the
record-class T1 placeholder (120 µs) — the span a decay fit resolves.
"""
struct T1DecayDesign
    delays_us::Vector{Float64}
    pi_gain_frac::Float64
    reps::Int
    soft_avgs::Int
end

function T1DecayDesign(; delays_us = collect(0.0:40.0:280.0),
                       pi_gain_frac = CAL_PI_GAIN_FRAC,
                       reps = 50, soft_avgs = 1)
    delays = Float64.(delays_us)
    isempty(delays) && error("T1DecayDesign: delays_us must be non-empty")
    all(≥(0), delays) || error(
        "T1DecayDesign: delays_us must be ≥ 0 (got $(minimum(delays)))")
    issorted(delays) && all(diff(delays) .> 0) || error(
        "T1DecayDesign: delays_us must be strictly increasing")
    pi_gain_frac > 0 || error("T1DecayDesign: pi_gain_frac must be > 0")
    reps ≥ 1 || error("T1DecayDesign: reps must be ≥ 1 (got $reps)")
    soft_avgs ≥ 1 || error("T1DecayDesign: soft_avgs must be ≥ 1 (got $soft_avgs)")
    return T1DecayDesign(delays, Float64(pi_gain_frac), Int(reps), Int(soft_avgs))
end

"""The design's geometry as the bridge's compile contract (the
`compile_t1_point` keyword block — the same constants the committed
fixture-generation script carries)."""
t1_geometry(design::T1DecayDesign) = (
    pi_gain_frac = design.pi_gain_frac,
    reps = design.reps,
    soft_avgs = design.soft_avgs,
)

"""The T1 schedule (the `propose_t1` seam's output): the declared delay grid
and the provenance the supervision layer (#38) wraps."""
struct T1Schedule
    delays_us::Vector{Float64}
    provenance::Dict{String,Any}
end

"""One proposed T1 measurement: its delay and its compiled payload, with the
accumulated shot count."""
struct T1Job
    delay_us::Float64
    job_wire::Dict{String,Any}
    shots::Int
end

"""The T1 sweep's measured responses: the schedule, its jobs, the per-delay
e-outcome frequency on the DECODED delay axis, and the rehearsal provenance."""
struct T1Result
    schedule::T1Schedule
    jobs::Vector{T1Job}
    responses::Vector{Float64}
    delays_us::Vector{Float64}
    shots::Int
    provenance::Dict{String,Any}
end

"""The T1 fit's outcome: the decay constant (µs) with its derived information
scale, the 5σ recovery tolerance, the fit quality, the belief-agreement gate,
and the rehearsal provenance. The belief entry `T1_q_us` SUPERSEDES the
record's estimate-flagged `noise.T1_q_us` placeholder IN BELIEF ONLY — the
record itself is vault-committed truth, never procedure-edited (stated in the
provenance)."""
struct T1DecayFit
    T1_q_us::Float64
    T1_sigma_q_us::Float64
    T1_tolerance_q_us::Float64
    chi2_dof::Float64
    agrees_with_belief::Bool
    seed::Any
    record_id::String
    provenance::Dict{String,Any}
end

# The believed T1 for scheduling: the belief's own measured entry when a
# calibration wrote one, else the record's estimate-flagged placeholder (the
# only prior the v1 record carries).
function _believed_t1_q_us(rig::RehearsalRig)
    prior = get(believed(rig.twin), "T1_q_us", nothing)
    prior isa Real && return Float64(prior)
    wrapped = get(rig.twin.record.noise, "T1_q_us", nothing)
    (wrapped isa AbstractDict && wrapped["value"] isa Real) || error(
        "propose_t1: neither the belief nor the record carries a T1_q_us to " *
        "schedule against — the record's noise.T1_q_us placeholder is the v1 " *
        "prior; the record must state it")
    return Float64(wrapped["value"])
end

"""The `propose_t1` seam (#38 wraps here): (belief + schedule) -> the
declared delay grid, validated. The grid's span must RESOLVE the believed T1
(a span shorter than the decay constant cannot separate the decay from its
amplitude)."""
function propose_t1(rig::RehearsalRig, design::T1DecayDesign)
    t1_bel = _believed_t1_q_us(rig)
    (last(design.delays_us) - first(design.delays_us)) ≥ t1_bel || error(
        "propose_t1: the declared delay span [$(first(design.delays_us)), " *
        "$(last(design.delays_us))] µs does not resolve the believed T1 " *
        "($t1_bel µs) — a span shorter than the decay constant cannot " *
        "separate the decay from its amplitude; re-author the grid or " *
        "calibrate the belief")
    return T1Schedule(
        copy(design.delays_us),
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "overlay_id" => rig.overlay_id,
            "device_path" => rig.device_path,
            "evidence_class" => "twin-rehearsal",
        ),
    )
end

"""The compile seam's fixture lane: the committed per-delay T1 payloads. The
design's delays must land on the committed grid (40 µs steps)."""
function fixture_t1_jobs(rig::RehearsalRig, schedule::T1Schedule)
    fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
    jobs = T1Job[]
    for τ in schedule.delays_us
        idx = round(Int, τ / 40.0)
        abs(idx * 40.0 - τ) > 1e-9 && error(
            "fixture_t1_jobs: the declared delay $τ µs is not on the committed " *
            "fixture grid (40 µs steps — the geometry the fixtures carry); " *
            "compile the design's own payload (the bridge lane) or re-author " *
            "the design to the committed grid")
        path = joinpath(fixtures, "t1_rehearsal_$(lpad(idx, 2, '0')).json")
        isfile(path) || error(
            "fixture_t1_jobs: the committed fixture $path is missing — the " *
            "fixture lane expects one payload per schedule point (regenerate " *
            "with test/fixtures/_fixtures/generate_rehearsal_payloads.py)")
        job = JSON.parsefile(path)
        push!(jobs, T1Job(τ, job, _job_shots(rig, job)))
    end
    return jobs
end

"""The `run_t1_over_wire` seam (#38 wraps here): run each per-delay payload
over the wire and reduce to the e-outcome frequency on the DECODED delay
axis."""
function run_t1_over_wire(rig::RehearsalRig, schedule::T1Schedule,
                          jobs::Vector{T1Job})
    length(jobs) == length(schedule.delays_us) || error(
        "run_t1_over_wire: $(length(jobs)) compiled jobs for " *
        "$(length(schedule.delays_us)) schedule points — one payload per point")
    js = _jobserver_ext()
    responses = Float64[]
    delays = Float64[]
    for job in jobs
        acq = run_job(rig.client, job.job_wire)
        iq = get(acq, "iq", nothing)
        (iq isa AbstractVector && length(iq) == 1 &&
         length(iq[1]) == 1 && length(iq[1][1]) == 2) || error(
            "run_t1_over_wire: the per-point acquisition must be one read's " *
            "(I, Q) pair")
        payload = js.read_payload(rig.server.soccfg, job.job_wire)
        isempty(payload.idle_ticks) && error(
            "run_t1_over_wire: the T1 payload carries no decoded idle — the " *
            "delay rides the literal TIME advance")
        push!(responses, Float64(iq[1][1][2]))
        push!(delays, sum(payload.idle_ticks) / payload.f_time_hz * 1e6)
    end
    return T1Result(schedule, jobs, responses, delays, jobs[1].shots,
        Dict{String,Any}(
            "schedule_provenance" => schedule.provenance,
            "evidence_class" => "twin-rehearsal",
            "seed" => rig.seed,
            "overlay_id" => rig.overlay_id,
            "twin_time_days" => rig.twin.t,
        ))
end

# The exponential fit (the justified sibling of the certification class — the
# 3-parameter weighted binomial NLS on q(τ) = c + a·e^(−τ/T1)). Gauss-Newton
# from a log-linear initial guess; σ from the 3×3 observed Fisher marginalized
# to T1. Pure Julia, deterministic, no new dependency edge.
function _fit_exp_binomial(delays_us::Vector{Float64}, q::Vector{Float64},
                            shots::Int)
    n = length(delays_us)
    n ≥ 4 || error("_fit_exp_binomial: $(n) points cannot resolve a 3-parameter " *
                   "exponential — the decay needs at least four delays")
    length(q) == n || error("_fit_exp_binomial: $(length(q)) responses on a " *
                            "$(n)-point delay axis")
    shots ≥ 1 || error("_fit_exp_binomial: the accumulated shot count must be ≥ 1")
    τ = delays_us

    # initial guess: offset from the tail, amplitude from the head, T1 from a
    # log-linear regression on the resolving interior points
    c0 = minimum(q)
    head = findfirst(x -> x > c0 + 0.02, q)
    head === nothing && error(
        "_fit_exp_binomial: the measured curve never rises above its tail — " *
        "no decay to fit")
    a0 = q[head] - c0
    inner = [i for i in 1:n if q[i] > c0 + 0.05]
    length(inner) ≥ 2 || (inner = [i for i in 1:n if q[i] > c0 + 0.01])
    length(inner) ≥ 2 || error(
        "_fit_exp_binomial: only one point rises above the tail — the decay " *
        "is unresolved at this delay grid")
    # log-linear slope: log(q − c0) ≈ log(a) − τ/T1
    w = inner[2] - inner[1]
    slope = (log(q[inner[end]] - c0) - log(q[inner[1]] - c0)) /
            (τ[inner[end]] - τ[inner[1]])
    slope < 0 || error(
        "_fit_exp_binomial: the measured curve does not decay (slope ≥ 0 on " *
        "the log axis) — the schedule measures no relaxation")
    t1 = -1.0 / slope
    θ = [c0, a0, t1]

    σ² = [max(x * (1 - x), 1e-9) / shots for x in q]
    model(θ, τ) = θ[1] + θ[2] * exp(-τ / θ[3])
    jacobian(θ, τ) = [1.0, exp(-τ / θ[3]), θ[2] * exp(-τ / θ[3]) * τ / θ[3]^2]
    for _ in 1:100
        r = [(q[i] - model(θ, τ[i])) for i in 1:n]
        J = reduce(hcat, [jacobian(θ, τ[i]) for i in 1:n])
        # weighted normal equations (3×3 — closed form via the explicit inverse)
        F = J * diagm(1 ./ σ²) * J'
        g = J * ((r) ./ σ²)
        step = F \ g
        θ = θ + step
        maximum(abs.(step)) < 1e-12 && break
    end
    # observed information at the optimum: the 3×3 Fisher, marginalized to T1
    J = reduce(hcat, [jacobian(θ, τ[i]) for i in 1:n])
    F = J * diagm(1 ./ σ²) * J'
    cov = inv(F)
    sigma = sqrt(max(cov[3, 3], 0.0))
    χ2 = sum(((q .- [model(θ, t) for t in τ]) .^ 2) ./ σ²)
    dof = max(n - 3, 1)
    return θ[3], sigma, χ2 / dof, θ
end

"""The `fit_t1` seam (#38 wraps here): the weighted binomial exponential fit
on the DECODED delay axis — c + a·e^(−τ/T1) with (c, a) nuisance parameters
(the prep amplitude and the confusion ceiling absorb into them; the played
window's constant extra decay is an amplitude rescale), σ from the 3×3
observed Fisher marginalized to T1, the recovery tolerance
`BOSONIC_CERT_TOLERANCE_SIGMA`·σ. The justified sibling of the certification
class, in this module (the one-fitter-home rule: the exponential IS the
belief-side model, and the cached 1-D model sweep does not apply to a
3-parameter analytic law)."""
function fit_t1(rig::RehearsalRig, design::T1DecayDesign, result::T1Result)
    pc = _piccolo_ext()
    belief = believed(rig.twin)
    t1, σ, χ2dof, _ = _fit_exp_binomial(result.delays_us, result.responses,
                                        result.shots)
    tolerance = pc.BOSONIC_CERT_TOLERANCE_SIGMA * σ
    prior = get(belief, "T1_q_us", nothing)
    agrees = !(prior isa Real) || abs(t1 - Float64(prior)) ≤ tolerance
    return T1DecayFit(t1, σ, tolerance, χ2dof, agrees,
        result.provenance["seed"], rig.twin.record.id,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "record_path" => rig.record_path,
            "design" => "$(length(result.delays_us)) delay points x " *
                        "$(result.shots) shots; span " *
                        "$(round(first(result.delays_us), digits=3)).." *
                        "$(round(last(result.delays_us), digits=3)) µs",
            "tolerance_rule" => string(
                "recovery within $(pc.BOSONIC_CERT_TOLERANCE_SIGMA)·σ; σ from " *
                "the 3×3 observed binomial Fisher of (offset, amplitude, T1), " *
                "marginalized to T1"),
            "supersedes" => string(
                "the record's noise.T1_q_us estimate-flagged placeholder — IN " *
                "BELIEF ONLY (the belief entry T1_q_us supersedes it; the " *
                "record itself is vault-committed truth, changed by human " *
                "commit, never by a procedure)"),
            "evidence_class" => "twin-rehearsal",
            "tool" => "Strumento v$(pkgversion(Strumento)), julia $(VERSION)",
        ))
end

"""The `write_back` seam (#38 wraps here): the fitted T1 lands in the twin's
BELIEF via `calibrate!` — the `T1_q_us` belief key SUPERSEDES the record's
estimate-flagged `noise.T1_q_us` placeholder in belief only (the record is
never edited; its noise entry keeps `estimate: true` until a human vault
commit retires it)."""
function write_back!(rig::RehearsalRig, fitres::T1DecayFit)
    calibrate!(rig.twin, Dict{String,Any}("T1_q_us" => fitres.T1_q_us))
    return rig
end

"""
    run_t1_sweep(rig, design; jobs = fixture_t1_jobs) -> T1DecayFit

The T1 chain, one call: propose → compile → run over the wire → fit → write
back. `jobs` is the compile seam's source: the committed fixture payloads
(the default — the Julia-only lane) or a live bridge source (the PythonCall
extension's `compile_t1_point` over the design's `t1_geometry`).

Everything is a pure function of (rig, design, jobs, the twin's seed): a
procedure run replays bit-exactly from its seed across fresh processes.
"""
function run_t1_sweep(rig::RehearsalRig, design::T1DecayDesign;
                      jobs = fixture_t1_jobs)
    schedule = propose_t1(rig, design)
    payloads = jobs isa Function ? jobs(rig, schedule) : jobs
    result = run_t1_over_wire(rig, schedule, payloads)
    fitres = fit_t1(rig, design, result)
    write_back!(rig, fitres)
    return fitres
end

# ─── The readout-confusion procedure (issue #37, the measured confusion) ──────
#
# The transfer procedure's "measured confusion" source, now produced by a
# procedure: prepare |g⟩ (a played zero drive over the π window — ge_pi at
# gain 0) and |e⟩ (ge_pi at the operating-point gain), count, and recover the
# confusion matrix from the response statistics. The g preparation is pure
# (zero drive leaves the joint ground state) — its outcome distribution IS
# the confusion's first row. The e preparation carries the ancilla T1 over
# the payload's played window (the readout samples the state at the trigger,
# after the π window's decay), so the second row is recovered with the
# believed T1 correction q_e = (1−s)·row_g + s·row_e, s = e^(−w/T1_bel) — the
# certification machinery's own correction idiom, now belief-side. The
# preparation's flip deficit (the π calibration's own quality — the linear
# ruler's shape error) rides the e row uncorrected: the measured confusion is
# the assignment matrix OF THE PREPARATIONS AS PLAYED, stated in the
# provenance (the row's recovery bound is the π calibration's scale, not the
# binomial one).

"""
    ReadoutConfusionDesign(; kwargs...) -> ReadoutConfusionDesign

The confusion procedure's pinned design — the e-preparation's operating-point
π gain (the committed constant the fixture payloads carry) and the
acquisition. The g preparation is the same compile at gain 0.
"""
struct ReadoutConfusionDesign
    pi_gain_frac::Float64
    reps::Int
    soft_avgs::Int
end

function ReadoutConfusionDesign(; pi_gain_frac = CAL_PI_GAIN_FRAC,
                                reps = 50, soft_avgs = 1)
    pi_gain_frac > 0 || error("ReadoutConfusionDesign: pi_gain_frac must be > 0")
    reps ≥ 1 || error("ReadoutConfusionDesign: reps must be ≥ 1 (got $reps)")
    soft_avgs ≥ 1 || error("ReadoutConfusionDesign: soft_avgs must be ≥ 1 " *
                           "(got $soft_avgs)")
    return ReadoutConfusionDesign(Float64(pi_gain_frac), Int(reps), Int(soft_avgs))
end

"""The design's geometry as the bridge's compile contract (the `compile_ge_pi`
keyword block — both preparations ride the ge_pi factory compile)."""
confusion_geometry(design::ReadoutConfusionDesign) = (
    pi_gain_frac = design.pi_gain_frac,
    reps = design.reps,
    soft_avgs = design.soft_avgs,
)

"""The confusion schedule (the `propose_confusion` seam's output): the two
preparations and the provenance the supervision layer (#38) wraps."""
struct ConfusionSchedule
    preps::Vector{String}               # ["ground", "excited"]
    provenance::Dict{String,Any}
end

"""One proposed confusion preparation: its name and its compiled payload,
with the accumulated shot count."""
struct ConfusionJob
    prep::String
    job_wire::Dict{String,Any}
    shots::Int
end

"""The confusion procedure's measured responses: the schedule, its two jobs,
the per-prep outcome frequencies and played windows, and the rehearsal
provenance."""
struct ConfusionResult_raw
    schedule::ConfusionSchedule
    jobs::Vector{ConfusionJob}
    responses::Dict{String,Vector{Float64}}
    window_us::Dict{String,Float64}
    shots::Int
    provenance::Dict{String,Any}
end

"""The confusion procedure's outcome: the recovered 2×2 confusion matrix
(rows = TRUE state outcome distributions, the record's convention), the
derived per-entry binomial scales (the e row amplified by the T1
correction), the T1 correction's own facts, and the rehearsal provenance.
The belief entry `readout_confusion` lands in the wrapped noise form the
transfer machinery consumes."""
struct ReadoutConfusionResult
    confusion::Matrix{Float64}
    sigma_entries::Matrix{Float64}
    survive::Float64                       # the T1 correction factor s
    T1_used_q_us::Float64                  # the believed T1 the correction rode
    seed::Any
    record_id::String
    provenance::Dict{String,Any}
end

"""The `propose_confusion` seam (#38 wraps here): the two preparations,
validated."""
function propose_confusion(rig::RehearsalRig, design::ReadoutConfusionDesign)
    return ConfusionSchedule(
        ["ground", "excited"],
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "overlay_id" => rig.overlay_id,
            "device_path" => rig.device_path,
            "evidence_class" => "twin-rehearsal",
        ),
    )
end

"""The compile seam's fixture lane: the two committed preparation payloads
(the g prep at gain 0, the e prep at the committed operating-point gain)."""
function fixture_confusion_jobs(rig::RehearsalRig, schedule::ConfusionSchedule)
    fixtures = joinpath(pkgdir(Strumento), "test", "fixtures", "_fixtures")
    files = Dict{String,String}(
        "ground" => joinpath(fixtures, "confusion_g_rehearsal.json"),
        "excited" => joinpath(fixtures, "confusion_e_rehearsal.json"),
    )
    jobs = ConfusionJob[]
    for prep in schedule.preps
        path = get(files, prep, nothing)
        path === nothing && error(
            "fixture_confusion_jobs: unknown preparation $(repr(prep)) — the " *
            "confusion procedure prepares \"ground\" and \"excited\"")
        isfile(path) || error(
            "fixture_confusion_jobs: the committed fixture $path is missing " *
            "(regenerate with test/fixtures/_fixtures/" *
            "generate_rehearsal_payloads.py)")
        job = JSON.parsefile(path)
        push!(jobs, ConfusionJob(prep, job, _job_shots(rig, job)))
    end
    return jobs
end

"""The `run_confusion_over_wire` seam (#38 wraps here): run both preparation
payloads over the wire and reduce to the per-prep outcome frequency and the
DECODED played window (the payload's literal timeline — the readout samples
the state at the trigger)."""
function run_confusion_over_wire(rig::RehearsalRig, schedule::ConfusionSchedule,
                                 jobs::Vector{ConfusionJob})
    js = _jobserver_ext()
    length(jobs) == 2 || error(
        "run_confusion_over_wire: the confusion procedure runs TWO " *
        "preparations (ground and excited), got $(length(jobs)) jobs")
    responses = Dict{String,Vector{Float64}}()
    window = Dict{String,Float64}()
    for job in jobs
        acq = run_job(rig.client, job.job_wire)
        iq = get(acq, "iq", nothing)
        (iq isa AbstractVector && length(iq) == 1 &&
         length(iq[1]) == 1 && length(iq[1][1]) == 2) || error(
            "run_confusion_over_wire: the per-prep acquisition must be one " *
            "read's (I, Q) pair")
        payload = js.read_payload(rig.server.soccfg, job.job_wire)
        total_samp = sum(payload.waves[p[2]].length_cycles *
                          payload.gen_cfg[p[1]].samps_per_clk for p in payload.plays) +
                     sum(round(Int, t / payload.f_time_hz *
                               payload.gen_cfg[payload.plays[1][1]].fs_hz)
                         for t in payload.idle_ticks)
        responses[job.prep] = [Float64(iq[1][1][1]), Float64(iq[1][1][2])]
        window[job.prep] = total_samp / payload.gen_cfg[payload.plays[1][1]].fs_hz * 1e6
    end
    return ConfusionResult_raw(schedule, jobs, responses, window, jobs[1].shots,
        Dict{String,Any}(
            "schedule_provenance" => schedule.provenance,
            "evidence_class" => "twin-rehearsal",
            "seed" => rig.seed,
            "overlay_id" => rig.overlay_id,
            "twin_time_days" => rig.twin.t,
        ))
end

"""The `fit_confusion` seam (#38 wraps here): the counting estimator — the
g row IS the g-prep's outcome distribution (the preparation is a played zero
drive; no correction), the e row the T1-corrected e-prep distribution over
the payload's own played window, with the BELIEVED T1 (the calibration the
composed pass just wrote, when it ran; the record's estimate-flagged
placeholder otherwise). Rows renormalized; per-entry binomial scales carried
(the e row amplified by the 1/s correction)."""
function fit_confusion(rig::RehearsalRig, design::ReadoutConfusionDesign,
                       result::ConfusionResult_raw)
    haskey(result.responses, "ground") && haskey(result.responses, "excited") || error(
        "fit_confusion: the confusion run must carry both preparations")
    q_g = result.responses["ground"]
    q_e = result.responses["excited"]
    w_us = result.window_us["excited"]

    # the believed T1 the correction rides: the calibration's belief entry,
    # else the record's placeholder (the v1 prior)
    T1_bel = _believed_t1_q_us(rig)
    T1_bel > 0 || error("fit_confusion: the believed T1 must be > 0")
    s = exp(-w_us / T1_bel)
    0 < s < 1 || error(
        "fit_confusion: the T1 window correction factor s = $s is degenerate " *
        "(window $(w_us) µs vs believed T1 $(T1_bel) µs)")

    row_g = q_g ./ sum(q_g)
    row_e = (q_e .- (1 - s) .* q_g) ./ s
    all(>=(0), row_e) || error(
        "fit_confusion: the T1-corrected excited row has negative entries " *
        "($(row_e)) — the shots are inconsistent with the believed T1 " *
        "(is the T1 belief stale?)")
    row_e = row_e ./ sum(row_e)
    Ĉ = [row_g'; row_e']

    # the derived per-entry scales: the binomial σ of the counts, the e row
    # amplified by the 1/s correction
    σ_g = [sqrt(max(q * (1 - q), 1e-9) / result.shots) for q in q_g]
    σ_e = [sqrt(max(q * (1 - q), 1e-9) / result.shots) / s for q in q_e]
    return ReadoutConfusionResult(Ĉ, [σ_g'; σ_e'], s, T1_bel,
        result.provenance["seed"], rig.twin.record.id,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "record_path" => rig.record_path,
            "shots" => result.shots,
            "design" => "ground + excited preparations, $(result.shots) shots each",
            "t1_correction" => string(
                "e row T1-corrected over the payload's played window " *
                "($(w_us) µs) at the believed T1 ($T1_bel µs): s = $s"),
            "prep_note" => string(
                "the measured confusion is the assignment matrix of the " *
                "preparations AS PLAYED — the e row's flip deficit (the π " *
                "calibration's own scale) rides it; the g row is prep-pure"),
            "evidence_class" => "twin-rehearsal",
            "tool" => "Strumento v$(pkgversion(Strumento)), julia $(VERSION)",
        ))
end

"""The `write_back` seam (#38 wraps here): the measured confusion lands in
the twin's BELIEF via `calibrate!` in the wrapped noise form the transfer
machinery consumes (`{value, estimate => false, note}` — the
`BosonicCalibration` write-back's own form, now produced by a bring-up
procedure). The record keeps its estimate-flagged placeholder."""
function write_back!(rig::RehearsalRig, res::ReadoutConfusionResult)
    calibrate!(rig.twin, Dict{String,Any}(
        "readout_confusion" => Dict{String,Any}(
            "value" => [[res.confusion[i, j] for j in 1:size(res.confusion, 2)]
                        for i in 1:size(res.confusion, 1)],
            "estimate" => false,
            "note" => "measured readout calibration through the wire " *
                      "(twin-rehearsed; the confusion procedure, issue #37)",
        ),
    ))
    return rig
end

"""
    run_confusion_calibration(rig, design; jobs = fixture_confusion_jobs) -> ReadoutConfusionResult

The confusion chain, one call: propose → compile → run over the wire → fit →
write back. `jobs` is the compile seam's source: the committed fixture
payloads (the default — the Julia-only lane) or a live bridge source (the
PythonCall extension's `compile_ge_pi` at gain 0 and at the design's
`pi_gain_frac`).

Everything is a pure function of (rig, design, jobs, the twin's seed): a
procedure run replays bit-exactly from its seed across fresh processes.
"""
function run_confusion_calibration(rig::RehearsalRig,
                                   design::ReadoutConfusionDesign;
                                   jobs = fixture_confusion_jobs)
    schedule = propose_confusion(rig, design)
    payloads = jobs isa Function ? jobs(rig, schedule) : jobs
    result = run_confusion_over_wire(rig, schedule, payloads)
    fitres = fit_confusion(rig, design, result)
    write_back!(rig, fitres)
    return fitres
end

# ─── The composed bring-up pass (issue #37, the calibration set in one seed) ──
#
# The bring-up layer's first end-to-end shape: the full calibration set over
# one rig in one seeded sequence — χ (the comb), the π-gain (the Rabi ladder),
# the ancilla detuning (the Ramsey fringe), T1 (the decay curve), the readout
# confusion (the two preparations) — each procedure writing its belief
# entries via `calibrate!`, the drift moving truth only throughout. The
# ORDER is the calibration dependency: the Ramsey's model reads the
# belief's χ (the comb's fresh entry), the confusion's T1 correction reads
# the belief's T1 (the T1 procedure's fresh entry). The #38 supervision
# layer wraps this pass later; the drift-aware schedule (when to re-run
# which procedure, from the record's own drift priors) is the next slice.

"""The composed pass's outcome: the five procedures' fit results, the belief
snapshot after the pass, and the rehearsal provenance."""
struct BringupPassResult
    resonator::ResonatorSweepFit
    rabi::RabiSweepFit
    ramsey::RamseyFringeFit
    t1::T1DecayFit
    confusion::ReadoutConfusionResult
    belief_after::Dict{String,Any}
    seed::Any
    record_id::String
    provenance::Dict{String,Any}
end

"""
    run_bringup_pass(rig; comb, rabi, ramsey, t1, confusion) -> BringupPassResult

The composed bring-up pass, one call over one rig: the full calibration set
in dependency order (comb → Rabi → Ramsey → T1 → confusion), every procedure
running its whole chain (propose → compile → run over the wire → fit →
write back) and its belief entries landing via `calibrate!`. The
truth/belief invariant is the twin contract's — each procedure's own
testitem asserts it live; the pass's testitem asserts the truth untouched
across the whole pass.

Everything is a pure function of (rig, designs, the twin's seed): the pass
replays bit-exactly from its seed across fresh processes (the replay check:
`test/configurations/calibration_replay_check.jl`).
"""
function run_bringup_pass(rig::RehearsalRig;
                          comb = ResonatorSweepDesign(),
                          rabi = RabiSweepDesign(),
                          ramsey = RamseyFringeDesign(),
                          t1 = T1DecayDesign(),
                          confusion = ReadoutConfusionDesign())
    resonator = run_resonator_sweep(rig, comb)
    rabi_res = run_rabi_sweep(rig, rabi)
    ramsey_res = run_ramsey_sweep(rig, ramsey)
    t1_res = run_t1_sweep(rig, t1)
    confusion_res = run_confusion_calibration(rig, confusion)
    return BringupPassResult(resonator, rabi_res, ramsey_res, t1_res,
        confusion_res, copy(believed(rig.twin)), rig.seed, rig.twin.record.id,
        Dict{String,Any}(
            "record_id" => rig.twin.record.id,
            "record_path" => rig.record_path,
            "order" => "comb -> rabi -> ramsey -> t1 -> confusion",
            "evidence_class" => "twin-rehearsal",
            "tool" => "Strumento v$(pkgversion(Strumento)), julia $(VERSION)",
        ))
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

# ─── The calibration set (issue #37, M4a-3) ─────────────────────────────────────
# The three procedures that complete the bosonic bring-up set — Ramsey (the
# ancilla detuning), T1 (the decay constant), the readout confusion — plus the
# composed bring-up pass that runs the whole set over one rig in one seeded
# sequence. Same skeleton as the keystone and the Rabi slice: propose →
# compile → run over the wire → fit → write back, every seam named for the
# #38 supervision layer.

@testitem "the Ramsey procedure recovers the ancilla detuning from the delay fringe within the DERIVED tolerance (the belief entry)" begin
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
        pc = Base.get_extension(Strumento, :StrumentoPiccoloExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        # a DRIFTED twin (the rehearsal posture): χ aged off the record — the
        # ancilla transition sits detuned from its believed position at the
        # calibration photon number, and THAT is what the fringe measures
        plan = DriftPlan(:chi_kHz => [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0,
                                                        mu = -298.4)])
        make_rig(seed) = ext.RehearsalRig(record, device, soccfg, wiring;
                                         drift = plan, seed = seed,
                                         overlay_id = "rehearsal-v2")
        rig = make_rig(0xC0FFEE)
        try
            advance!(rig.twin, 3.0)
            χ_true = rig.twin.truth[:chi_kHz]
            χ_bel = believed(rig.twin)["chi_kHz"]
            n̄ = ext.RamseyFringeDesign().displacement_alpha^2
            detuning_true = n̄ * (χ_true - χ_bel)
            n_truth = length(rig.twin.truth)
            @test !haskey(believed(rig.twin), "detuning_kHz")   # no prior entry

            design = ext.RamseyFringeDesign()
            fitres = ext.run_ramsey_sweep(rig, design)  # propose -> wire -> fit -> write back

            # ── the fit is REAL and recovers the detuning within the DERIVED
            # tolerance (5·σ, σ from the fit's observed binomial information)
            @test fitres.detuning_kHz !== nothing
            @test abs(fitres.detuning_kHz - detuning_true) < fitres.detuning_tolerance_kHz
            @test fitres.detuning_tolerance_kHz ≈ pc.BOSONIC_CERT_TOLERANCE_SIGMA *
                                                    fitres.detuning_sigma_kHz
            # a real information scale (the fringe's collapse-revival contrast)
            @test 0.01 < fitres.detuning_sigma_kHz < 30.0
            # the fit is a real procedure: the estimate sits off the truth
            # (shot noise) with a sound residual
            @test fitres.detuning_kHz != detuning_true
            @test 0.05 < fitres.chi2_dof < 4.0

            # the belief-agreement flag is its DEFINITION: with no prior
            # detuning belief there is nothing to disagree with
            @test fitres.agrees_with_belief

            # ── the write-back: the detuning belief entry lands via
            # calibrate!; believed reflects it; the invariants hold live
            b = believed(rig.twin)
            @test b["detuning_kHz"] == fitres.detuning_kHz
            @test length(b) == 8                       # the record's 7 + detuning
            @test length(rig.twin.truth) == n_truth    # truth keys untouched
            @test !any(==(Symbol("detuning_kHz")), keys(rig.twin.truth))
            @test rig.twin.truth[:chi_kHz] == χ_true   # truth never moved

            # drift moves truth ONLY: aging the twin leaves the calibrated
            # belief exactly where the write-back put it
            advance!(rig.twin, 1.0)
            @test believed(rig.twin)["detuning_kHz"] == fitres.detuning_kHz
            @test rig.twin.truth[:chi_kHz] != χ_true

            # the rehearsal evidence marking
            @test fitres.provenance["evidence_class"] == "twin-rehearsal"
            @test fitres.seed == 0xC0FFEE
            @test fitres.record_id == rig.twin.record.id

            # ── the propose seam's recalibration validation: once the belief
            # carries the detuning, a bracket that does not span it is
            # refused — the belief and the schedule disagree
            err = try
                ext.propose_ramsey(rig, ext.RamseyFringeDesign(
                    delays_us = 0.0:0.8:6.4, halfbracket_kHz = 1e-6)); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("does not span", sprint(showerror, err))

            # a RE-CALIBRATION against the prior belief: the second run's
            # agrees_with_belief is computed against the written-back entry
            fit2 = ext.run_ramsey_sweep(rig, design)
            @test fit2.agrees_with_belief ==
                  (abs(fit2.detuning_kHz - fitres.detuning_kHz) ≤
                   fit2.detuning_tolerance_kHz)
        finally
            ext.stop!(rig)
        end

        # ── seeded replay, in-process form: two FRESH rigs with the same seed
        # reproduce the whole procedure bit-exactly; a different seed differs
        run_it(seed) = begin
            r = make_rig(seed)
            try
                advance!(r.twin, 3.0)
                ext.run_ramsey_sweep(r, ext.RamseyFringeDesign(
                    delays_us = 0.0:0.8:6.4, reps = 20))
            finally
                ext.stop!(r)
            end
        end
        a = run_it(0x5EED)
        b_replay = run_it(0x5EED)
        c = run_it(0xFEED)
        @test a.detuning_kHz == b_replay.detuning_kHz &&
              a.detuning_sigma_kHz == b_replay.detuning_sigma_kHz
        @test a.detuning_kHz != c.detuning_kHz
    end
end

@testitem "the T1 procedure recovers the decay constant within the DERIVED tolerance (the belief entry superseding the record's estimate-flagged placeholder)" begin
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
        pc = Base.get_extension(Strumento, :StrumentoPiccoloExt)

        fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
        record = joinpath(fixtures, "twins", "bosonic.md")
        device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
        soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
        wiring = TwinWiringMap([
            TwinGenWiring(2, 1, 2; line = "qubit.drive"),
            TwinGenWiring(3, 3, 4; line = "manipulate.main"),
        ]; n_drives = 4)

        # the record file BEFORE the procedure — records change by vault
        # commit, never by procedure (the record's estimate-flagged T1
        # placeholder is superseded IN BELIEF ONLY)
        record_before = read(record, String)
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
            t1_truth = Float64(rig.twin.record.noise["T1_q_us"]["value"])
            # the belief carries NO T1 yet (the record keeps it in noise,
            # estimate-flagged — the placeholder nothing could ever replace)
            @test !haskey(believed(rig.twin), "T1_q_us")
            @test rig.twin.record.noise["T1_q_us"]["estimate"] == true

            design = ext.T1DecayDesign()
            fitres = ext.run_t1_sweep(rig, design)  # propose -> wire -> fit -> write back

            # ── the fit is REAL and recovers the decay constant within the
            # DERIVED tolerance (5·σ from the exponential fit's observed
            # binomial information over (offset, amplitude, T1))
            @test fitres.T1_q_us !== nothing
            @test abs(fitres.T1_q_us - t1_truth) < fitres.T1_tolerance_q_us
            @test fitres.T1_tolerance_q_us ≈ pc.BOSONIC_CERT_TOLERANCE_SIGMA *
                                              fitres.T1_sigma_q_us
            # a real information scale, and the tolerance MEANS something:
            # 5σ resolves a small fraction of the decay constant itself
            @test 1e-3 < fitres.T1_sigma_q_us < 5.0
            @test fitres.T1_tolerance_q_us < 0.1 * t1_truth
            # the fit is a real procedure: the estimate sits off the truth
            # (shot noise) with a sound residual
            @test fitres.T1_q_us != t1_truth
            @test 0.05 < fitres.chi2_dof < 4.0

            # the belief-agreement flag: no prior T1 belief — nothing to
            # disagree with
            @test fitres.agrees_with_belief

            # ── the write-back: the T1 belief entry lands via calibrate!,
            # superseding the record's estimate-flagged placeholder IN BELIEF
            # ONLY — the record itself is never touched
            b = believed(rig.twin)
            @test b["T1_q_us"] == fitres.T1_q_us
            @test length(b) == 8                       # the record's 7 + T1
            @test length(rig.twin.truth) == n_truth    # truth keys untouched
            @test !any(==(Symbol("T1_q_us")), keys(rig.twin.truth))
            # the RECORD still carries its estimate-flagged placeholder, and
            # the record FILE is byte-identical (records change by vault
            # commit, never by procedure)
            @test rig.twin.record.noise["T1_q_us"]["value"] == 120.0
            @test rig.twin.record.noise["T1_q_us"]["estimate"] == true
            @test read(record, String) == record_before
            # the supersession is stated in the fit's own provenance
            @test occursin("placeholder", fitres.provenance["supersedes"])
            @test occursin("belief", fitres.provenance["supersedes"])

            # drift moves truth ONLY
            advance!(rig.twin, 1.0)
            @test believed(rig.twin)["T1_q_us"] == fitres.T1_q_us
            @test rig.twin.truth[:chi_kHz] != truth_chi

            # the rehearsal evidence marking
            @test fitres.provenance["evidence_class"] == "twin-rehearsal"
            @test fitres.seed == 0xC0FFEE
            @test fitres.record_id == rig.twin.record.id

            # ── the propose seam's belief/schedule validation: a delay span
            # that does not resolve the believed T1 measures nothing useful
            err = try
                ext.propose_t1(rig, ext.T1DecayDesign(delays_us = [0.0, 10.0]));
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("resolve", sprint(showerror, err))

            # ── a RE-CALIBRATION against the prior belief
            fit2 = ext.run_t1_sweep(rig, design)
            @test fit2.agrees_with_belief ==
                  (abs(fit2.T1_q_us - fitres.T1_q_us) ≤ fit2.T1_tolerance_q_us)
        finally
            ext.stop!(rig)
        end

        # ── seeded replay, in-process form
        run_it(seed) = begin
            r = make_rig(seed)
            try
                advance!(r.twin, 3.0)
                ext.run_t1_sweep(r, ext.T1DecayDesign())
            finally
                ext.stop!(r)
            end
        end
        a = run_it(0x5EED)
        b_replay = run_it(0x5EED)
        c = run_it(0xFEED)
        @test a.T1_q_us == b_replay.T1_q_us && a.T1_sigma_q_us == b_replay.T1_sigma_q_us
        @test a.T1_q_us != c.T1_q_us
    end
end

@testitem "the confusion procedure recovers the measured-confusion belief entry from the response statistics (the transfer consumer's source)" begin
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
        pc = Base.get_extension(Strumento, :StrumentoPiccoloExt)

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
        make_rig(seed) = ext.RehearsalRig(record, device, soccfg, wiring;
                                         drift = plan, seed = seed,
                                         overlay_id = "rehearsal-v2")
        rig = make_rig(0xC0FFEE)
        try
            advance!(rig.twin, 3.0)
            n_truth = length(rig.twin.truth)
            Crows = rig.twin.record.noise["readout_confusion"]["value"]
            C = [Float64(Crows[i][j]) for i in 1:2, j in 1:2]
            # the belief carries no measured confusion yet
            @test !haskey(believed(rig.twin), "readout_confusion")

            design = ext.ReadoutConfusionDesign()
            res = ext.run_confusion_calibration(rig, design)  # count -> correct -> write back

            # ── the recovery, within DERIVED bounds: the g row is prep-pure
            # (a played zero drive) — its bound is the pure binomial 5σ of
            # the counts; the e row rides the operating-point π (its flip
            # deficit is the π calibration's own scale — the Rabi paired
            # proof's 5-point margin) and the T1 correction over the payload
            # window
            Ĉ = res.confusion
            @test size(Ĉ) == (2, 2)
            @test all(>=(0), Ĉ)
            @test all(i -> isapprox(sum(Ĉ[i, :]), 1.0; atol = 0.01), 1:2)
            shots = res.provenance["shots"]
            for j in 1:2
                q = C[1, j]
                σ = sqrt(max(q * (1 - q), 1e-9) / shots)
                @test abs(Ĉ[1, j] - q) < 5σ            # the g row: 5σ binomial
                @test abs(Ĉ[2, j] - C[2, j]) < 0.05    # the e row: prep-limited
            end
            # the derived per-entry scales are carried on the result
            @test res.sigma_entries isa Matrix && size(res.sigma_entries) == (2, 2)
            @test all(>(0), res.sigma_entries)

            # ── the write-back: the measured-confusion belief entry lands in
            # the wrapped noise form the transfer consumer reads — the record
            # keeps its estimate-flagged placeholder, never edited
            b = believed(rig.twin)
            wrapped = b["readout_confusion"]
            @test wrapped isa AbstractDict && haskey(wrapped, "value")
            @test wrapped["estimate"] == false          # measured, not placeholder
            @test [wrapped["value"][i][j] for i in 1:2, j in 1:2] == Ĉ
            @test length(b) == 8                        # the record's 7 + the entry
            @test length(rig.twin.truth) == n_truth     # truth keys untouched
            @test rig.twin.record.noise["readout_confusion"]["estimate"] == true
            # the TRANSFER machinery's own consumer reads it back (the
            # certification's belief-side confusion unwrap)
            @test pc._cert_belief_confusion(rig.twin) == Ĉ

            # drift moves truth ONLY
            advance!(rig.twin, 1.0)
            @test pc._cert_belief_confusion(rig.twin) == Ĉ

            # the rehearsal evidence marking
            @test res.provenance["evidence_class"] == "twin-rehearsal"
            @test res.seed == 0xC0FFEE
            @test res.record_id == rig.twin.record.id
        finally
            ext.stop!(rig)
        end

        # ── seeded replay, in-process form
        run_it(seed) = begin
            r = make_rig(seed)
            try
                ext.run_confusion_calibration(r, ext.ReadoutConfusionDesign())
            finally
                ext.stop!(r)
            end
        end
        a = run_it(0x5EED)
        b_replay = run_it(0x5EED)
        c = run_it(0xFEED)
        @test a.confusion == b_replay.confusion
        @test a.confusion != c.confusion
    end
end

@testitem "the composed bring-up pass: the full calibration set over one rig in one seeded sequence" begin
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

        # a DRIFTED twin (the rehearsal posture): the pass calibrates the
        # belief against aged truth, the whole set in one seeded sequence
        plan = DriftPlan(:chi_kHz => [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0,
                                                        mu = -298.4)])
        rig = ext.RehearsalRig(record, device, soccfg, wiring;
                               drift = plan, seed = 0xC0FFEE,
                               overlay_id = "rehearsal-v2")
        try
            advance!(rig.twin, 3.0)
            truth_before = copy(rig.twin.truth)
            χ_true = rig.twin.truth[:chi_kHz]
            t1_truth = Float64(rig.twin.record.noise["T1_q_us"]["value"])
            @test length(believed(rig.twin)) == 7     # the record's parameters
            @test !haskey(believed(rig.twin), "detuning_kHz")
            @test !haskey(believed(rig.twin), "T1_q_us")
            @test !haskey(believed(rig.twin), "readout_confusion")

            # REDUCED variants of the pinned designs (the phase-commit
            # discipline — the composed item stays inside the suite's budget
            # without changing the story; the full designs are the replay
            # check's business)
            comb = ext.ResonatorSweepDesign(
                freqs_kHz = vcat(collect(230.0:24.0:350.0),
                                 collect(520.0:24.0:640.0)), reps = 20)
            rabi = ext.RabiSweepDesign(reps = 20)
            ramsey = ext.RamseyFringeDesign(delays_us = 0.0:0.8:6.4, reps = 20)
            t1 = ext.T1DecayDesign(reps = 20)
            confusion = ext.ReadoutConfusionDesign(reps = 20)

            pass = ext.run_bringup_pass(rig; comb = comb, rabi = rabi,
                                        ramsey = ramsey, t1 = t1,
                                        confusion = confusion)

            # ── every procedure recovered its truth within its own DERIVED
            # tolerance (the beliefs were calibrated against AGED truth)
            @test abs(pass.resonator.chi_kHz - χ_true) < pass.resonator.chi_tolerance_kHz
            @test pass.rabi.agrees_with_belief          # the fresh pi_gain entry
            n̄ = ramsey.displacement_alpha^2
            @test abs(pass.ramsey.detuning_kHz - n̄ * (χ_true - pass.resonator.chi_kHz)) <
                  pass.ramsey.detuning_tolerance_kHz
            @test abs(pass.t1.T1_q_us - t1_truth) < pass.t1.T1_tolerance_q_us

            # ── ALL the belief entries landed, in dependency order: χ (the
            # comb), the pi_gain pair (the Rabi), the detuning (the Ramsey,
            # against the comb's fresh χ), T1 (the decay), the measured
            # confusion (its T1 correction riding the fresh T1 entry)
            b = believed(rig.twin)
            @test b["chi_kHz"] == pass.resonator.chi_kHz
            @test b["pi_gain"] == pass.rabi.pi_gain
            @test b["pi_rabi_mhz"] == pass.rabi.pi_rabi_mhz
            @test b["detuning_kHz"] == pass.ramsey.detuning_kHz
            @test b["T1_q_us"] == pass.t1.T1_q_us
            @test b["readout_confusion"]["estimate"] == false
            @test pass.confusion.T1_used_q_us == pass.t1.T1_q_us  # the composed T1
            @test b == pass.belief_after                    # the snapshot is live
            @test length(b) == 12   # the record's 7 + the pi-gain pair, detuning,
            # T1, and the measured confusion (χ itself is a record parameter —
            # the comb CALIBRATES it; it is not a new key)

            # ── the truth/belief invariant across the WHOLE pass: drift moved
            # truth (the aged value the procedures measured), the pass moved
            # belief only, and truth is exactly where the aging left it
            @test rig.twin.truth == truth_before            # the pass never touched truth
            @test rig.twin.truth[:chi_kHz] != believed(rig.twin)["chi_kHz"]
            # the belief's calibrated χ is the AGED truth, not the record
            @test abs(believed(rig.twin)["chi_kHz"] - rig.twin.truth[:chi_kHz]) <
                  pass.resonator.chi_tolerance_kHz

            # ── the composed pass is one SEEDED sequence: two FRESH rigs with
            # the same seed reproduce it bit-exactly (the reduced designs);
            # a different seed differs
            run_pass(seed) = begin
                r = ext.RehearsalRig(record, device, soccfg, wiring;
                                     drift = plan, seed = seed,
                                     overlay_id = "rehearsal-v2")
                try
                    advance!(r.twin, 3.0)
                    ext.run_bringup_pass(r; comb = comb, rabi = rabi,
                                         ramsey = ramsey, t1 = t1,
                                         confusion = confusion)
                finally
                    ext.stop!(r)
                end
            end
            a = run_pass(0x5EED)
            b_replay = run_pass(0x5EED)
            c = run_pass(0xFEED)
            @test a.resonator.chi_kHz == b_replay.resonator.chi_kHz
            @test a.ramsey.detuning_kHz == b_replay.ramsey.detuning_kHz
            @test a.t1.T1_q_us == b_replay.t1.T1_q_us
            @test a.confusion.confusion == b_replay.confusion.confusion
            @test a.resonator.chi_kHz != c.resonator.chi_kHz
        finally
            ext.stop!(rig)
        end
    end
end
