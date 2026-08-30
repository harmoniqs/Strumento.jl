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
#                                                         contract + twin surface present;
#                                                         extension surfaces absent; the
#                                                         base testitems pass
#   piccolo     Piccolo ONLY (no PythonCall)               the mock/translation surface
#                                                         appears; the delegation soc does
#                                                         not; the golden pin passes
#   pythoncall  PythonCall ONLY (no Piccolo)               the delegation soc appears; the
#                                                         mock/translation surface does not
#
# Exit code 0 = the configuration holds; nonzero otherwise (each violated
# assertion is printed).

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

# The names the BASE package must export (the soc contract + the readout
# conversion + the twin core) — every configuration, no triggers needed.
const BASE_SURFACE = [
    # the soc contract
    :AbstractSoc, :execute!, :load_envelope!, :play_program!, :acquire,
    :dac_rate, :adc_rate,
    # the channel map (device policy)
    :QickChannelMap, :QickGenChannel,
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

# Names owned by the two package extensions — present exactly when the
# extension is loaded.
const PICCOLO_EXT_SURFACE = [:MockSoc, :pulse_to_envelopes, :QickProgram, :populations]
const PYTHONCALL_EXT_SURFACE = [:StrumentoSoc]

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

"""Load Strumento (plus the mode's trigger, loaded FIRST so the extension's
exports are captured by `using Strumento`) into Main. The actual checks run
through `Base.invokelatest` — the packages are loaded in a newer world than
this script's frames."""
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
        for name in PICCOLO_EXT_SURFACE
            check(!isdefined(M, name), "no Piccolo extension surface: $name absent")
        end
        for name in PYTHONCALL_EXT_SURFACE
            check(!isdefined(M, name), "no PythonCall extension surface: $name absent")
        end
        check(piccolo_ext === nothing, "StrumentoPiccoloExt not loaded")
        check(pythoncall_ext === nothing, "StrumentoPythonCallExt not loaded")
    elseif mode == "piccolo"
        for name in PICCOLO_EXT_SURFACE
            check(isdefined(M, name), "Piccolo extension surface: $name defined on Strumento")
        end
        for name in PYTHONCALL_EXT_SURFACE
            check(!isdefined(M, name), "no PythonCall extension surface: $name absent")
        end
        check(piccolo_ext !== nothing, "StrumentoPiccoloExt loaded")
        check(pythoncall_ext === nothing, "StrumentoPythonCallExt not loaded")
        # bare-name visibility: the extension's exports are visible to
        # `using Strumento` when the trigger loaded first (zero surface loss).
        check(isdefined(Main, :MockSoc) && isdefined(Main, :pulse_to_envelopes),
              "extension exports visible bare after `using Piccolo; using Strumento`")
    elseif mode == "pythoncall"
        for name in PYTHONCALL_EXT_SURFACE
            check(isdefined(M, name), "PythonCall extension surface: $name defined on Strumento")
        end
        for name in PICCOLO_EXT_SURFACE
            check(!isdefined(M, name), "no Piccolo extension surface: $name absent")
        end
        check(pythoncall_ext !== nothing, "StrumentoPythonCallExt loaded")
        check(piccolo_ext === nothing, "StrumentoPiccoloExt not loaded")
        check(isdefined(Main, :StrumentoSoc),
              "delegation soc visible bare after `using PythonCall; using Strumento`")
    end

    # Run the package's testitems — all of them; the extension testitems skip
    # cleanly where their trigger is absent. TestItemRunner's root test set
    # THROWS when the run is not green, so catch, report, and mark.
    ok_items, msg = try
        ts = Main.TestItemRunner.run_tests(REPO)
        c = Main.Test.get_test_counts(ts)
        (true, "testitem run green ($(c.passes) passed, $(c.fails) failed, " *
               "$(c.errors) errored)")
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