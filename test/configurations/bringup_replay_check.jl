# Fresh-process replay check for the bring-up keystone chain (issue #31).
#
# The replay invariant is absolute: identical (record, seed, design, payload
# set) inputs reproduce the ENTIRE procedure bit-exactly — across fresh
# processes, including the in-process Python compile when the reference env
# is present. This script runs the resonator sweep end-to-end (propose ->
# compile -> submit over the wire -> fit -> write-back) and prints a
# canonical serialization: the mode, every compiled payload's wire JSON
# (byte-exact across processes — the Python compile's determinism pin), and
# the fit result's canonical fields. Run it TWICE and the outputs must be
# byte-identical (diff). The bridge lane runs when Python `strumento` is
# importable (the dev machine's reference env); the fixture lane otherwise
# (CI's pure-Julia lane) — the lane is printed as the first line, so compare
# like with like.
#
# Requires an environment with this repo dev'd and Piccolo + JSON added (plus
# PythonCall for the bridge lane) — e.g.:
#
#   julia --startup-file=no -e 'using Pkg; Pkg.activate("/tmp/strumento-bringup");
#       Pkg.develop(path = "/path/to/Strumento.jl");
#       Pkg.add(["Piccolo", "JSON", "PythonCall"]); Pkg.instantiate()'
#   julia --startup-file=no --project=/tmp/strumento-bringup \
#       test/configurations/bringup_replay_check.jl /path/to/repo > run1.txt
#   julia --startup-file=no --project=/tmp/strumento-bringup \
#       test/configurations/bringup_replay_check.jl /path/to/repo > run2.txt
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

"""The whole chain, invoked through `Base.invokelatest` so every method
loaded at the top level (the extensions, PythonCall when present) is
callable. The compile lane: the live bridge when Python `strumento` is
importable, else the committed fixture payloads — the payload JSON lines
pin the compile's determinism either way."""
function run_chain()
    rig = bu.RehearsalRig(record, device, soccfg, wiring;
                         drift = plan, seed = 0xC0FFEE, overlay_id = "rehearsal-v2")
    try
        advance!(rig.twin, 3.0)
        design = bu.ResonatorSweepDesign()

        lane = "fixtures"
        jobs = nothing
        if HAVE_PYTHONCALL
            pext = Base.get_extension(Strumento, :StrumentoPythonCallExt)
            pext === nothing && error(
                "bringup_replay_check: PythonCall loaded but its extension did not attach")
            st = try
                PythonCall = Base.require(Base.identify_package("PythonCall"))
                Base.invokelatest(PythonCall.pyimport, "strumento")
            catch e
                nothing
            end
            if st !== nothing
                bridge = pext.BringupBridge(device; overlay_id = "rehearsal-v2")
                jobs = (r, s) -> bu.point_jobs(
                    f -> pext.compile_comb_point(bridge; bu.comb_geometry(design)...,
                                                 f_kHz = f), r, s)
                lane = "bridge"
            end
        end

        schedule = bu.propose(rig, design)
        payloads = jobs === nothing ? bu.fixture_comb_jobs(rig, schedule) : jobs(rig, schedule)
        result = bu.run_over_wire(rig, schedule, payloads)
        println("lane: ", lane)
        for job in result.jobs
            println("point_kHz=", string(job.point_kHz))
            println(JSON.json(job.job_wire))
        end
        fitres = bu.fit(rig, design, result)
        bu.write_back!(rig, fitres)

        # canonical serialization of the outcome (shortest-round-trip reprs —
        # identical bits print identically)
        println("truth_chi_kHz=", string(rig.twin.truth[:chi_kHz]))
        println("fitted_chi_kHz=", string(fitres.chi_kHz))
        println("chi_sigma_kHz=", string(fitres.chi_sigma_kHz))
        println("chi_tolerance_kHz=", string(fitres.chi_tolerance_kHz))
        println("chi2_dof=", string(fitres.chi2_dof))
        println("agrees_with_belief=", string(fitres.agrees_with_belief))
        println("believed_chi_kHz=", string(believed(rig.twin)["chi_kHz"]))
    finally
        bu.stop!(rig)
    end
    return nothing
end

Base.invokelatest(run_chain)
