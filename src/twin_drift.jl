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

# ─── Spec-floor extensions (issue #15) ───────────────────────────────────────
# The exact-Gaussian OU transition vs Euler-stepped wrongness, replay across
# fresh processes, and golden pins captured from the absorbed implementation
# (Distributions 0.25.131, StableRNGs 1.0.4, Julia 1.12.5).

@testitem "OrnsteinUhlenbeck — one step is the exact Gaussian transition" begin
    using Strumento
    using StableRNGs
    using Statistics
    # One step from a fixed x₀: the transition is Gaussian with
    # mean μ + (x₀-μ)e^{-θdt} and std σ√(1-e^{-2θdt}).
    ou = OrnsteinUhlenbeck(theta = 0.5, sigma = 0.02, mu = 100.0)
    steps = [step!(ou, 110.0, 2.0, StableRNG(seed)) for seed in 1:20000]
    @test mean(steps) ≈ 100.0 + 10.0 * exp(-1.0) rtol = 1e-3
    @test std(steps) ≈ 0.02 * sqrt(1 - exp(-2.0)) rtol = 0.01
end

@testitem "OrnsteinUhlenbeck — exact transition vs Euler at coarse dt (stationary std)" begin
    using Strumento
    using StableRNGs
    using Statistics
    # θdt = 1.5: the exact transition keeps the stationary std at σ for ANY dt.
    # An Euler step on the SDE matched to the same stationary law (σ_E = σ√(2θ))
    # doubles it: Var_Euler = σ_E²dt/(1-(1-θdt)²) = 4σ² at θdt = 1.5.
    theta, sigma, dt, n = 1.0, 0.1, 1.5, 6000
    ou = OrnsteinUhlenbeck(theta = theta, sigma = sigma, mu = 0.0)
    exact = let x = 0.0, acc = Float64[], rng = StableRNG(1234)
        for _ in 1:n
            x = step!(ou, x, dt, rng); push!(acc, x)
        end
        acc
    end
    euler = let x = 0.0, acc = Float64[], rng = StableRNG(1234), sE = sigma * sqrt(2theta)
        for _ in 1:n
            x = x - theta * x * dt + sE * sqrt(dt) * randn(rng); push!(acc, x)
        end
        acc
    end
    @test std(exact[1001:end]) ≈ sigma rtol = 0.1          # exact stays at σ
    @test std(euler[1001:end]) ≈ 2 * sigma rtol = 0.1      # Euler: 2σ — discretization bias
    @test std(euler[1001:end]) > 1.6 * std(exact[1001:end])
end

@testitem "OrnsteinUhlenbeck — lag-1 autocorrelation exp(-θdt): exact vs Euler" begin
    using Strumento
    using StableRNGs
    using Statistics
    # The exact transition has lag-k correlation e^{-θkdt} at ANY dt; the Euler
    # AR(1) has (1-θdt)^k. At θdt = 0.5 those are 0.607 vs 0.5 — distinguishable.
    theta, sigma, dt, n = 1.0, 0.1, 0.5, 20000
    ou = OrnsteinUhlenbeck(theta = theta, sigma = sigma, mu = 0.0)
    autocorr(v, lag) = (vv = v .- mean(v); sum(vv[1:end-lag] .* vv[1+lag:end]) / sum(vv .^ 2))
    exact = let x = 0.0, acc = Float64[], rng = StableRNG(42)
        for _ in 1:n
            x = step!(ou, x, dt, rng); push!(acc, x)
        end
        acc
    end
    euler = let x = 0.0, acc = Float64[], rng = StableRNG(42), sE = sigma * sqrt(2theta)
        for _ in 1:n
            x = x - theta * x * dt + sE * sqrt(dt) * randn(rng); push!(acc, x)
        end
        acc
    end
    @test autocorr(exact[1001:end], 1) ≈ exp(-theta * dt) atol = 0.015
    @test autocorr(euler[1001:end], 1) ≈ 1 - theta * dt atol = 0.015
    @test abs(autocorr(exact[1001:end], 1) - autocorr(euler[1001:end], 1)) > 0.05
end

@testitem "OrnsteinUhlenbeck — replay across fresh processes (bit-exact)" begin
    using Strumento
    using StableRNGs
    trajectory(seed) = let ou = OrnsteinUhlenbeck(theta = 1.0, sigma = 0.03, mu = 0.0),
                            rng = StableRNG(seed), x = 1.0, acc = Float64[]
        for _ in 1:50
            x = step!(ou, x, 0.05, rng); push!(acc, x)
        end
        acc
    end
    # FRESH process objects each call — replay must not depend on shared state
    @test trajectory(7) == trajectory(7)
    @test trajectory(7) != trajectory(8)
end

@testitem "OrnsteinUhlenbeck — golden pin: seeded trajectory bit-exact" begin
    using Strumento
    using StableRNGs
    # GOLDEN PIN — captured from the absorbed Sosia implementation (issue #15)
    # before any adaptation: θ=1, σ=0.03, μ=0, x₀=1, dt=0.05, StableRNG(7).
    # `==`, no tolerance: a deviation is a behavior change, never noise.
    ou = OrnsteinUhlenbeck(theta = 1.0, sigma = 0.03, mu = 0.0)
    rng = StableRNG(7)
    got = let x = 1.0, acc = Float64[]
        for _ in 1:5
            x = step!(ou, x, 0.05, rng); push!(acc, x)
        end
        acc
    end
    @test got == [0.932471738707425, 0.8941451344605106, 0.8459799475465459,
                  0.7947853076362916, 0.7621492912296226]
end

@testitem "RandomTelegraph — replay across fresh processes (bit-exact)" begin
    using Strumento
    using StableRNGs
    rt_traj(seed) = let rt = RandomTelegraph(gamma_up = 2.0, gamma_down = 2.0, amplitude = 3.0),
                         rng = StableRNG(seed), x = 0.0, acc = Float64[]
        for _ in 1:200
            x = step!(rt, x, 0.05, rng); push!(acc, x)
        end
        acc
    end
    @test rt_traj(99) == rt_traj(99)      # fresh process + fresh rng, same seed
    @test rt_traj(99) != rt_traj(100)     # different seed → different chain
end

@testitem "RandomTelegraph — only the CHANGE in offset moves the parameter" begin
    using Strumento
    using StableRNGs
    # gamma = 0: the chain never flips; the first step applies the +amplitude
    # offset (state starts +1, applied 0), then the value is stationary.
    rt0 = RandomTelegraph(gamma_up = 0.0, gamma_down = 0.0, amplitude = 3.0)
    let x = 0.0, rng = StableRNG(5)
        x = step!(rt0, x, 0.05, rng); @test x == 3.0
        x = step!(rt0, x, 0.05, rng); @test x == 3.0
        x = step!(rt0, x, 0.05, rng); @test x == 3.0
    end
    # gamma → ∞: the chain flips every step; each step moves x by the offset
    # CHANGE (−3, then +6, then −6, …) — x only ever sits at ±amplitude.
    rtH = RandomTelegraph(gamma_up = 1e9, gamma_down = 1e9, amplitude = 3.0)
    let x = 0.0, rng = StableRNG(5)
        x = step!(rtH, x, 0.05, rng); @test x == -3.0
        x = step!(rtH, x, 0.05, rng); @test x == 3.0
        x = step!(rtH, x, 0.05, rng); @test x == -3.0
        x = step!(rtH, x, 0.05, rng); @test x == 3.0
    end
end

@testitem "JumpSchedule — unlisted times pass through; a scheduled time applies" begin
    using Strumento
    using StableRNGs
    js = JumpSchedule(times = [1.0, 3.0], deltas = [1.5, -0.5])
    rng = StableRNG(1)
    @test step!(js, 10.0, 0.5, rng; t = 2.0) == 10.0    # between scheduled times
    @test step!(js, 10.0, 0.5, rng; t = 0.0) == 10.0    # before any
    @test step!(js, 10.0, 0.5, rng; t = 1.0) == 11.5    # at a scheduled time
    @test step!(js, 10.0, 0.5, rng; t = 3.0) == 9.5     # the other scheduled time
end

@testitem "DriftPlan — chains compose additively; unplanned and missing params pass through" begin
    using Strumento
    using StableRNGs
    plan = DriftPlan(:omega => [Ramp(rate = 0.1), Ramp(rate = 0.2)])
    truth = Dict{Symbol, Float64}(:omega => 4.0, :delta => 0.2)
    out = apply(plan, truth, 1.0, StableRNG(1); t = 0.0)
    @test out[:omega] == 4.3                 # both processes applied, additively
    @test out[:delta] == 0.2                 # unplanned parameter untouched
    @test truth[:omega] == 4.0               # pure function: input untouched
    # a plan naming a parameter the truth lacks is skipped, not an error
    plan2 = DriftPlan(:missing => [Ramp(rate = 1.0)])
    out2 = apply(plan2, Dict{Symbol, Float64}(:omega => 4.0), 1.0, StableRNG(1))
    @test out2 == Dict{Symbol, Float64}(:omega => 4.0)
    # the empty plan is the identity
    @test apply(DriftPlan(), Dict{Symbol, Float64}(:a => 1.0), 1.0, StableRNG(1)) ==
          Dict{Symbol, Float64}(:a => 1.0)
end
