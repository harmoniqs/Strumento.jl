# ──── The bosonic family (issue #21) ──────────────────────────────────────────
# The family physics factory for the bosonic twin: transmon ancilla dispersively
# coupled to a storage cavity, WITH Lindblad decay (cavity κ, transmon T1) — the
# Stanford-class device shape. Grounded in the bosonic skill (the displaced-frame
# model, cutoff sizing) before authoring; every convention is documented on
# `bosonic_system_builder` below. Vendored from Piccolo primitives inline
# (annihilate + kron + OpenQuantumSystem): zero demo-repo or vault dependencies.

using LinearAlgebra: I, kron

# Unwrap a decay value from the record's noise map. The vault schema wraps noise
# values as {value, estimate, note} (the same form TwinSoc's readout-confusion
# unwrapping requires) — bare numbers are rejected with the shape named.
function _bosonic_noise_value(record, key)
    haskey(record.noise, key) || error(
        "bosonic family: record $(repr(record.id)) carries no noise.$key — " *
        "the decay wiring requires it in the wrapped form " *
        "{value: <number>, estimate, note}")
    wrapped = record.noise[key]
    (wrapped isa AbstractDict && haskey(wrapped, "value") && wrapped["value"] isa Real) || error(
        "bosonic family: noise.$key must be the wrapped form " *
        "{value: <number>, estimate, note} (got $(typeof(wrapped)))")
    return Float64(wrapped["value"])
end

# A required truth parameter, named actionably when missing.
function _bosonic_truth(truth::Dict{Symbol,Float64}, key::Symbol)
    haskey(truth, key) || error(
        "bosonic family: truth is missing :$key — the bosonic system is built " *
        "from the CURRENT truth (record parameters enter truth at instantiate)")
    return truth[key]
end

# A level count: an integer-valued truth parameter with a floor.
function _bosonic_dim(truth::Dict{Symbol,Float64}, key::Symbol, min::Int)
    val = _bosonic_truth(truth, key)
    (isinteger(val) && val ≥ min) || error(
        "bosonic family: truth :$key must be an integer ≥ $min (got $val) — " *
        "level counts are model dims, not physics values")
    return Int(val)
end

"""
    bosonic_system_builder(record::TwinRecord) -> (truth::Dict{Symbol,Float64}) -> OpenQuantumSystem

The bosonic family factory: a **builder of the TwinSoc family seam**
(`families["bosonic"] = bosonic_system_builder(twin.record)`), returning a
closure that maps the twin's CURRENT truth to the live quantum system — so a
`TwinSoc` built on it feels drift the acquire it evolved in (the builder is a
function of truth, never a cached system).

The system is the transmon-ancilla–cavity shape of the Stanford bosonic record,
with Lindblad decay. Construction is **vendored from Piccolo primitives inline**
(`annihilate`, `kron`, `OpenQuantumSystem`) — no demo-repo or vault dependency.
Because it returns an `OpenQuantumSystem`, `TwinSoc` rolls it out through the
Lindblad master equation (`DensityTrajectory`), so the decay is LIVE in every
acquire.

# The Hamiltonian (rotating frame; rad·GHz, so rollout time is ns)

```
H/ħ = χ (a†a)(q†q) + (α_c/2) a†²a² + (α_q/2) q†²q² + χ′ (a†²a²)(q†q)
```

`a` is the cavity mode, `q` the transmon mode, in the joint basis
**cavity ⊗ transmon** (cavity-major, the bosonic skill's `kron` ordering). The
frame is the resonant rotating frame: the bare cavity and transmon frequencies
are absorbed, so `H_drift` is diagonal and the record's dispersive shift is read
directly off it — the cavity transition shifts by **χ per transmon
excitation** and the transmon transition by **χ per cavity photon** (closed
form, pinned by tests). The bosonic skill's displaced frame is the
optimization-side control reparameterization; the twin rolls out *played*
pulses in the frame the drives are defined in, so the factory uses the plain
rotating frame with linear quadrature drives.

# Unit-convention table (record → model)

| record field      | record meaning                  | model value (rad·GHz / ns)     |
|-------------------|--------------------------------|--------------------------------|
| `chi_kHz`         | dispersive shift χ/2π (kHz)    | `χ = 2π · v · 1e-6`            |
| `K_q_GHz`         | transmon anharmonicity α_q/2π  | `α_q = 2π · v`                 |
| `K_c_kHz`         | cavity self-Kerr α_c/2π (kHz)  | `α_c = 2π · v · 1e-6`          |
| `chi_p_kHz`       | higher-order dispersive χ′/2π  | `χ′ = 2π · v · 1e-6`           |
| `T1_q_us` (noise)  | transmon T1 (μs)               | `γ₁ = 1e-3 / v` [ns⁻¹]         |
| `kappa_c_per_us` (noise) | cavity κ (per μs)        | `κ_c = v · 1e-3` [ns⁻¹]        |

Both Kerrs enter in the ladder convention `E_n = ωn + (α/2)n(n−1)` (the skill's
`−K_q q†²q²` form with `K_q = −α_q/2`): the record's `K_q_GHz` is the signed
ANHARMONICITY (negative for a transmon), not the positive self-Kerr symbol.

# Level-count conventions

`N_transmon` and `N_fock` are the subsystem **dimensions** (the bosonic skill's
`annihilate(N_fock)` cutoff semantics: `N_fock = 10` means Fock states
`|0⟩…|9⟩`, as in the GKP demo precedent): joint dim
`N_transmon × N_fock`. The fixture record's `N_transmon = 2` therefore makes
the α_q Kerr term **structurally zero** (`q†²q² = n(n−1)` vanishes on 2 levels)
— a qubit-only ancilla model, the record's intent.

# Decay wiring (from the RECORD, not truth)

Lindblad dissipators `√κ_c · a` (cavity) then `√γ₁ · q` (transmon, this order,
both nonzero by construction), with κ_c and T1 read from the record's wrapped
`noise` entries. These are static device properties in v1 — drift plans move
the Hamiltonian truth only — so they close over the record at factory time.

The readout convention (why the record's confusion is 2×2 against a
24-dimensional system) is documented on `bosonic_ancilla_populations`.
"""
function bosonic_system_builder(record::Strumento.TwinRecord)
    record.family == "bosonic" || error(
        "bosonic family: bosonic_system_builder got a $(repr(record.family)) " *
        "record ($(repr(record.id))) — the factory is keyed by the record's " *
        "family field; build it from a bosonic record")
    κ_c = _bosonic_noise_value(record, "kappa_c_per_us") * 1e-3   # per μs → per ns
    T1_q_us = _bosonic_noise_value(record, "T1_q_us")
    T1_q_us > 0 || error(
        "bosonic family: noise.T1_q_us must be > 0 (got $T1_q_us) — the decay " *
        "rate is 1/T1")
    γ₁ = 1e-3 / T1_q_us                                          # T1[μs] → per ns
    return function (truth::Dict{Symbol,Float64})
        χ  = 2π * _bosonic_truth(truth, :chi_kHz) * 1e-6
        α_q = 2π * _bosonic_truth(truth, :K_q_GHz)
        α_c = 2π * _bosonic_truth(truth, :K_c_kHz) * 1e-6
        χ_p = 2π * _bosonic_truth(truth, :chi_p_kHz) * 1e-6
        n_t = _bosonic_dim(truth, :N_transmon, 2)
        n_f = _bosonic_dim(truth, :N_fock, 1)

        # Joint operators, cavity ⊗ transmon (the bosonic skill's kron order).
        a = kron(annihilate(n_f), Matrix{ComplexF64}(I, n_t, n_t))   # cavity mode
        q = kron(Matrix{ComplexF64}(I, n_f, n_f), annihilate(n_t))   # transmon mode
        na, nq = a'a, q'q

        # Rotating-frame dispersive Hamiltonian (see the unit table above).
        H_drift = χ * na * nq + (α_c / 2) * (a'^2 * a^2) +
                  (α_q / 2) * (q'^2 * q^2) + χ_p * (a'^2 * a^2) * nq

        # Linear quadrature drives: transmon I/Q then cavity I/Q. Bounds are
        # unit-symmetric placeholders — the record carries no drive bound and
        # soc rollouts enforce no bound.
        H_drives = [(q + q') / 2, im * (q' - q) / 2, (a + a') / 2, im * (a' - a) / 2]

        # Lindblad decay (this order: cavity first, transmon second).
        L_cavity   = kron(sqrt(κ_c) .* annihilate(n_f), Matrix{ComplexF64}(I, n_t, n_t))
        L_transmon = kron(Matrix{ComplexF64}(I, n_f, n_f), sqrt(γ₁) .* annihilate(n_t))

        return OpenQuantumSystem(H_drift, H_drives, [1.0, 1.0, 1.0, 1.0];
                                dissipators = [L_cavity, L_transmon])
    end
end

export bosonic_system_builder

@testitem "bosonic family — the factory turns the record's truth into a decay-carrying system (no hand-passed parameters)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using Strumento: DriftPlan, instantiate, load_record
        using LinearAlgebra
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
        record = load_record(fixture)
        twin = instantiate(fixture; drift = DriftPlan(), seed = 1)

        builder = ext.bosonic_system_builder(record)
        @test builder isa Function
        sys = builder(twin.truth)
        @test sys isa OpenQuantumSystem

        # dims from the record's level counts, via the CURRENT truth:
        # N_transmon transmon levels ⊗ N_fock Fock levels (cavity-major basis).
        @test sys.levels == 24                 # 2 transmon × 12 Fock
        @test sys.n_drives == 4                # transmon I/Q + cavity I/Q quadratures

        # decay is live and comes from the RECORD's noise — no hand-passed values:
        # κ_c from noise.kappa_c_per_us, T1 from noise.T1_q_us (μs → ns units).
        κ = record.noise["kappa_c_per_us"]["value"] * 1e-3   # per μs → per ns
        γ = 1e-3 / record.noise["T1_q_us"]["value"]          # T1[μs] → per ns
        @test length(sys.dissipators) == 2
        idx(n, m) = (n - 1) * 2 + m             # cavity ⊗ transmon, 1-based
        L_cavity = dissipator_matrix(sys.dissipators[1])
        L_transmon = dissipator_matrix(sys.dissipators[2])
        @test norm(L_cavity) > 0 && norm(L_transmon) > 0     # nonzero decay
        # the cavity dissipator is √κ · a on the fock mode: it maps fock n → n−1,
        # so its entries sit at [target, source]: L[(n,m),(n+1,m)] = √κ√(n−1)
        @test L_cavity[idx(1, 1), idx(2, 1)] ≈ sqrt(κ) atol = 1e-15
        @test L_cavity[idx(2, 1), idx(3, 1)] ≈ sqrt(2κ) atol = 1e-15
        # the transmon dissipator is √γ₁ · q on the ancilla: L[(n,g),(n,e)] = √γ₁
        @test L_transmon[idx(1, 1), idx(1, 2)] ≈ sqrt(γ) atol = 1e-15
        @test L_transmon[idx(7, 1), idx(7, 2)] ≈ sqrt(γ) atol = 1e-15
    end
end

@testitem "bosonic family — the Hamiltonian matches the dispersive closed form (units and frame pinned)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using Strumento: DriftPlan, instantiate, load_record
        using LinearAlgebra
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
        twin = instantiate(fixture; drift = DriftPlan(), seed = 1)
        sys = ext.bosonic_system_builder(twin.record)(twin.truth)

        # the record's symbols in model units (the factory's documented table)
        χ  = 2π * twin.truth[:chi_kHz] * 1e-6     # kHz → rad·GHz
        α_c = 2π * twin.truth[:K_c_kHz] * 1e-6
        α_q = 2π * twin.truth[:K_q_GHz]
        χ_p = 2π * twin.truth[:chi_p_kHz] * 1e-6

        idx(n, m) = (n - 1) * 2 + m               # cavity ⊗ transmon, 1-based
        H = sys.H_drift

        # closed form: E(n, m) = χ(n−1)(m−1) + (α_c/2)(n−1)(n−2) + (α_q/2)(m−1)(m−2)
        # + χ′(n−1)(n−2)(m−1) — the rotating frame absorbs the bare frequencies,
        # so H_drift is DIAGONAL and the record's dispersive shift reads off it.
        @test norm(Matrix(H) - diagm(diag(H))) < 1e-15
        @test H[idx(1, 1), idx(1, 1)] ≈ 0.0 atol = 1e-15
        # the cavity transition shifts by χ per transmon excitation — the
        # record's dispersive shift, at its kHz magnitude and sign
        @test H[idx(2, 2), idx(2, 2)] ≈ χ
        @test H[idx(2, 2), idx(2, 2)] - H[idx(2, 1), idx(2, 1)] ≈ 2π * (-298.4e-6)
        # the transmon transition shifts by χ per cavity photon: the one-photon
        # transmon pull minus the zero-photon pull
        @test (H[idx(2, 2), idx(2, 2)] - H[idx(2, 1), idx(2, 1)]) -
              (H[idx(1, 2), idx(1, 2)] - H[idx(1, 1), idx(1, 1)]) ≈ χ
        # two photons: the cavity self-Kerr enters the ladder (spacings shrink
        # by |α_c| per photon) on top of the doubled dispersive pull
        @test H[idx(3, 2), idx(3, 2)] ≈ 2χ + α_c
        @test H[idx(3, 1), idx(3, 1)] ≈ α_c

        # N_transmon = 2: the α_q (anharmonicity) and χ′ terms are structurally
        # zero on a 2-level ancilla — the documented level-count convention.
        # (A 3-level record would see (α_q/2)q†²q²; the record's intent is a
        # qubit-only ancilla.)
        @test H[idx(1, 1), idx(1, 1)] ≈ 0.0 atol = 1e-15   # no q†q bare term in frame

        # the four drives are the transmon and cavity quadratures (the bosonic
        # skill's 4 control channels), in the documented order:
        # transmon I, transmon Q, cavity I, cavity Q — Hermitian, unit-bounded.
        @test sys.n_drives == 4
        @test all(b -> b == (-1.0, 1.0), sys.drive_bounds)   # v1 unit placeholder
        D = [drive_matrix(d) for d in sys.H_drives]
        @test all(d -> ishermitian(d), D)
        @test D[1][idx(1, 1), idx(1, 2)] ≈ 0.5              # transmon I: (q+q†)/2
        @test D[2][idx(1, 1), idx(1, 2)] ≈ -0.5im           # transmon Q: i(q†−q)/2
        @test D[3][idx(1, 1), idx(2, 1)] ≈ 0.5              # cavity I: (a+a†)/2
        @test D[4][idx(1, 1), idx(2, 1)] ≈ -0.5im           # cavity Q: i(a†−a)/2
    end
end

@testitem "bosonic family — the system is a function of CURRENT truth (drift felt; wiring errors named)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using Strumento: DriftPlan, Ramp, instantiate, load_record
        using LinearAlgebra
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
        twin = instantiate(fixture; drift = DriftPlan(), seed = 1)
        builder = ext.bosonic_system_builder(twin.record)
        idx(n, m) = (n - 1) * 2 + m

        # ── truth-dependence: perturbing χ moves the dispersive signature at
        # exactly the documented kHz → rad·GHz conversion ──
        sys1 = builder(twin.truth)
        truth2 = deepcopy(twin.truth)
        truth2[:chi_kHz] += 1000.0                        # +1 MHz
        sys2 = builder(truth2)
        @test sys2.H_drift[idx(2, 2), idx(2, 2)] -
              sys1.H_drift[idx(2, 2), idx(2, 2)] ≈ 2π * 1e-3 atol = 1e-18
        # a Hamiltonian that is NOT a function of current truth (a cached
        # system) would return the unperturbed value — the shift is exact

        # ── advance!: the factory reflects DRIFTED truth (the seeded plan
        # from the twin-core suite: Ramp(-0.5/day), 10 days → χ_kHz −5.0) ──
        plan = DriftPlan(:chi_kHz => [Ramp(rate = -0.5)])
        twin_d = instantiate(fixture; drift = plan, seed = 7)
        sys_before = builder(twin_d.truth)
        advance!(twin_d, 10.0)
        @test twin_d.truth[:chi_kHz] == -303.4             # the twin moved
        sys_after = builder(twin_d.truth)
        @test sys_after.H_drift[idx(2, 2), idx(2, 2)] -
              sys_before.H_drift[idx(2, 2), idx(2, 2)] ≈ 2π * (-5.0e-6) atol = 1e-18

        # ── wiring errors are actionable ──
        # a non-bosonic record: the factory is keyed by the record's family
        spinrec = load_record(joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "spin.md"))
        err = try
            ext.bosonic_system_builder(spinrec); nothing
        catch e
            e
        end
        @test err isa ErrorException
        msg = sprint(showerror, err)
        @test occursin("family", msg) && occursin("bosonic", msg)

        # a record without the decay noise: the missing noise key is named
        dir = mktempdir()
        path = joinpath(dir, "no-decay.md")
        write(path, "---\ntype: device-twin\nid: x\nfamily: bosonic\n" *
                    "parameters:\n  chi_kHz: -298.4\n  K_q_GHz: -0.161\n" *
                    "  K_c_kHz: -12.3\n  chi_p_kHz: 0.0\n" *
                    "  N_transmon: 2\n  N_fock: 12\n" *
                    "noise:\n  T1_q_us: {value: 120.0, estimate: true}\n" *
                    "---\n# body\n")
        rec = load_record(path)
        err = try
            ext.bosonic_system_builder(rec); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("kappa_c_per_us", sprint(showerror, err))

        # a truth missing a required parameter: named actionably
        err = try
            builder(Dict{Symbol,Float64}(:chi_kHz => -298.4)); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin(":K_q_GHz", sprint(showerror, err))

        # non-integer / too-small level counts: named actionably
        bad = deepcopy(twin.truth)
        bad[:N_fock] = 12.5
        err = try
            builder(bad); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("N_fock", sprint(showerror, err))
        bad = deepcopy(twin.truth)
        bad[:N_transmon] = 1.0
        err = try
            builder(bad); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("N_transmon", sprint(showerror, err))
    end
end
