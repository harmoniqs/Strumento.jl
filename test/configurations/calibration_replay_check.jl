# Fresh-process replay check for the calibration set + the composed bring-up
# pass (issue #37, M4a-3).
#
# The replay invariant is absolute (the keystone's discipline): identical
# (record, seed, designs, payloads) inputs reproduce the ENTIRE composed
# pass bit-exactly — across fresh processes, including the in-process Python
# compile when the reference env is present. This script runs the whole
# bring-up pass (comb -> Rabi -> Ramsey -> T1 -> confusion, each procedure
# propose -> compile -> submit over the wire -> fit -> write-back) and prints
# a canonical serialization: the mode, the new procedures' compiled payload
# wire JSONs (byte-exact across processes — the comb's and Rabi's payloads are
# pinned by their own replay checks), every fit's canonical fields, and the
# believed entries after the pass. Run it TWICE and the outputs must be
# byte-identical (diff). The bridge lane runs when Python `strumento` is
# importable (the dev machine's reference env — see the invocation note
# below); the fixture lane otherwise (CI's Python-free lane — the chain
# against the committed payloads).
# The lane is the first line, so compare like with like.
#
# Requires an environment with this repo dev'd and Piccolo + JSON added
# (plus PythonCall for the bridge lane) — e.g.:
#
#   julia --startup-file=no -e 'using Pkg; Pkg.activate("/tmp/strumento-bringup");
#       Pkg.develop(path = "/path/to/Strumento.jl");
#       Pkg.add(["Piccolo", "JSON", "PythonCall"]); Pkg.instantiate()'
#   julia --startup-file=no --project=/tmp/strumento-bringup \
#       test/configurations/calibration_replay_check.jl /path/to/repo > run1.txt
#   julia --startup-file=no --project=/tmp/strumento-bringup \
#       test/configurations/calibration_replay_check.jl /path/to/repo > run2.txt
#   diff run1.txt run2.txt   # must be empty
#
# The BRIDGE lane's reference env (the fixture-generation stack — the bridge
# must reproduce the committed payloads byte-identically, so it needs the
# fixture-generation qick): strumento at the audit-remediation-2026-09-13
# line (or the matching state) with qick 0.2.422, e.g. a scratch conda env
# with python3.10 + `pip install qick==0.2.422 pydantic pyyaml numpy` +
# `pip install -e <strumento clone>`, then:
#
#   CONDA_PREFIX=<env> PATH=<env>/bin:$PATH JULIA_CONDAPKG_BACKEND=Current \
#     julia --startup-file=no --project=... this script ...
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

bu = Base.get_extension(Strumento, :StrumentoBringupExt)
bu === nothing && error("the bring-up extension is not loaded (Piccolo + JSON)")

# PythonCall loads at the TOP LEVEL (before any invokelatest frame runs): the
# bridge lane's methods — defined when the extension attaches — must be
# callable from the chain's world. The lane is probed here and consumed in
# `run_pass` below.
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

"""The whole composed pass, invoked through `Base.invokelatest` so every
method loaded at the top level (the extensions, PythonCall when present) is
callable. The compile lane: the live bridge when Python `strumento` is
importable — every schedule point compiled in-process through the pack's own
factories — else the committed fixture payloads. The payload JSON lines pin
the compile's determinism either way."""
function run_pass()
    rig = bu.RehearsalRig(record, device, soccfg, wiring;
                         drift = plan, seed = 0xC0FFEE, overlay_id = "rehearsal-v2")
    try
        advance!(rig.twin, 3.0)

        lane = "fixtures"
        bridge = nothing
        if HAVE_PYTHONCALL
            pext = Base.get_extension(Strumento, :StrumentoPythonCallExt)
            pext === nothing && error(
                "calibration_replay_check: PythonCall loaded but its extension " *
                "did not attach")
            st = try
                PythonCall = Base.require(Base.identify_package("PythonCall"))
                Base.invokelatest(PythonCall.pyimport, "strumento")
            catch e
                nothing
            end
            if st !== nothing
                bridge = pext.BringupBridge(device; overlay_id = "rehearsal-v2")
                lane = "bridge"
            end
        end

        # the full pinned designs (the composed item's test run uses reduced
        # variants; the replay check carries the full-design discipline)
        comb = bu.ResonatorSweepDesign()
        rabi = bu.RabiSweepDesign()
        ramsey = bu.RamseyFringeDesign()
        t1 = bu.T1DecayDesign()
        confusion = bu.ReadoutConfusionDesign()

        # the compile seams: the live bridge lane compiles every schedule
        # point through the pack's own factories; the fixture lane loads the
        # committed payloads (the payloads ARE the fixtures — the bridge
        # testitems pin byte-equality)
        ramsey_jobs = bridge === nothing ? bu.fixture_ramsey_jobs : (r, s) -> begin
            jobs = bu.RamseyJob[]
            for τ in s.delays_us
                wire = pext.compile_ramsey_point(bridge; bu.ramsey_geometry(ramsey)...,
                                                 delay_us = τ)
                push!(jobs, bu.RamseyJob(τ, wire, bu._job_shots(r, wire)))
            end
            jobs
        end
        t1_jobs = bridge === nothing ? bu.fixture_t1_jobs : (r, s) -> begin
            jobs = bu.T1Job[]
            for τ in s.delays_us
                wire = pext.compile_t1_point(bridge; bu.t1_geometry(t1)...,
                                             delay_us = τ)
                push!(jobs, bu.T1Job(τ, wire, bu._job_shots(r, wire)))
            end
            jobs
        end
        confusion_jobs = bridge === nothing ? bu.fixture_confusion_jobs :
        (r, s) -> begin
            g = pext.compile_ge_pi(bridge; gain_frac = 0.0,
                                   reps = confusion.reps, soft_avgs = confusion.soft_avgs)
            e = pext.compile_ge_pi(bridge;
                                   gain_frac = confusion.pi_gain_frac,
                                   reps = confusion.reps, soft_avgs = confusion.soft_avgs)
            [bu.ConfusionJob("ground", g, bu._job_shots(r, g)),
             bu.ConfusionJob("excited", e, bu._job_shots(r, e))]
        end

        println("lane: ", lane)

        # the pass in dependency order, with the per-procedure payloads
        # serialized (the new surface's compile determinism pin)
        resonator = begin
            jobs = bridge === nothing ? bu.fixture_comb_jobs : (r, s) -> begin
                pts = bu.BringupJob[]
                for f in s.points_kHz
                    wire = pext.compile_comb_point(bridge; bu.comb_geometry(comb)...,
                                                   f_kHz = f)
                    push!(pts, bu.BringupJob(f, wire, bu._job_shots(r, wire)))
                end
                pts
            end
            schedule = bu.propose(rig, comb)
            payloads = jobs isa Function ? jobs(rig, schedule) : jobs
            result = bu.run_over_wire(rig, schedule, payloads)
            fitres = bu.fit(rig, comb, result)
            bu.write_back!(rig, fitres)
            fitres
        end
        println("chi=", string(resonator.chi_kHz))
        println("chi_sigma=", string(resonator.chi_sigma_kHz))

        rabi_res = begin
            schedule = bu.propose_rabi(rig, rabi)
            payloads = bridge === nothing ? bu.fixture_rabi_job(rig, schedule) :
                       begin
                           wire = pext.compile_rabi_sweep(bridge;
                                                          bu.rabi_geometry(rabi)...)
                           bu.RabiJob(wire, bu._job_shots(rig, wire))
                       end
            result = bu.run_rabi_over_wire(rig, schedule, payloads)
            fitres = bu.fit_rabi(rig, rabi, result)
            bu.write_back!(rig, fitres)
            fitres
        end
        println("pi_gain=", string(rabi_res.pi_gain))
        println("pi_gain_sigma=", string(rabi_res.pi_gain_sigma))

        ramsey_res = begin
            schedule = bu.propose_ramsey(rig, ramsey)
            payloads = ramsey_jobs(rig, schedule)
            result = bu.run_ramsey_over_wire(rig, schedule, payloads)
            println("ramsey_payload_00=", JSON.json(result.jobs[1].job_wire))
            println("ramsey_payload_17=", JSON.json(result.jobs[end].job_wire))
            fitres = bu.fit_ramsey(rig, ramsey, result)
            bu.write_back!(rig, fitres)
            fitres
        end
        println("detuning=", string(ramsey_res.detuning_kHz))
        println("detuning_sigma=", string(ramsey_res.detuning_sigma_kHz))
        println("detuning_chi2_dof=", string(ramsey_res.chi2_dof))

        t1_res = begin
            schedule = bu.propose_t1(rig, t1)
            payloads = t1_jobs(rig, schedule)
            result = bu.run_t1_over_wire(rig, schedule, payloads)
            println("t1_payload_03=", JSON.json(result.jobs[4].job_wire))
            fitres = bu.fit_t1(rig, t1, result)
            bu.write_back!(rig, fitres)
            fitres
        end
        println("T1=", string(t1_res.T1_q_us))
        println("T1_sigma=", string(t1_res.T1_sigma_q_us))
        println("T1_chi2_dof=", string(t1_res.chi2_dof))

        confusion_res = begin
            schedule = bu.propose_confusion(rig, confusion)
            payloads = confusion_jobs(rig, schedule)
            result = bu.run_confusion_over_wire(rig, schedule, payloads)
            println("confusion_payload_e=", JSON.json(result.jobs[2].job_wire))
            fitres = bu.fit_confusion(rig, confusion, result)
            bu.write_back!(rig, fitres)
            fitres
        end
        println("confusion=", string(vec(confusion_res.confusion)))
        println("confusion_survive=", string(confusion_res.survive))

        # the believed entries after the whole pass (canonical, shortest-repr)
        b = believed(rig.twin)
        println("believed_chi=", string(b["chi_kHz"]))
        println("believed_pi_gain=", string(b["pi_gain"]))
        println("believed_detuning=", string(b["detuning_kHz"]))
        println("believed_T1=", string(b["T1_q_us"]))
        println("believed_confusion=", string(b["readout_confusion"]["value"]))
        println("truth_unchanged=", string(rig.twin.truth[:chi_kHz] != b["chi_kHz"]))
    finally
        bu.stop!(rig)
    end
    return nothing
end

Base.invokelatest(run_pass)
