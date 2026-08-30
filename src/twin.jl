# The twin contract — truth (drifting) / belief (calibrated) / record (provenance).
# Drift moves truth only; calibration moves belief only (spec-20260803-043304).
#
# Absorbed from harmoniqs/Sosia.jl (spec-20260803-043304-digital-twins-sosia),
# issue #15 — ported faithfully; naming carried as-is.

using StableRNGs: StableRNG

export DigitalTwin, instantiate, believed, advance!, calibrate!

"""
    DigitalTwin

A device-shaped object the Loop runs against exactly as hardware:

- `record` — the vault twin record (parameters, noise, drift priors, provenance)
- `truth` — hidden parameters, evolving under a `DriftPlan`
- `belief` — what the calibration store currently knows (moves only via `calibrate!`)
- `rng` — the seeded replayable source of all stochasticity
- `t` — twin time (days by convention)
"""
mutable struct DigitalTwin
    record::TwinRecord
    truth::Dict{Symbol, Float64}
    belief::Dict{String, Any}
    plan::DriftPlan
    rng::StableRNG
    t::Float64
end

"""
    instantiate(record_path; drift, seed) -> DigitalTwin

Build a twin from a vault record. Truth initializes at the record parameters
(belief and truth agree — until drift).
"""
function instantiate(record_path::AbstractString; drift::DriftPlan, seed::Integer)
    record = load_record(record_path)
    truth = Dict{Symbol, Float64}(
        Symbol(k) => float(v) for (k, v) in record.parameters if v isa Real
    )
    belief = deepcopy(record.parameters)
    return DigitalTwin(record, truth, belief, drift, StableRNG(seed), 0.0)
end

"""The calibration store's current beliefs (record parameters + calibrations)."""
believed(twin::DigitalTwin) = twin.belief

"""Evolve the twin's truth by `dt` under its drift plan. Belief untouched."""
function advance!(twin::DigitalTwin, dt::Real)
    twin.truth = apply(twin.plan, twin.truth, dt, twin.rng; t = twin.t)
    twin.t += dt
    return twin
end

"""A calibration write-back: update belief (never truth)."""
function calibrate!(twin::DigitalTwin, updates::Dict)
    merge!(twin.belief, updates)
    return twin
end

@testitem "instantiate — truth from record, belief = record, seeded" begin
    using Strumento
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    plan = DriftPlan(
        :chi_kHz => [OrnsteinUhlenbeck(theta = 0.07, sigma = 3.0, mu = -298.4)],
    )
    twin = instantiate(fixture; drift = plan, seed = 0xC0FFEE)

    @test twin.record.id == "synthetic-bosonic"
    @test believed(twin)["chi_kHz"] == -298.4
    # truth starts at the record value (belief and truth agree before drift)
    @test twin.truth[:chi_kHz] == -298.4
    @test twin.t == 0.0
end

@testitem "advance! — drift moves truth only; calibrate! moves belief only" begin
    using Strumento
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    plan = DriftPlan(
        :chi_kHz => [Ramp(rate = -0.5)],
    )
    twin = instantiate(fixture; drift = plan, seed = 1)
    chi0 = twin.truth[:chi_kHz]

    advance!(twin, 10.0)

    @test twin.t == 10.0
    @test twin.truth[:chi_kHz] == chi0 - 5.0
    # belief untouched by drift — calibration hasn't happened
    @test believed(twin)["chi_kHz"] == -298.4

    # a calibration write updates belief, never truth
    calibrate!(twin, Dict("chi_kHz" => twin.truth[:chi_kHz]))
    @test believed(twin)["chi_kHz"] == chi0 - 5.0
    @test twin.truth[:chi_kHz] == chi0 - 5.0
end

@testitem "replay — seeded twins drift identically" begin
    using Strumento
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    plan = DriftPlan(
        :chi_kHz => [OrnsteinUhlenbeck(theta = 0.1, sigma = 1.0, mu = -298.4)],
    )
    t1 = instantiate(fixture; drift = plan, seed = 7)
    t2 = instantiate(fixture; drift = plan, seed = 7)
    for _ in 1:20
        advance!(t1, 1.0)
        advance!(t2, 1.0)
    end
    @test t1.truth == t2.truth
end

# ─── Spec-floor extensions (issue #15) ───────────────────────────────────────
# The contract's core invariants at full strength: truth/belief typing,
# t-plumbing for scheduled jumps, seed divergence, and golden pins captured
# from the absorbed implementation (Distributions 0.25.131, StableRNGs 1.0.4,
# Julia 1.12.5).

@testitem "instantiate — truth is the Real parameters (as Float64); belief is the whole record" begin
    using Strumento
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    twin = instantiate(fixture; drift = DriftPlan(), seed = 1)
    @test length(twin.truth) == 7                    # every bosonic parameter is numeric
    @test twin.truth[:N_fock] === 12.0               # Ints enter truth as Float64
    @test twin.truth[:chi_kHz] === -298.4
    @test length(believed(twin)) == 7
    @test believed(twin)["N_fock"] == 12             # belief keeps the record's Int as-is

    # a string parameter (the atoms family's species) lives in belief, never truth
    atoms = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "atoms.md")
    twinA = instantiate(atoms; drift = DriftPlan(), seed = 1)
    @test haskey(twinA.truth, :omega_max_MHz)        # Real → truth
    @test !haskey(twinA.truth, :species)             # String → belief only
    @test length(twinA.truth) == 8
    @test believed(twinA)["species"] == "Rb87"
    @test length(believed(twinA)) == 9
end

@testitem "advance! — returns the twin, accumulates t, and leaves belief alone" begin
    using Strumento
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    twin = instantiate(fixture; drift = DriftPlan(), seed = 1)
    @test advance!(twin, 0.5) === twin
    @test twin.t == 0.5
    advance!(twin, 0.25)
    @test twin.t == 0.75
    # the empty plan drifts nothing — truth and belief both unchanged
    @test twin.truth[:chi_kHz] == -298.4
    @test believed(twin)["chi_kHz"] == -298.4
end

@testitem "advance! — JumpSchedule fires at twin time t (the t-plumbing)" begin
    using Strumento
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    plan = DriftPlan(:chi_kHz => [JumpSchedule(times = [2.0], deltas = [1.0])])
    twin = instantiate(fixture; drift = plan, seed = 1)
    seq = Float64[]
    for _ in 1:3
        advance!(twin, 1.0)
        push!(seq, twin.truth[:chi_kHz])
    end
    # steps begin at t = 0, 1, 2 — the jump lands exactly on the step from t = 2
    @test seq == [-298.4, -298.4, -297.4]
end

@testitem "calibrate! — merges into belief (new keys included); truth never moves" begin
    using Strumento
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    twin = instantiate(fixture; drift = DriftPlan(), seed = 1)
    @test calibrate!(twin, Dict("chi_kHz" => -250.0)) === twin
    @test believed(twin)["chi_kHz"] == -250.0        # an update overwrites
    @test twin.truth[:chi_kHz] == -298.4             # ...and never touches truth
    calibrate!(twin, Dict("K_c_kHz" => -10.0))       # a second write merges
    @test believed(twin)["chi_kHz"] == -250.0
    @test believed(twin)["K_c_kHz"] == -10.0
    calibrate!(twin, Dict("omega_new_GHz" => 5.0))   # a NEW key enters belief
    @test believed(twin)["omega_new_GHz"] == 5.0
    @test twin.truth[:chi_kHz] == -298.4             # truth still pristine
end

@testitem "replay — different seeds drift apart; a rerun reproduces exactly" begin
    using Strumento
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    plan = DriftPlan(
        :chi_kHz => [OrnsteinUhlenbeck(theta = 0.1, sigma = 1.0, mu = -298.4)],
    )
    drift5(seed) = let twin = instantiate(fixture; drift = plan, seed = seed)
        for _ in 1:5
            advance!(twin, 1.0)
        end
        copy(twin.truth)
    end
    @test drift5(7) != drift5(8)                     # different seeds → different truths
    @test drift5(7) == drift5(7)                     # same seed → identical, always
end

@testitem "golden pin — a seeded twin trajectory is bit-exact" begin
    using Strumento
    # GOLDEN PIN — captured from the absorbed Sosia implementation (issue #15)
    # before any adaptation: the bosonic fixture, plan OU(θ=0.1, σ=1.0, μ=-298.4)
    # on :chi_kHz, seed 7, five advance!(twin, 1.0). `==`, no tolerance.
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    plan = DriftPlan(
        :chi_kHz => [OrnsteinUhlenbeck(theta = 0.1, sigma = 1.0, mu = -298.4)],
    )
    twin = instantiate(fixture; drift = plan, seed = 7)
    got = Float64[]
    for _ in 1:5
        advance!(twin, 1.0)
        push!(got, twin.truth[:chi_kHz])
    end
    @test got == [-299.26295263440176, -298.8518674225128, -299.0185224752866,
                  -299.41675747150697, -299.0381663034378]
    # the same twin rerun from the same seed reproduces the pin (a calibration
    # failure must reproduce exactly)
    twin2 = instantiate(fixture; drift = plan, seed = 7)
    got2 = Float64[]
    for _ in 1:5
        advance!(twin2, 1.0)
        push!(got2, twin2.truth[:chi_kHz])
    end
    @test got2 == got
end
