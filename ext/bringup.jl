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
                        abspath(soccfg_path), String(overlay_id), wiring,
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
