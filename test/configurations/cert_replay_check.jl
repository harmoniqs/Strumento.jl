# Fresh-process replay check for the certification gates (issue #22).
#
# The replay invariant is absolute: identical (record, seed, design) inputs
# reproduce identical certification results bit-exactly — across FRESH
# PROCESSES. This script prints a canonical serialization of the two gates on
# a fixed seed and perturbation: gate 1 (parameter recovery, perturbed twin)
# and gate 2's metric numbers (calibration transfer). Run it TWICE and the
# outputs must be byte-identical (diff). Requires an environment with this
# repo dev'd and Piccolo added — e.g.:
#
#   julia --startup-file=no -e 'using Pkg; Pkg.activate("/tmp/strumento-cert");
#       Pkg.develop(path = "/path/to/Strumento.jl"); Pkg.add("Piccolo");
#       Pkg.instantiate()'
#   julia --startup-file=no --project=/tmp/strumento-cert \
#       test/configurations/cert_replay_check.jl /path/to/repo > run1.txt
#   julia --startup-file=no --project=/tmp/strumento-cert \
#       test/configurations/cert_replay_check.jl /path/to/repo > run2.txt
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

ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)

fixture = joinpath(REPO, "test", "fixtures", "twins", "bosonic.md")
seed = 0xC0FFEE
pert = Dict(:chi_kHz => 8.0, :K_c_kHz => -2.0)

# gate 1: parameter recovery on the perturbed twin (a lean design keeps the
# ritual affordable; the replay property is design-independent)
design = ext.BosonicCertDesign(
    comb_freqs_kHz = vcat(collect(230.0:30.0:350.0), collect(520.0:30.0:640.0)),
    ramsey_freqs_kHz = collect(250.0:13.0:354.0),
    comb_shots = 100_000, ramsey_shots = 100_000,
    chi_halfbracket_kHz = 10.0, K_c_halfbracket_kHz = 6.0,
    fit_grid_step_kHz = 2.5)

r = ext.certify_parameter_recovery(fixture; seed = seed,
                                   perturbation = pert, design = design)
println("recovery: chi_kHz=", r.chi_kHz, " sigma=", r.chi_sigma_kHz,
        " chi2_dof=", r.chi_chi2_dof)
println("recovery: K_c_kHz=", r.K_c_kHz, " sigma=", r.K_c_sigma_kHz,
        " K_c_chi2_dof=", r.K_c_chi2_dof, " kappa=", r.provenance["chi_propagation_kappa"])
println("recovery: agrees_with_record=", r.agrees_with_record)

# gate 2: the transfer metrics on a same-class pair (the same lean design)
t = ext.certify_calibration_transfer(fixture;
    seed_a = seed, perturbation_a = pert,
    seed_b = 0xBEEF, perturbation_b = Dict(:chi_kHz => 10.5, :K_c_kHz => -2.8),
    design = design)
println("transfer: baseline=", t.metric_baseline,
        " calibrated=", t.metric_calibrated, " improved=", t.improved)
println("transfer: cal_chi=", t.calibration.chi_kHz, " cal_K_c=", t.calibration.K_c_kHz)
println("transfer: cal_confusion=", t.calibration.confusion)