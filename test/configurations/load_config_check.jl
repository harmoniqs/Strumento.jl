# Load-configuration checks (issue #16 — the weakdeps split).
#
# The FULL configuration (Piccolo + PythonCall both present) is covered by
# `Pkg.test()`: the `[targets]` `test` entry injects both trigger deps into the
# test sandbox, so CI's `julia-runtest` step is unchanged. The other three
# configurations cannot go through `Pkg.test` by construction — this script
# builds each environment explicitly, asserts the package's load surface, and
# runs the package's testitems (extension testitems skip cleanly when their
# trigger is absent, the same pattern the Python-strumento delegation item
# already uses).
#
# Usage (always `--startup-file=no`; no --project needed — the script
# activates the environment it builds):
#
#   julia --startup-file=no test/configurations/load_config_check.jl <mode> [<repo> [<envdir>]]
#
#   mode        environment                                what must hold
#   ─────────   ──────────────────────────────────────     ─────────────────────────────────
#   base        NO Piccolo, NO PythonCall (the board-lane  the manifest carries neither
#               guarantee)                                 trigger; `using Strumento` loads;
#                                                         the base surface (contract +
#                                                         translation data + twins) present;
#                                                         extension types absent; the base
#                                                         testitems pass
#   piccolo     Piccolo ONLY (no PythonCall)               the mock type + the typed
#                                                         translation/seam methods appear
#                                                         (via the extension); the
#                                                         delegation soc does not; the
#                                                         golden pin passes
#   pythoncall  PythonCall ONLY (no Piccolo)               the delegation soc appears (via
#                                                         the extension); the mock type and
#                                                         the typed methods do not
#
# Extension access semantics (Julia 1.12): extension exports never surface on
# the parent module — extension-defined types are reached through
# `Base.get_extension`, and the duck-typed verbs base declares dispatch to
# the extension's typed methods when loaded.
#
# Exit code 0 = the configuration holds; nonzero otherwise (each violated
# assertion is printed).

# Isolate the load path to THIS environment (plus stdlibs): a dev machine's
# global default environment (@v#.#) stacked behind the active project leaks
# packages (Piccolo via the global env, even when the manifest carries no
# weakdep) and poisons the configuration under test. The deployment reality —
# a consumer's project environment — has a clean load path by construction.
push!(empty!(LOAD_PATH), "@", "@stdlib")

using Pkg
using UUIDs

const PICCOLO_UUID = UUID("c4671d76-df94-11ed-2057-43d4fd632fad")
const PYTHONCALL_UUID = UUID("6099a3de-0909-46bc-b1f4-468b9a2dfc0d")

# The repo this script belongs to (default: the checkout it lives in).
const REPO = abspath(get(ARGS, 2, joinpath(@__DIR__, "..", "..")))

const results = String[]
global ok = true

function check(cond::Bool, msg::AbstractString)
    push!(results, string(cond ? "  ✓ " : "  ✗ ", msg))
    cond || (global ok = false)
    return cond
end

# The names the BASE package must export (the soc contract + the translation
# data contract + the readout conversion + the twin core) — every
# configuration, no triggers needed. `pulse_to_envelopes` is a duck-typed stub
# in base: defined everywhere, dispatches to the Piccolo extension's typed
# method when Piccolo is loaded.
const BASE_SURFACE = [
    # the soc contract
    :AbstractSoc, :execute!, :load_envelope!, :play_program!, :acquire,
    :dac_rate, :adc_rate,
    # the channel map (device policy)
    :QickChannelMap, :QickGenChannel,
    # the translation data contract + the duck-typed verb
    :QickProgram, :pulse_to_envelopes,
    # readout conversion
    :Measurement, :iq_to_measurements,
    # twin core: drift
    :DriftProcess, :OrnsteinUhlenbeck, :Ramp, :RandomTelegraph, :JumpSchedule,
    :DriftPlan, :apply, :step!,
    # twin core: records
    :TwinRecord, :RecordError, :load_record,
    # twin core: the truth/belief contract
    :DigitalTwin, :instantiate, :believed, :advance!, :calibrate!,
]

# Types DEFINED by the two package extensions — reachable through
# `Base.get_extension` exactly when the trigger is loaded.
const PICCOLO_EXT_TYPES = [:MockSoc, :TwinSoc]
const PYTHONCALL_EXT_TYPES = [:StrumentoSoc]

"""Build the scratch environment for `mode`: dev the repo, add the runner deps
the testitems need, and (for the trigger modes) add the one trigger package."""
function build_env(envdir::String, mode::String)
    mkpath(envdir)
    Pkg.activate(envdir)
    Pkg.develop(path = REPO)
    # Testitem runner deps + the packages the base twin/records testitems use.
    Pkg.add(["TestItemRunner", "TestItems", "StableRNGs", "Statistics"])
    mode == "piccolo" && Pkg.add("Piccolo")
    mode == "pythoncall" && Pkg.add("PythonCall")
    Pkg.instantiate()
    return envdir
end

"""Assert manifest-level trigger presence according to `mode`."""
function check_manifest(mode::String)
    deps = Pkg.dependencies()
    has_piccolo = haskey(deps, PICCOLO_UUID)
    has_pythoncall = haskey(deps, PYTHONCALL_UUID)
    if mode == "base"
        check(!has_piccolo, "manifest carries no Piccolo (weakdep, not installed)")
        check(!has_pythoncall, "manifest carries no PythonCall (weakdep, not installed)")
    elseif mode == "piccolo"
        check(has_piccolo, "manifest carries Piccolo (the trigger)")
        check(!has_pythoncall, "manifest carries no PythonCall")
    elseif mode == "pythoncall"
        check(has_pythoncall, "manifest carries PythonCall (the trigger)")
        check(!has_piccolo, "manifest carries no Piccolo")
    end
    return deps
end

"""Load Strumento (plus the mode's trigger, loaded FIRST so the extension
attaches under it) into Main. The actual checks run through
`Base.invokelatest` — the packages are loaded in a newer world than this
script's frames."""
function load_packages(mode::String)
    if mode == "piccolo"
        Base.eval(Main, :(using Piccolo))
    elseif mode == "pythoncall"
        Base.eval(Main, :(using PythonCall))
    end
    Base.eval(Main, :(using Strumento))
    Base.eval(Main, :(using TestItemRunner))
    Base.eval(Main, :(using Test))
    return nothing
end

"""The post-load check phase — invoked via `Base.invokelatest` so it compiles
in a world that can see the loaded packages."""
function check_phase(mode::String)
    M = Main.Strumento
    for name in BASE_SURFACE
        check(isdefined(M, name), "base surface: $name defined on Strumento")
    end

    piccolo_ext = Base.get_extension(M, :StrumentoPiccoloExt)
    pythoncall_ext = Base.get_extension(M, :StrumentoPythonCallExt)

    if mode == "base"
        for name in PICCOLO_EXT_TYPES
            check(!isdefined(M, name), "no Piccolo extension type: $name absent from Strumento")
        end
        for name in PYTHONCALL_EXT_TYPES
            check(!isdefined(M, name), "no PythonCall extension type: $name absent from Strumento")
        end
        check(piccolo_ext === nothing, "StrumentoPiccoloExt not loaded")
        check(pythoncall_ext === nothing, "StrumentoPythonCallExt not loaded")
        # The duck-typed translation verb stubs actionably for anything that
        # is not a Piccolo AbstractPulse (in particular: without Piccolo, for
        # everything).
        stub_errors = try
            M.pulse_to_envelopes("duck pulse", nothing, 0.0, [0])
            false
        catch e
            e isa ErrorException && occursin("Piccolo extension", e.msg)
        end
        check(stub_errors,
              "pulse_to_envelopes stub errors actionably (no typed method loaded)")
        stub_seam = try
            M.pulse_duration("duck pulse")
            false
        catch e
            e isa ErrorException && occursin("Piccolo extension", e.msg)
        end
        check(stub_seam, "pulse-sampling seam errors actionably (no typed method loaded)")
    elseif mode == "piccolo"
        check(piccolo_ext !== nothing, "StrumentoPiccoloExt loaded (extension attached)")
        check(pythoncall_ext === nothing, "StrumentoPythonCallExt not loaded")
        for name in PICCOLO_EXT_TYPES
            check(isdefined(piccolo_ext, name), "Piccolo extension type: $name reachable via get_extension")
        end
        for name in PYTHONCALL_EXT_TYPES
            check(!isdefined(M, name), "no PythonCall extension type: $name absent from Strumento")
        end
        P = Main.Piccolo
        check(piccolo_ext.MockSoc <: M.AbstractSoc, "the mock soc is an AbstractSoc")
        # the base-declared duck-typed surface gained its Piccolo methods
        check(hasmethod(M.pulse_to_envelopes,
                        Tuple{P.AbstractPulse, M.QickChannelMap, Float64, Vector{Int}}),
              "pulse_to_envelopes has its AbstractPulse typed method")
        check(hasmethod(M.pulse_duration, Tuple{P.AbstractPulse}),
              "pulse-sampling seam has its duration method")
        check(hasmethod(M.sample_controls, Tuple{P.AbstractPulse, Vector{Float64}}),
              "pulse-sampling seam has its sample method")
    elseif mode == "pythoncall"
        check(pythoncall_ext !== nothing, "StrumentoPythonCallExt loaded (extension attached)")
        check(piccolo_ext === nothing, "StrumentoPiccoloExt not loaded")
        for name in PYTHONCALL_EXT_TYPES
            check(isdefined(pythoncall_ext, name), "PythonCall extension type: $name reachable via get_extension")
        end
        check(pythoncall_ext.StrumentoSoc <: M.AbstractSoc,
              "the delegation soc is an AbstractSoc")
        for name in PICCOLO_EXT_TYPES
            check(!isdefined(M, name), "no Piccolo extension type: $name absent from Strumento")
        end
        # the delegation verb's method is on the base generic function
        check(hasmethod(M.execute!, Tuple{pythoncall_ext.StrumentoSoc, Any, M.QickChannelMap,
                                          Vector{Int}}),
              "execute! has its delegation method (duck-typed pulse)")
    end

    # Run the package's testitems — all of them; the extension testitems skip
    # cleanly where their trigger is absent. TestItemRunner's root test set
    # THROWS when the run is not green, so catch, report, and mark. Counts:
    # the finished root set carries its descendants in the cumulative fields.
    ok_items, msg = try
        ts = Main.TestItemRunner.run_tests(REPO)
        c = Main.Test.get_test_counts(ts)
        passed = c.passes + c.cumulative_passes
        failed = c.fails + c.cumulative_fails
        errored = c.errors + c.cumulative_errors
        (true, "testitem run green ($passed passed, $failed failed, " *
               "$errored errored)")
    catch e
        (false, "testitem run not green: $(sprint(showerror, e))")
    end
    check(ok_items, msg)
    return nothing
end

function main()
    mode = get(ARGS, 1, "")
    mode in ("base", "piccolo", "pythoncall") ||
        error("usage: load_config_check.jl base|piccolo|pythoncall [<repo> [<envdir>]]")
    envdir = abspath(get(ARGS, 3, "/tmp/strumento-config-$mode"))

    println("[$mode] repo: $REPO")
    println("[$mode] env:  $envdir")
    build_env(envdir, mode)
    check_manifest(mode)
    load_packages(mode)
    Base.invokelatest(check_phase, mode)

    println()
    println("[$mode] configuration check:")
    for line in results
        println(line)
    end
    println("[$mode] $(ok ? "HOLDS" : "VIOLATED")")
    return ok ? 0 : 1
end

exit(main())