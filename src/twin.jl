# The twin contract — truth (drifting) / belief (calibrated) / record (provenance).
# Drift moves truth only; calibration moves belief only (spec-20260803-043304).
#
# Absorbed from harmoniqs/Sosia.jl (spec-20260803-043304-digital-twins-sosia),
# issue #15 — ported tests first (RED), implementation follows.

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
