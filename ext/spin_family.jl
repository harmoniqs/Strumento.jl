# ──── The spin family (issue #35, M4b-1) ───────────────────────────────────────
# The spin track's family physics: the DOUBLE-DOT CHARGE-STABILITY LANDSCAPE —
# the autotuning's observable (the thing M4b-2's charge-stability map measures).
# Vendored from first principles per the demo cards' physics (the
# exchange/detuning scales, the PSB readout shape): the constant-interaction
# two-electron double dot over the (2,0)/(1,1)/(0,2) charge manifold. ZERO
# demo-repo or vault dependencies — the record carries every scale.

# The v1 detuning LEVER ARM (gate volts -> E/h, MHz). The record carries no
# lever arm (a measured per-device quantity), so the family pins a documented
# unit-symmetric placeholder — the same convention the bosonic family uses for
# its drive bounds. Every structural assertion is a RATIO or a position on
# the gate diagonal, so the placeholder cannot mask a physics change.
const _SPIN_LEVER_ARM_MHZ_PER_V = 1000.0   # 1 GHz/V — the v1 placeholder

# The quasi-static rounding grid: composite trapezoid over +-6 sigma, 480
# intervals. Deterministic (fixed grid, pure Float64 arithmetic) — replayable
# by construction; the Gaussian tail beyond +-6 sigma is < 1e-9.
const _NOISE_GRID_INTERVALS = 480
const _NOISE_GRID_SPAN_SIGMAS = 6.0

# A required truth parameter, named actionably when missing (the bosonic
# family's convention).
function _spin_truth(truth::Dict{Symbol,Float64}, key::Symbol)
    haskey(truth, key) || error(
        "spin family: truth is missing :$key — the charge landscape is built " *
        "from the CURRENT truth (record parameters enter truth at instantiate)")
    return truth[key]
end

"""
    DoubleDotLandscape

The spin family's charge landscape: the two-electron double dot over the
charge manifold |2,0⟩, |1,1⟩, |0,2⟩ at the CURRENT truth's scales. This is the
family seam's DC-side return (`AbstractChargeLandscape`): it names its gates
and maps the gate CONTROLS to the true charge-sensor discrimination
probabilities.

# The charge Hamiltonian (vendored; energies E/h in MHz)

```
        ⎡ -ε   t_c   0  ⎤        ε = detuning: E(1,1) - E(2,0)
H(ε) =  ⎢ t_c   0   t_c ⎥        t_c = inter-dot tunnel matrix element
        ⎣  0   t_c   +ε  ⎦       basis: (2,0), (1,1), (0,2)
```

ε > 0 is the (2,0)/singlet side — the Pauli-spin-blockade setpoint side the
autotuning parks at; ε = 0 is the symmetric honeycomb vertex (the inter-dot
transition line in the gate plane is the DIAGONAL v_L = v_R). Eigenvalues
`0, ±√(ε² + 2t_c²)`; the ground state's left-dot occupancy is a smooth step
from 0 (ε ≪ 0, the (0,2) side) through 1 (ε = 0) to 2 (ε ≫ 0, the (2,0) side).

# The sensor response chain (this type's half of it)

A left-dot charge sensor discriminates two outcomes — sensor-HIGH (the
merged (2,0)-like configuration, n_L = 2) vs sensor-LOW — the thresholded
charge-sensor readout of the spin pack's `PSBReadout` class. The TRUE
probability of the sensor-high outcome is the ground state's mean left-dot
occupancy ⟨n_L⟩/2 in closed form:

```
p_hi(ε) = (A + ½)/(1 + A + B),   A = t_c²/(s-ε)²,  B = t_c²/(s+ε)²,
          s = √(ε² + 2t_c²)
```

(analytically: p_hi(0) = ½ exactly; p_hi(−ε) = 1 − p_hi(ε); p_hi → 0/1 on the
far sides). `sensor_probabilities` returns `[1 − p̃, p̃]` — the record's
2-outcome confusion dimension. The REMAINING chain (the record's PSB readout
confusion remap + binomial shot sampling) is the soc's one response home,
exactly the pulse path's machinery.

# Unit-convention table (record → landscape)

| record field  | record meaning (×2π)      | landscape value (E/h, MHz)      |
|---------------|----------------------------|--------------------------------|
| `J_max_MHz`   | exchange ceiling           | t_c = J_max/2 — the anticrossing gap 2t_c is the declared exchange ceiling (the v1 scale identification: the U-mediated relation J = 4t_c²/U needs the charging energy U the record does not carry) |
| `delta_MHz`   | charge-noise detuning scale| σ_ε = delta — the quasi-static (slow-OU) charge-noise broadening, a Gaussian convolution of the bare step (the ensemble view of the noise the record declares) |

Gates: `"L"` and `"R"` (the plunger pair); the detuning axis is
`ε = α(v_L − v_R)` with the documented lever-arm placeholder α = 1 GHz/V.
"""
struct DoubleDotLandscape <: AbstractChargeLandscape
    t_c::Float64        # inter-dot tunnel matrix element (E/h, MHz) — truth :J_max_MHz / 2
    sigma_eps::Float64   # quasi-static charge-noise detuning scale (E/h, MHz) — truth :delta_MHz
    gates::Vector{String}
end

gate_names(landscape::DoubleDotLandscape) = landscape.gates

# The bare (noise-free) sensor-high probability — the closed form above.
function _sensor_high_bare(eps::Float64, t_c::Float64)
    s = sqrt(eps * eps + 2.0 * t_c * t_c)
    A = t_c * t_c / (s - eps)^2
    B = t_c * t_c / (s + eps)^2
    return (A + 0.5) / (1.0 + A + B)
end

# The quasi-static rounding: Gaussian convolution of the bare step over the
# fixed grid (deterministic; skipped when sigma = 0).
function _sensor_high_rounded(eps::Float64, t_c::Float64, sigma::Float64)
    sigma ≤ 0 && return _sensor_high_bare(eps, t_c)
    lo = -_NOISE_GRID_SPAN_SIGMAS * sigma
    du = 2.0 * _NOISE_GRID_SPAN_SIGMAS * sigma / _NOISE_GRID_INTERVALS
    inv_norm = 1.0 / (sqrt(2.0pi) * sigma)
    total = 0.5 * _sensor_high_bare(eps + lo, t_c) * exp(-lo^2 / (2.0 * sigma^2))
    for k in 1:(_NOISE_GRID_INTERVALS - 1)
        u = lo + k * du
        total += _sensor_high_bare(eps + u, t_c) * exp(-u^2 / (2.0 * sigma^2))
    end
    hi = -lo
    total += 0.5 * _sensor_high_bare(eps + hi, t_c) * exp(-hi^2 / (2.0 * sigma^2))
    return total * du * inv_norm
end

"""
    sensor_probabilities(landscape::DoubleDotLandscape, gates) -> Vector{Float64}

The true charge-sensor discrimination probabilities at the given gate
CONTROLS: the rounded sensor-high step along the detuning axis
`ε = α(v_L − v_R)` (see the struct docstring for the full chain). Unset gates
read 0 V (the control-field default). Returns the 2-vector `[1 − p̃, p̃]` —
the record's PSB confusion dimension; the soc's response machinery (confusion
remap + binomial shots) turns it into the readout blob.
"""
function sensor_probabilities(landscape::DoubleDotLandscape,
                             gates::AbstractDict{<:AbstractString})
    vL = get(gates, landscape.gates[1], 0.0)
    vR = get(gates, landscape.gates[2], 0.0)
    eps = _SPIN_LEVER_ARM_MHZ_PER_V * (Float64(vL) - Float64(vR))
    p_hi = _sensor_high_rounded(eps, landscape.t_c, landscape.sigma_eps)
    return [1.0 - p_hi, p_hi]
end

"""
    spin_landscape_builder(record::TwinRecord) -> (truth) -> DoubleDotLandscape

The spin family factory: a **builder of the TwinSoc family seam**
(`families["spin"] = spin_landscape_builder(twin.record)`), returning a
closure that maps the twin's CURRENT truth to the live charge landscape — a
`TwinSoc` built on it feels drift in every DC readout (the builder is a
function of truth, never a cached landscape). The twin's PULSE path refuses
this family actionably (two control classes, one twin); the DC path
(`set_gate!` + the charge-sensor readout) drives it.
"""
function spin_landscape_builder(record::Strumento.TwinRecord)
    record.family == "spin" || error(
        "spin family: spin_landscape_builder got a $(repr(record.family)) " *
        "record ($(repr(record.id))) — the factory is keyed by the record's " *
        "family field; build it from a spin record")
    return function (truth::Dict{Symbol,Float64})
        J_max = _spin_truth(truth, :J_max_MHz)
        delta = _spin_truth(truth, :delta_MHz)
        J_max > 0 || error(
            "spin family: truth :J_max_MHz must be > 0 (got $J_max) — the " *
            "anticrossing gap 2t_c = J_max is a scale, not a degeneracy")
        delta ≥ 0 || error(
            "spin family: truth :delta_MHz must be ≥ 0 (got $delta) — the " *
            "quasi-static charge-noise scale is a broadening width")
        return DoubleDotLandscape(J_max / 2.0, delta, ["L", "R"])
    end
end

export spin_landscape_builder, DoubleDotLandscape
@testitem "spin family — the landscape factory builds from the fixture's truth (no hand-passed parameters)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using Strumento: DriftPlan, instantiate, load_record
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "spin.md")
        record = load_record(fixture)
        twin = instantiate(fixture; drift = DriftPlan(), seed = 1)

        # the factory is keyed by the record's family field
        @test record.family == "spin"
        builder = ext.spin_landscape_builder(record)
        @test builder isa Function
        landscape = builder(twin.truth)
        @test landscape isa ext.DoubleDotLandscape
        @test landscape isa ext.AbstractChargeLandscape

        # the family's DC gate declaration — the two plunger gates
        @test collect(ext.gate_names(landscape)) == ["L", "R"]

        # the record's PSB-flavor readout confusion rides the response machinery
        # (the twin's 2x2 confusion must match the landscape's outcome count)
        @test length(ext.sensor_probabilities(landscape, Dict("L" => 0.0, "R" => 0.0))) == 2
        rows = record.noise["readout_confusion"]["value"]
        @test length(rows) == 2 && all(r -> length(r) == 2, rows)   # 2x2, list of rows

        # ── wiring errors are actionable ──
        # a non-spin record: the factory is keyed by the record's family
        bosrec = load_record(joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md"))
        err = try
            ext.spin_landscape_builder(bosrec); nothing
        catch e
            e
        end
        @test err isa ErrorException
        msg = sprint(showerror, err)
        @test occursin("family", msg) && occursin("spin", msg)

        # a truth missing the declared scales: named actionably
        err = try
            builder(Dict{Symbol,Float64}(:delta_MHz => 45.0)); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin(":J_max_MHz", sprint(showerror, err))

        # non-physical scales: named actionably
        bad = deepcopy(twin.truth); bad[:J_max_MHz] = 0.0
        err = try
            builder(bad); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("J_max_MHz", sprint(showerror, err))
        bad = deepcopy(twin.truth); bad[:delta_MHz] = -1.0
        err = try
            builder(bad); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("delta_MHz", sprint(showerror, err))
    end
end

@testitem "spin family — the double-dot closed form: transition structure at the declared scales" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using Strumento: DriftPlan, instantiate
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "spin.md")
        twin = instantiate(fixture; drift = DriftPlan(), seed = 1)
        landscape = ext.spin_landscape_builder(twin.record)(twin.truth)
        p(vL, vR = 0.0) = ext.sensor_probabilities(landscape, Dict("L" => vL, "R" => vR))

        # a valid 2-outcome probability vector at every gate point
        for v in (-0.5, -0.1, 0.0, 0.25, 0.75)
            pv = p(v)
            @test length(pv) == 2
            @test pv[1] ≥ 0 && pv[2] ≥ 0
            @test pv[1] + pv[2] ≈ 1.0 atol = 1e-9
        end

        # the inter-dot transition: the sensor-high outcome is a STEP along the
        # detuning axis — full (2,0)-merged side at +1 V, full (0,2) side at -1 V
        @test p(1.0)[2] > 0.99
        @test p(-1.0)[2] < 0.01

        # the transition's midpoint sits EXACTLY on the gate diagonal (v_L = v_R,
        # i.e. detuning zero — the symmetric honeycomb vertex), for every common
        # mode: the transition line is the diagonal in the (v_L, v_R) plane
        @test p(0.0)[2] ≈ 0.5 atol = 1e-6
        @test p(0.3, 0.3)[2] ≈ 0.5 atol = 1e-6
        @test p(-0.2, -0.2)[2] ≈ 0.5 atol = 1e-6

        # symmetric broadening: p(-v) + p(v) = 1 (the noise rounding preserves
        # the bare step's antisymmetry about the diagonal)
        for v in (0.05, 0.15, 0.4)
            @test p(-v)[2] + p(v)[2] ≈ 1.0 atol = 1e-6
        end

        # monotone along the detuning axis (the observable the autotuning tracks)
        vs = collect(range(-0.6, 0.6, length = 61))
        rises = [p(v)[2] for v in vs]
        @test all(diff(rises) .> 0)
        @test rises[end] - rises[1] > 0.9

        # ── the declared scales, pinned in the transition WIDTH ──
        # with the noise scale zeroed, the bare 10-90 width is the closed form
        # 1.886 * t_c volts (t_c = J_max/2, lever arm 1 GHz/V): the fixture's
        # J_max = 95 MHz -> ~0.09 V, within a semantic band (never a captured golden)
        quiet = deepcopy(twin.truth); quiet[:delta_MHz] = 0.0
        bare = ext.spin_landscape_builder(twin.record)(quiet)
        cross(bare_land, target) = begin
            lo, hi = 0.0, 1.0
            for _ in 1:60
                mid = (lo + hi) / 2
                (ext.sensor_probabilities(bare_land, Dict("L" => mid))[2] < target) ?
                    (lo = mid) : (hi = mid)
            end
            (lo + hi) / 2
        end
        bare_width = cross(bare, 0.9) - cross(bare, 0.1)
        @test 0.085 < bare_width < 0.095          # ≈ 0.944 * J_max_MHz / alpha

        # the noise scale widens it: the fixture's delta = 45 MHz broadens the
        # same step to ~0.11 V (the quasi-static rounding at its declared scale)
        with_noise = cross(landscape, 0.9) - cross(landscape, 0.1)
        @test 0.10 < with_noise < 0.13
        @test with_noise > bare_width
    end
end

@testitem "spin family — truth-dependence: perturbing landscape truth moves the transition; advance! + rebuild reflects drift" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using Strumento: DriftPlan, Ramp, instantiate, advance!
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "spin.md")

        # the seeded pin: the SAME builder, truths perturbed by hand — the
        # transition WIDTH moves measurably, the transition POSITION stays on
        # the gate diagonal (a control, not truth)
        width(landscape) = begin
            lo, hi = 0.0, 2.0
            find(target) = begin
                lo, hi = 0.0, 2.0
                for _ in 1:60
                    mid = (lo + hi) / 2
                    (ext.sensor_probabilities(landscape, Dict("L" => mid))[2] < target) ?
                        (lo = mid) : (hi = mid)
                end
                (lo + hi) / 2
            end
            find(0.9) - find(0.1)
        end
        mid_v(landscape) = begin
            lo, hi = -2.0, 2.0
            for _ in 1:60
                mid = (lo + hi) / 2
                (ext.sensor_probabilities(landscape, Dict("L" => mid))[2] < 0.5) ?
                    (lo = mid) : (hi = mid)
            end
            (lo + hi) / 2
        end

        twin = instantiate(fixture; drift = DriftPlan(), seed = 0x5EED)
        builder = ext.spin_landscape_builder(twin.record)
        base_width = width(builder(twin.truth))

        # a seeded pin: perturb the exchange truth — the anticrossing gap opens
        truth_J = deepcopy(twin.truth); truth_J[:J_max_MHz] *= 2.0
        wJ = width(builder(truth_J))
        @test 1.5 < wJ / base_width < 2.1        # measured ~1.73 for this pair
        @test abs(mid_v(builder(truth_J))) < 0.005

        # perturb the charge-noise truth — the quasi-static rounding widens
        truth_d = deepcopy(twin.truth); truth_d[:delta_MHz] *= 3.0
        wD = width(builder(truth_d))
        @test 1.6 < wD / base_width < 2.1        # measured ~1.86 for this pair
        @test abs(mid_v(builder(truth_d))) < 0.005

        # ── advance! + rebuild: DRIFT moves the transition through the same
        # seam — the builder consumes the twin's CURRENT truth (Ramp on the
        # exchange, one twin-day: J_max 95 -> 142.5 MHz) ──
        plan = DriftPlan(:J_max_MHz => [Ramp(rate = 47.5)])
        twin_d = instantiate(fixture; drift = plan, seed = 7)
        w_before = width(builder(twin_d.truth))
        advance!(twin_d, 1.0)
        @test twin_d.truth[:J_max_MHz] ≈ 142.5   # the twin moved...
        w_after = width(builder(twin_d.truth))   # ...and the REBUILT landscape feels it
        @test w_after / w_before > 1.2           # measured ~1.45
        @test abs(mid_v(builder(twin_d.truth))) < 0.005

        # belief never moves the landscape: a calibrated J_max belief is not truth
        using Strumento: calibrate!, believed
        calibrate!(twin_d, Dict("J_max_MHz" => 95.0))
        @test believed(twin_d)["J_max_MHz"] == 95.0
        @test width(builder(twin_d.truth)) == w_after   # unchanged — truth is the input
    end
end

@testitem "the spin family rides the Piccolo extension; the base package gains nothing" begin
    using Strumento
    # UNguarded (like the soc interface and bosonic-family items): the base
    # placement pin must hold in EVERY load configuration — the spin family
    # names must never exist on the base module, extension or not.
    @test !isdefined(Strumento, :spin_landscape_builder)
    @test !isdefined(Strumento, :DoubleDotLandscape)
    if Base.identify_package("Piccolo") === nothing
        @info "skipping the extension side: no Piccolo in this environment"
        @test true
    else
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        @test ext !== nothing
        @test isdefined(ext, :spin_landscape_builder)
        @test isdefined(ext, :DoubleDotLandscape)
    end
end
