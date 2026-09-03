# Fresh-process replay check for the spin DC path (issue #35, M4b-1).
#
# The replay invariant is absolute (the TwinSoc discipline): identical seeds
# reproduce identical measurement sequences bit-exactly — across FRESH
# PROCESSES. This script is the cross-process form of the in-suite seeded
# replay: it prints a canonical serialization (shortest-round-trip reprs —
# identical bits print identically) of a fixed seeded DC sweep — gate controls
# driven through the verbs, the charge-sensor readout through the twin's
# response machinery with shot sampling ON (64 shots) and drift ON (OU on the
# exchange truth, dt = 1.0: every read ages the twin after responding).
#
# Run it TWICE and the outputs must be byte-identical (diff). Requires an
# environment with this repo dev'd and Piccolo added — e.g. the piccolo
# configuration environment built by load_config_check.jl:
#
#   julia --startup-file=no test/configurations/load_config_check.jl \
#       piccolo /path/to/repo
#   julia --startup-file=no --project=/tmp/strumento-config-piccolo \
#       test/configurations/spin_replay_check.jl /path/to/repo > run1.txt
#   julia --startup-file=no --project=/tmp/strumento-config-piccolo \
#       test/configurations/spin_replay_check.jl /path/to/repo > run2.txt
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
TwinSoc = ext.TwinSoc

fixture = joinpath(REPO, "test", "fixtures", "twins", "spin.md")
plan = DriftPlan(:J_max_MHz => [OrnsteinUhlenbeck(theta = 0.1, sigma = 1.0, mu = 95.0)])

twin = instantiate(fixture; drift = plan, seed = 0x5EED)
soc = TwinSoc(twin; families = Dict("spin" => ext.spin_landscape_builder(twin.record)),
              shots = 64, dt = 1.0)

# the fixed sweep: the detuning axis across the inter-dot transition, three
# passes (each pass ages the twin 11 more days — the drifted truth is felt)
volts = collect(range(-0.4, 0.4, length = 11))
for pass in 1:3
    set_gate!(soc, "R", 0.0)
    trace = ext.charge_sensor_sweep(soc, "L", volts)
    println("pass $pass twin_t=", soc.twin.t, " J_max=", soc.twin.truth[:J_max_MHz])
    for (k, blob) in enumerate(trace)
        println("  point $k v=", volts[k], ": ", blob)
    end
end
