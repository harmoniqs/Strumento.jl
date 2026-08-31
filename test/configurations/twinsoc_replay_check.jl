# Fresh-process replay check for TwinSoc (issue #20).
#
# The replay invariant is absolute: identical seeds reproduce identical
# measurement sequences bit-exactly — across FRESH PROCESSES. This script is
# the explicit cross-process form of the in-suite golden pin: it prints a
# canonical serialization (shortest-round-trip reprs — identical bits print
# identically) of a fixed seeded sequence with drift ON (OU plan, dt = 1.0)
# and shot sampling ON (64 shots), two knots per acquire, six acquires.
#
# Run it TWICE and the outputs must be byte-identical (diff). Requires an
# environment with this repo dev'd and Piccolo added — e.g. the piccolo
# configuration environment built by load_config_check.jl:
#
#   julia --startup-file=no test/configurations/load_config_check.jl \
#       piccolo /path/to/repo
#   julia --startup-file=no --project=/tmp/strumento-config-piccolo \
#       test/configurations/twinsoc_replay_check.jl /path/to/repo > run1.txt
#   julia --startup-file=no --project=/tmp/strumento-config-piccolo \
#       test/configurations/twinsoc_replay_check.jl /path/to/repo > run2.txt
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

TwinSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).TwinSoc

# the toy family (test-side): a QuantumSystem from the twin's CURRENT truth
σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
toy_family(truth) = QuantumSystem(truth[:omega] * σz, [σx, σx],
                                  [truth[:drive_bound], truth[:drive_bound]])

fixture = joinpath(REPO, "test", "fixtures", "twins", "toy.md")
plan = DriftPlan(:omega => [OrnsteinUhlenbeck(theta = 0.1, sigma = 0.2, mu = 1.0)])

# the fixed golden pulse (the MockSoc golden fixture's deterministic shape)
N = 11; T = 5.0
times = collect(range(0.0, T, length = N))
vals = 0.1 .* permutedims(hcat(sin.(range(0.0, 2.4π, length = N)),
                               cos.(range(0.3π, 1.7π, length = N))))
pulse = LinearSplinePulse(vals, times)
map = QickChannelMap([QickGenChannel(0, 5e9; i_drive = 1, q_drive = 2)]; n_drives = 2)

twin = instantiate(fixture; drift = plan, seed = 0x5EED)
soc = TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
              families = Dict("toy" => toy_family),
              shots = 64, dt = 1.0, dac_rate = 20.0)

for i in 1:6
    blobs = execute!(soc, pulse, map, [11, 101])
    println("acquire $i twin_t=", soc.twin.t, " omega=", soc.twin.truth[:omega])
    for (j, blob) in enumerate(blobs)
        println("  knot $j: ", blob)
    end
end
