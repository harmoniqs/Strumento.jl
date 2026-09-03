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
            bridge = pext.BringupBridge(device; overlay_id = "rehearsal-v2")
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
                    wire = pext.compile_rabi_sweep(bridge; ext.rabi_geometry(design)...)
                    ext.RabiJob(wire, ext._job_shots(r, wire))
                end
                fitres = ext.run_rabi_sweep(rig_cal, design; job = live_design_job)
                @test believed(rig_cal.twin)["pi_gain"] == fitres.pi_gain
                @test fitres.provenance["evidence_class"] == "twin-rehearsal"

                # the downstream compiles: the ge_pi factory at the believed
                # gain (the belief-scaled path — the fraction the
                # calibration store carries) vs the uncalibrated baseline
                # (the device calibration's own stale gain)
                cal_wire = pext.compile_ge_pi(bridge;
                                              gain_frac = believed(rig_cal.twin)["pi_gain"],
                                              reps = 50, soft_avgs = 1)
                base_wire = pext.compile_ge_pi(bridge; reps = 50, soft_avgs = 1)
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
