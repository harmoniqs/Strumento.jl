# Drift processes — the stochastic dynamics of a twin's truth.
#
# Every process is a pure function of (current value, dt, rng): replayability
# by construction (spec-20260803-043304). OU uses the exact Gaussian
# transition — no Euler time-step bias over long drifts.
#
# Absorbed from harmoniqs/Sosia.jl (spec-20260803-043304-digital-twins-sosia),
# issue #15 — ported tests first (RED), implementation follows.

@testitem "OrnsteinUhlenbeck — mean reversion and stationary statistics" begin
    using Strumento
    using StableRNGs
    using Statistics
    ou = OrnsteinUhlenbeck(theta = 0.5, sigma = 0.02, mu = 100.0)

    # starting exactly at mu: the process stays centered on mu
    rng = StableRNG(0xC0FFEE)
    xs = Float64[100.0]
    x = 100.0
    for _ in 1:2000
        x = step!(ou, x, 0.1, rng)
        push!(xs, x)
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
    x = 10.0
    for _ in 1:4
        x = step!(ramp, x, 2.0, rng)
    end
    @test x == 10.0 + 0.5 * 8.0
end

@testitem "RandomTelegraph — two-state CTMC (the TLS signature)" begin
    using Strumento
    using StableRNGs
    using Statistics
    rt = RandomTelegraph(gamma_up = 2.0, gamma_down = 2.0, amplitude = 3.0)
    rng = StableRNG(99)
    x, n = 0.0, 5000
    xs = Float64[]
    for _ in 1:n
        x = step!(rt, x, 0.05, rng)
        push!(xs, x)
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
