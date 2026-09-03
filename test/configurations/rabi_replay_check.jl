# Fresh-process replay check for the Rabi procedure (issue #33, M4a-2).
#
# The replay invariant is absolute (the keystone's discipline): identical
# (record, seed, design, payload) inputs reproduce the ENTIRE procedure
# bit-exactly — across fresh processes, including the in-process Python
# compile when the reference env is present, and under PYTHONHASHSEED
# variation (the sweep below varies it deliberately). This script runs the
# Rabi chain end-to-end (propose -> compile -> submit over the wire -> fit
# -> write-back) plus the downstream pair (the ge_pi factory compiled at
# the believed pi_gain vs the uncalibrated baseline, both run through the
# wire) and prints a canonical serialization: the mode, every compiled
# payload's wire JSON (byte-exact across processes), the fit's canonical
# fields, and the paired responses. Run it TWICE and the outputs must be
# byte-identical (diff). The bridge lane runs when Python `strumento` is
# importable (the dev machine's reference env); the fixture lane otherwise
# (CI's Python-free lane — the chain against the committed payload; the
# downstream pair's calibrated compile is a function of the fit and rides
# the bridge lane only, so the fixture lane prints the baseline response).
# The lane is the first line, so compare like with like.
#
# Requires an environment with this repo dev'd and Piccolo + JSON added
# (plus PythonCall for the bridge lane) — e.g.:
#
#   julia --startup-file=no -e 'using Pkg; Pkg.activate("/tmp/strumento-bringup");
#       Pkg.develop(path = "/path/to/Strumento.jl");
#       Pkg.add(["Piccolo", "JSON", "PythonCall"]); Pkg.instantiate()'
#   julia --startup-file=no --project=/tmp/strumento-bringup \
#       test/configurations/rabi_replay_check.jl /path/to/repo > run1.txt
#   julia --startup-file=no --project=/tmp/strumento-bringup \
#       test/configurations/rabi_replay_check.jl /path/to/repo > run2.txt
#   diff run1.txt run2.txt   # must be empty
#
# Exit code 0 always (the check is the diff between two invocations).

const REPO = abspath(get(ARGS, 1, joinpath(@__DIR__, "..", "..")))

# Isolate the load path to THIS environment (plus stdlibs): a dev machine's
# global default environment stacked behind the active project leaks packages
# and poisons the configuration under test (same isolation as
# load_config_check.jl).
push!(empty!(LOAD_PATH), "@", "@v#.#", "@stdlib")

using Strumento
using Piccolo
using JSON

pc = Base.get_extension(Strumento, :StrumentoPiccoloExt)
bu = Base.get_extension(Strumento, :StrumentoBringupExt)
bu === nothing && error("the bring-up extension is not loaded (Piccolo + JSON)")

# PythonCall loads at the TOP LEVEL (before any invokelatest frame runs): the
# bridge lane's methods — defined when the extension attaches — must be
# callable from the chain's world. The lane is probed here and consumed in
# `run_chain` below.
const HAVE_PYTHONCALL = Base.identify_package("PythonCall") !== nothing
if HAVE_PYTHONCALL
    ENV["PYTHONUTF8"] = "1"                 # embedded-Python hygiene (µ/– in YAMLs)
    Base.require(Base.identify_package("PythonCall"))
end

using Strumento: DriftPlan, OrnsteinUhlenbeck, advance!, believed

const fixtures = joinpath(REPO, "test", "fixtures")
const record = joinpath(fixtures, "twins", "bosonic.md")
const device = joinpath(fixtures, "multimode_rehearsal", "device.yaml")
const soccfg = joinpath(fixtures, "multimode_rehearsal", "soccfg_v2_rehearsal.json")
const wiring = Strumento.TwinWiringMap(
    [Strumento.TwinGenWiring(2, 1, 2; line = "qubit.drive"),
     Strumento.TwinGenWiring(3, 3, 4; line = "manipulate.main")]; n_drives = 4)
const plan = DriftPlan(:chi_kHz =>
    [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0, mu = -298.4)])

"""The whole chain + the downstream pair, invoked through `Base.invokelatest`
so every method loaded at the top level (the extensions, PythonCall when
present) is callable. The compile lane: the live bridge when Python
`strumento` is importable, else the committed fixture payload — the payload
JSON lines pin the compile's determinism either way. The downstream pair
rides the bridge lane (the calibrated compile is a function of the fit);
the fixture lane prints the baseline response alone."""
function run_chain()
    rig = bu.RehearsalRig(record, device, soccfg, wiring;
                         drift = plan, seed = 0xC0FFEE, overlay_id = "rehearsal-v2")
    try
        advance!(rig.twin, 3.0)
        design = bu.RabiSweepDesign()

        lane = "fixtures"
        jobs = nothing
        bridge = nothing
        if HAVE_PYTHONCALL
            pext = Base.get_extension(Strumento, :StrumentoPythonCallExt)
            pext === nothing && error(
                "rabi_replay_check: PythonCall loaded but its extension did not attach")
            st = try
                PythonCall = Base.require(Base.identify_package("PythonCall"))
                Base.invokelatest(PythonCall.pyimport, "strumento")
            catch e
                nothing
            end
            if st !== nothing
                bridge = pext.BringupBridge(device; overlay_id = "rehearsal-v2")
                jobs = (r, s) -> begin
                    wire = pext.compile_rabi_sweep(bridge; bu.rabi_geometry(design)...)
                    bu.RabiJob(wire, bu._job_shots(r, wire))
                end
                lane = "bridge"
            end
        end

        schedule = bu.propose_rabi(rig, design)
        payload_job = jobs === nothing ? bu.fixture_rabi_job(rig, schedule) :
                      jobs(rig, schedule)
        println("lane: ", lane)
        println(JSON.json(payload_job.job_wire))
        result = bu.run_rabi_over_wire(rig, schedule, payload_job)
        fitres = bu.fit_rabi(rig, design, result)
        bu.write_back!(rig, fitres)

        # canonical serialization of the outcome (shortest-round-trip reprs —
        # identical bits print identically)
        println("pi_gain=", string(fitres.pi_gain))
        println("pi_gain_sigma=", string(fitres.pi_gain_sigma))
        println("pi_gain_tolerance=", string(fitres.pi_gain_tolerance))
        println("chi2_dof=", string(fitres.chi2_dof))
        println("agrees_with_belief=", string(fitres.agrees_with_belief))
        println("pi_rabi_mhz=", string(fitres.pi_rabi_mhz))
        println("believed_pi_gain=", string(believed(rig.twin)["pi_gain"]))
        println("believed_pi_rabi_mhz=", string(believed(rig.twin)["pi_rabi_mhz"]))

        # the downstream pair: the belief-scaled compile vs the uncalibrated
        # baseline, run through the wire (the bridge lane; the calibrated
        # payload is a function of the fit, never a fixture). The fixture
        # lane prints the committed baseline payload's response alone.
        pe(wire) = Float64(bu.run_job(rig.client, wire)["iq"][1][1][2])
        if bridge !== nothing
            pext = Base.get_extension(Strumento, :StrumentoPythonCallExt)
            cal_wire = pext.compile_ge_pi(bridge;
                                          gain_frac = believed(rig.twin)["pi_gain"],
                                          reps = 50, soft_avgs = 1)
            base_wire = pext.compile_ge_pi(bridge; reps = 50, soft_avgs = 1)
            println("cal_wire=", JSON.json(cal_wire))
            println("Pe_cal=", string(pe(cal_wire)))
            println("Pe_base=", string(pe(base_wire)))
        else
            base_wire = JSON.parsefile(joinpath(fixtures, "_fixtures",
                                                "gepi_baseline_rehearsal.json"))
            println("Pe_base=", string(pe(base_wire)))
        end
    finally
        bu.stop!(rig)
    end
    return nothing
end

Base.invokelatest(run_chain)
