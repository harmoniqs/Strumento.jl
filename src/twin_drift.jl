# Drift processes — the stochastic dynamics of a twin's truth.
#
# Every process is a pure function of (current value, dt, rng): replayability
# by construction (spec-20260803-043304). OU uses the exact Gaussian
# transition — no Euler time-step bias over long drifts.
#
# Absorbed from harmoniqs/Sosia.jl (spec-20260803-043304-digital-twins-sosia),
# issue #15 — ported faithfully; naming carried as-is.

using Distributions: Normal
using Random: AbstractRNG

export DriftProcess, OrnsteinUhlenbeck, step!

"""
    DriftProcess

Abstract supertype for parameter drift processes. Contract:
`step!(proc, x::Real, dt::Real, rng::AbstractRNG) -> new_x`.
"""
abstract type DriftProcess end

"""
    OrnsteinUhlenbeck(; theta, sigma, mu)

Mean-reverting diffusion: `dx = -theta (x - mu) dt + sigma dW`, stepped with
the exact Gaussian transition — stationary mean `mu`, stationary std `sigma`,
correlation time `1/theta`.
"""
struct OrnsteinUhlenbeck{T<:Real} <: DriftProcess
    theta::T
    sigma::T
    mu::T
end

OrnsteinUhlenbeck(; theta, sigma, mu) =
    OrnsteinUhlenbeck(promote(float(theta), float(sigma), float(mu))...)

function step!(ou::OrnsteinUhlenbeck, x::Real, dt::Real, rng::AbstractRNG; t::Real = 0.0)
    decay = exp(-ou.theta * dt)
    stationary_std = ou.sigma * sqrt(1 - decay^2)
    return ou.mu + (x - ou.mu) * decay + stationary_std * rand(rng, Normal())
end

export Ramp, RandomTelegraph, JumpSchedule, DriftPlan, apply

"""
    Ramp(; rate)

Deterministic linear aging: `x += rate * dt`. Models thermal soak, component
aging — any monotone drift between calibrations.
"""
struct Ramp{T<:Real} <: DriftProcess
    rate::T
end

Ramp(; rate) = Ramp(float(rate))
step!(r::Ramp, x::Real, dt::Real, ::AbstractRNG; t::Real = 0.0) = x + r.rate * dt

"""
    RandomTelegraph(; gamma_up, gamma_down, amplitude)

Two-state continuous-time Markov chain — the TLS (two-level-system) signature
in real transmons: the parameter jumps by `±amplitude` and dwells, with
per-unit-time flip rates `gamma_up` (offset − → +) and `gamma_down` (+ → −).
The returned value is `x + s*amplitude` with `s ∈ {-1, +1}` the chain state.
"""
mutable struct RandomTelegraph{T<:Real} <: DriftProcess
    gamma_up::T
    gamma_down::T
    amplitude::T
    state::Int     # current chain state ∈ {-1, +1}
    applied::Int   # the offset currently included in the parameter ∈ {-1, 0, 1}
end

RandomTelegraph(; gamma_up, gamma_down, amplitude) =
    RandomTelegraph(promote(float(gamma_up), float(gamma_down), float(amplitude))..., 1, 0)

function step!(rt::RandomTelegraph, x::Real, dt::Real, rng::AbstractRNG; t::Real = 0.0)
    rate = rt.state == 1 ? rt.gamma_down : rt.gamma_up
    if rand(rng) < 1 - exp(-rate * dt)
        rt.state = -rt.state
    end
    # composable: only the CHANGE in offset moves the parameter
    delta = (rt.state - rt.applied) * rt.amplitude
    rt.applied = rt.state
    return x + delta
end

"""
    JumpSchedule(; times, deltas)

Scheduled additive jumps (relocks, register reloads): `deltas[i]` applies at
`t == times[i]`. `step!` requires the keyword `t` (current time).
"""
struct JumpSchedule{T<:Real,S<:Real} <: DriftProcess
    times::Vector{T}
    deltas::Vector{S}
end

JumpSchedule(; times, deltas) = JumpSchedule(float.(times), float.(deltas))

function step!(js::JumpSchedule, x::Real, dt::Real, ::AbstractRNG; t::Real)
    i = findfirst(==(float(t)), js.times)
    return i === nothing ? x : x + js.deltas[i]
end

"""
    DriftPlan(pairs...)

Per-parameter drift composition: `DriftPlan(:omega => [proc1, proc2], ...)`.
`apply(plan, truth, dt, rng; t)` returns a NEW truth dict with each process
applied additively to its parameter; unspecified parameters pass through.
"""
struct DriftPlan
    procs::Dict{Symbol, Vector{DriftProcess}}
end

function DriftPlan(pairs::Pair{Symbol}...)
    procs = Dict{Symbol, Vector{DriftProcess}}()
    for (k, v) in pairs
        procs[k] = DriftProcess[p for p in v]
    end
    return DriftPlan(procs)
end

function apply(plan::DriftPlan, truth::Dict{Symbol, Float64}, dt::Real, rng::AbstractRNG; t::Real = 0.0)
    out = copy(truth)
    for (param, procs) in plan.procs
        haskey(out, param) || continue
        for proc in procs
            out[param] = step!(proc, out[param], dt, rng; t = t)
        end
    end
    return out
end

@testitem "OrnsteinUhlenbeck — mean reversion and stationary statistics" begin
    using Strumento
    using StableRNGs
    using Statistics
    ou = OrnsteinUhlenbeck(theta = 0.5, sigma = 0.02, mu = 100.0)

    # starting exactly at mu: the process stays centered on mu
    # (the `let` adapts the loop to testitem top-level scope: same values,
    #  same semantics as the ported Sosia loop)
    rng = StableRNG(0xC0FFEE)
    xs = Float64[100.0]
    let x = 100.0
        for _ in 1:2000
            x = step!(ou, x, 0.1, rng)
            push!(xs, x)
        end
    end
    @test mean(xs) ≈ 100.0 atol = 0.005
    @test std(xs) ≈ 0.02 rtol = 0.25

    # starting far from mu: the ensemble mean reverts toward mu
    ensemble_mean = mean(step!(ou, 110.0, 2.0, StableRNG(seed)) for seed in 1:2000)
    expected = 100.0 + 10.0 * exp(-0.5 * 2.0)
    @test ensemble_mean ≈ expected rtol = 0.05
end

@testitem "replay — identical seeds produce bit-identical trajectories" begin
    using Strumento
    using StableRNGs
    ou = OrnsteinUhlenbeck(theta = 1.0, sigma = 0.03, mu = 0.0)
    a, b = StableRNG(7), StableRNG(7)
    xa = accumulate((x, _) -> step!(ou, x, 0.05, a), 1:50; init = 1.0)
    xb = accumulate((x, _) -> step!(ou, x, 0.05, b), 1:50; init = 1.0)
    @test xa == xb
end

@testitem "Ramp — deterministic linear aging" begin
    using Strumento
    using StableRNGs
    ramp = Ramp(rate = 0.5)
    rng = StableRNG(1)
    let x = 10.0
        for _ in 1:4
            x = step!(ramp, x, 2.0, rng)
        end
        @test x == 10.0 + 0.5 * 8.0
    end
end

@testitem "RandomTelegraph — two-state CTMC (the TLS signature)" begin
    using Strumento
    using StableRNGs
    using Statistics
    rt = RandomTelegraph(gamma_up = 2.0, gamma_down = 2.0, amplitude = 3.0)
    rng = StableRNG(99)
    n = 5000
    xs = let x = 0.0
        acc = Float64[]
        for _ in 1:n
            x = step!(rt, x, 0.05, rng)
            push!(acc, x)
        end
        acc
    end
    # values only ever at the telegraph levels (within exact float arithmetic)
    @test all(v -> v ∈ (-3.0, 0.0, 3.0) || isapprox(v, 3.0) || isapprox(v, -3.0) || isapprox(v, 0.0), xs)
    # symmetric rates → roughly half the time in each state
    frac_up = mean(>(1.5), xs)
    @test frac_up ≈ 0.5 atol = 0.1
    # it actually jumps (not stuck at zero)
    @test frac_up > 0.2
end

@testitem "JumpSchedule — deltas applied at scheduled times" begin
    using Strumento
    using StableRNGs
    js = JumpSchedule(times = [1.0, 3.0], deltas = [1.5, -0.5])
    rng = StableRNG(1)
    @test step!(js, 10.0, 0.5, rng; t = 0.0) == 10.0
    @test step!(js, 10.0, 0.5, rng; t = 1.0) == 11.5
    @test step!(js, 11.5, 0.5, rng; t = 3.0) == 11.0
end

@testitem "DriftPlan — per-parameter composition, additive application" begin
    using Strumento
    using StableRNGs
    plan = DriftPlan(
        :omega => [Ramp(rate = 0.1)],
        :delta => [OrnsteinUhlenbeck(theta = 0.0, sigma = 0.0, mu = 0.0)],
    )
    truth = Dict{Symbol, Float64}(:omega => 4.0, :delta => 0.2, :other => 9.9)
    rng = StableRNG(1)
    out = apply(plan, truth, 1.0, rng; t = 0.0)
    @test out[:omega] == 4.1
    @test out[:delta] == 0.2
    @test out[:other] == 9.9
    # input dict untouched (pure function)
    @test truth[:omega] == 4.0
end
