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
