# ──── Certification gates (issue #22) ──────────────────────────────────────────
# The M2 capstone: the twin program's acceptance machinery — (1) parameter
# recovery through a real fit path, (2) calibration transfer across same-class
# twins — plus the promotion runbook's supporting surface (docs/certification.md).
#
# THE EXPERIMENT DESIGN (grounded in the bosonic skill + the χ-observable caveat)
#
# The dispersive shift of the ANCIlla frequency requires cavity photons (vacuum
# → no shift); the shift of the CAVITY frequency is χ per ancilla occupation.
# Two observables, each carrying one parameter cleanly:
#
# • χ — the photon-number COMB. Displace the cavity (a DC drive on the g-branch,
#   resonant in the rotating frame by construction) with the ancilla in |g,0⟩,
#   then a shaped π-pulse on the ancilla quadratures rotating at f_a, swept.
#   The ancilla transition at k photons sits at E(k,e)−E(k,g) = χk EXACTLY —
#   the cavity Kerr is m-independent and cancels in the difference — so the
#   spectrum is a comb of lines at f_a = −χk/2π whose SPACING is χ. The comb
#   exists only because the cavity holds photons: the χ-observable caveat,
#   made the experiment.
#
# • K_c — the RAMSEY-CONTRAST LADDER. Ancilla in (|g,0⟩+|e,0⟩)/√2, a shaped
#   rotating cavity drive swept across the e-branch resonance, then a
#   broadband DC π/2 analysis pulse on the ancilla. The e-branch cavity ladder
#   (transitions at χ + kα_c) saturates under the drive and imprints K_c on the
#   contrast profile; χ is pinned from the comb stage (sequential estimator).
#
# The fit is a Julia-side physics-model spectral fit — the bring-up layer's
# fitter seed: weighted binomial χ² of the measured sweep against the family
# model rolled at candidate parameters (the record's other parameters, noise,
# and readout confusion held at their BELIEF values — the fit never sees the
# twin's truth). Python-fitter bridging is a later, deliberate seam.
#
# THE TOLERANCE DERIVATION (never hand-waved): the recovery tolerance is
# 5·σ_derived, with σ_derived the observed-information Cramér–Rao scale of the
# fit's own model — per-point binomial weights N/(q̂(1−q̂)) against the numeric
# model Jacobian. For K_c the χ̂ uncertainty propagates through the Ramsey
# profile's χ–K_c covariance (κ = Σ_Kχ/Σ_χχ, validated against a direct
# refit at a mis-set χ): σ(K_c) = √(σ_CRB² + (κ·σ_χ̂)²).
#
# CI runs this machinery on COMMITTED FIXTURES ONLY — zero live vault reads
# (audited by the fixtures-only testitem below). The certification RUN against
# the real vault record is a campaign act documented in docs/certification.md;
# the record's status flip (seed → validated) is a HUMAN promotion.

@testitem "cert 1 — parameter recovery through the soc face (seeded, pinned)" begin
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
        pert = Dict(:chi_kHz => 8.0, :K_c_kHz => -2.0)   # class-realistic scales:
        # δχ = 8 kHz ≈ 2.7% of |χ|, ~3.3× the record's OU prior σ (0.008·298.4);
        # δK_c = 2 kHz ≈ 16% of |K_c|. Both ≫ the fit's resolution (below) and
        # ≪ the parameter scale — a realistic miscalibration the gate must catch.
        seed = 0xC0FFEE

        result = ext.certify_parameter_recovery(fixture; seed = seed,
                                                perturbation = pert)

        # ── AC: the perturbed truth is recovered through the fit path within
        # the DERIVED tolerance (not a hand-picked one) ──
        truth_chi = record.parameters["chi_kHz"] + pert[:chi_kHz]
        truth_kc = record.parameters["K_c_kHz"] + pert[:K_c_kHz]
        @test result.chi_kHz !== nothing && result.K_c_kHz !== nothing
        @test abs(result.chi_kHz - truth_chi) < result.chi_tolerance_kHz
        @test abs(result.K_c_kHz - truth_kc) < result.K_c_tolerance_kHz

        # the tolerance is 5·σ_derived with σ from the fit's information content
        @test result.chi_tolerance_kHz ≈ ext.BOSONIC_CERT_TOLERANCE_SIGMA *
                                         result.chi_sigma_kHz
        @test result.K_c_tolerance_kHz ≈ ext.BOSONIC_CERT_TOLERANCE_SIGMA *
                                         result.K_c_sigma_kHz
        # the pinned design's information content (kHz): σ_χ from the comb
        # spacing statistics, σ_K_c including the χ̂ propagation term
        @test 0.02 < result.chi_sigma_kHz < 0.5
        @test 0.05 < result.K_c_sigma_kHz < 1.5
        # the tolerance MEANS something: 5σ ≪ the perturbation it must catch
        @test result.chi_tolerance_kHz < 0.5 * pert[:chi_kHz]
        @test result.K_c_tolerance_kHz < 2.0 * abs(pert[:K_c_kHz])

        # ── AC: the fit is a real procedure, not a restatement of the generator:
        # shot noise moves the estimate off the truth, and the fit residual is
        # statistically sound (χ²/dof ≈ 1 for the correct model) ──
        @test result.chi_kHz != truth_chi
        @test result.K_c_kHz != truth_kc
        @test 0.2 < result.chi_chi2_dof < 3.0
        @test 0.2 < result.K_c_chi2_dof < 3.0

        # ── the gate detects a WRONG record: the fitted values disagree with
        # the record's belief (perturbed truth), and the flag is consistent
        # with its definition |fit − record| ≤ tolerance ──
        @test !result.agrees_with_record
        @test result.agrees_with_record ==
              (abs(result.chi_kHz - record.parameters["chi_kHz"]) ≤
                   result.chi_tolerance_kHz &&
               abs(result.K_c_kHz - record.parameters["K_c_kHz"]) ≤
                   result.K_c_tolerance_kHz)

        # provenance: the result is replayable evidence
        @test result.seed == seed
        @test result.record_id == record.id
        @test result.perturbation == pert

        # ── seeded replay (in-process form): the identical inputs reproduce
        # the identical certification, bit-exact ──
        again = ext.certify_parameter_recovery(fixture; seed = seed,
                                               perturbation = pert)
        @test again.chi_kHz == result.chi_kHz
        @test again.K_c_kHz == result.K_c_kHz
        @test again.chi_sigma_kHz == result.chi_sigma_kHz
        @test again.K_c_sigma_kHz == result.K_c_sigma_kHz
    end
end

@testitem "cert 1 — the fit is data-driven: recovery statistics across seeds" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using Strumento: load_record
        using Statistics
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)

        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
        record = load_record(fixture)
        pert = Dict(:chi_kHz => 8.0, :K_c_kHz => -2.0)
        truth_chi = record.parameters["chi_kHz"] + pert[:chi_kHz]
        truth_kc = record.parameters["K_c_kHz"] + pert[:K_c_kHz]

        # a REDUCED variant of the pinned design (fewer sweep points and shots:
        # the point here is the fitter's statistics, not the full precision) —
        # the machinery is the same code path at a smaller budget.
        design = ext.BosonicCertDesign(
            comb_freqs_kHz = vcat(collect(230.0:24.0:350.0),
                                 collect(520.0:24.0:640.0)),
            ramsey_freqs_kHz = collect(245.0:9.0:353.0),
            comb_shots = 100_000, ramsey_shots = 100_000)

        seeds = [0x0AA1, 0x0BB2, 0x0CC3, 0x0DD4, 0x0EE5]
        chis = Float64[]; kcs = Float64[]
        for s in seeds
            r = ext.certify_parameter_recovery(fixture; seed = s,
                                               perturbation = pert, design = design)
            # every seed recovers within its own derived tolerance
            @test abs(r.chi_kHz - truth_chi) < r.chi_tolerance_kHz
            @test abs(r.K_c_kHz - truth_kc) < r.K_c_tolerance_kHz
            push!(chis, r.chi_kHz); push!(kcs, r.K_c_kHz)
        end

        # the estimates VARY with the shot draw — a restatement of the
        # generator would be constant
        @test length(unique(chis)) == length(seeds)
        @test length(unique(kcs)) == length(seeds)

        # the derived σ is honest: the empirical scatter matches the
        # information-content scale (within a factor 3 on a 5-seed sample)
        σchi = mean([ext.certify_parameter_recovery(fixture; seed = seeds[1],
                             perturbation = pert, design = design).chi_sigma_kHz
                     for _ in 1:1])   # σ is seed-stable; reuse one value
        @test 0.3 * σchi < std(chis) < 3.0 * σchi
    end
end

@testitem "cert 2 — the transfer metric definition (pinned before implementation)" begin
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
        design = ext.BosonicCertDesign()
        builder = ext.bosonic_system_builder(record)
        n_t = Int(record.parameters["N_transmon"])
        n_f = Int(record.parameters["N_fock"])
        meas = ext.bosonic_ancilla_populations(n_t, n_f)
        families = Dict("bosonic" => builder)
        probes = design.transfer_probes

        # DEFINITION (pinned): calibration_transfer_metric(twin, families,
        # measurement_fn, probes, design) = the mean over `probes` of the
        # total-variation distance between
        #   q̂ = the BELIEF-predicted outcome distribution (a rollout of the
        #       probe pulse at the BELIEVED parameters, remapped by the
        #       BELIEVED readout calibration — exact), and
        #   q  = the twin's actual outcome distribution (the TwinSoc EXACT
        #       response: truth rollout + the record's confusion).
        # Lower is better; 0 = perfect prediction; the belief is believed(twin).

        # (a) with belief == truth and the record's own confusion, the metric
        # is EXACTLY zero (a fresh, unperturbed twin: belief = truth = record)
        twin = instantiate(fixture; drift = DriftPlan(), seed = 1)
        @test ext.calibration_transfer_metric(twin, families, meas, probes, design) == 0.0

        # (b) range and sign: a WRONG belief predicts worse than truth
        twin.truth[:chi_kHz] = record.parameters["chi_kHz"] + 8.0   # drift the truth away
        m = ext.calibration_transfer_metric(twin, families, meas, probes, design)
        @test 0.0 < m < 1.0

        # (c) the metric is the hand-computed mean TV distance over the probes
        # (recomputed here from public pieces: the same rollout, the same
        # measurement function, the same confusion remap)
        Crows = record.noise["readout_confusion"]["value"]
        C = Matrix{Float64}([Crows[i][j] for i in eachindex(Crows), j in eachindex(Crows)])
        MAP = ext._cert_channel_map()
        tv(p, q) = 0.5 * sum(abs.(p .- q))
        tvs = Float64[]
        for (stage, f_kHz) in probes
            soc = stage == :ramsey ?
                  ext.TwinSoc(twin, ext._cert_ramsey_state(n_t, n_f),
                             ext._cert_ramsey_state(n_t, n_f);
                             families = families, measurement_fn = meas,
                             exact = true, dac_rate = design.dac_rate) :
                  ext.TwinSoc(twin, ext._cert_comb_state(n_t, n_f),
                             ext._cert_comb_state(n_t, n_f);
                             families = families, measurement_fn = meas,
                             exact = true, dac_rate = design.dac_rate)
            pulse, nsamp = stage == :ramsey ?
                           ext._cert_ramsey_pulse(design, f_kHz * 1e-6) :
                           ext._cert_comb_pulse(design, f_kHz * 1e-6)
            q_true = real.(execute!(soc, pulse, MAP, [nsamp])[1])
            belief = believed(twin)
            bparams = Dict{Symbol,Float64}(
                Symbol(k) => Float64(v) for (k, v) in belief if v isa Real)
            q_pred = ext._cert_predict(builder, bparams, C, design, stage, f_kHz * 1e-6)
            push!(tvs, tv(q_pred, q_true))
        end
        @test m ≈ sum(tvs) / length(probes) atol = 1e-12
    end
end

@testitem "cert 2 — A's calibration transfers to same-class twin B (seeded, pinned)" begin
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

        # same-class twins: A's truth drifted from the record by (δχ, δK_c);
        # B's truth by δ_A + ε — the same class offset plus an independent
        # same-class residual (ε within the drift-prior scale). A's
        # calibration transfers iff knowing A beats knowing the raw record.
        pert_a = Dict(:chi_kHz => 8.0, :K_c_kHz => -2.0)
        pert_b = Dict(:chi_kHz => 8.0 + 2.5, :K_c_kHz => -2.0 - 0.8)

        # a reduced design keeps the item inside the suite's budget without
        # changing the story (A's fit σ ≪ the ε it must resolve)
        design = ext.BosonicCertDesign(
            comb_freqs_kHz = vcat(collect(230.0:24.0:350.0),
                                 collect(520.0:24.0:640.0)),
            ramsey_freqs_kHz = collect(245.0:10.0:355.0),
            comb_shots = 100_000, ramsey_shots = 200_000,
            readout_shots = 200_000)

        result = ext.certify_calibration_transfer(fixture;
            seed_a = 0xC0FFEE, perturbation_a = pert_a,
            seed_b = 0xBEEF, perturbation_b = pert_b, design = design)

        # the metric on B with A's calibration applied beats B's uncalibrated
        # baseline (raw record defaults + placeholder noise) — with margin
        @test result.metric_baseline > 0.0
        @test result.metric_calibrated < result.metric_baseline
        @test result.metric_calibrated < 0.5 * result.metric_baseline
        @test result.improved

        # A's calibration is a real bundle: fitted parameters + the readout
        # calibration, with provenance
        cal = result.calibration
        @test cal isa ext.BosonicCalibration
        @test abs(cal.chi_kHz - (record.parameters["chi_kHz"] + 8.0)) < 0.5
        @test size(cal.confusion) == (2, 2)
        @test cal.confusion ≈ record.noise["readout_confusion"]["value"] atol = 0.01
        @test haskey(cal.provenance, "seed_a")
        @test haskey(cal.provenance, "record_id")

        # the write-back path: calibrate! lands the bundle in twin B's belief
        twin_b = instantiate(fixture; drift = DriftPlan(), seed = 0xBEEF)
        ext.calibrate!(twin_b, cal)
        @test believed(twin_b)["chi_kHz"] == cal.chi_kHz
        @test believed(twin_b)["K_c_kHz"] == cal.K_c_kHz
        wrapped = believed(twin_b)["readout_confusion"]
        @test wrapped isa AbstractDict && haskey(wrapped, "value")
        @test Matrix{Float64}(wrapped["value"]) == cal.confusion
    end
end

@testitem "cert 2 — the readout confusion calibration is measured, not assumed" begin
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
        design = ext.BosonicCertDesign(readout_shots = 400_000)
        builder = ext.bosonic_system_builder(record)
        n_t = Int(record.parameters["N_transmon"])
        n_f = Int(record.parameters["N_fock"])
        meas = ext.bosonic_ancilla_populations(n_t, n_f)

        twin = instantiate(fixture; drift = DriftPlan(), seed = 0x5EED)
        Chat = ext.estimate_readout_confusion(twin, Dict("bosonic" => builder), meas;
                                              design = design)

        # the estimate recovers the record's (true, here) confusion to the
        # shot-noise scale — measured through the soc face (g/e preparations,
        # the e-prep T1-corrected), not read off the record
        C = record.noise["readout_confusion"]["value"]
        @test size(Chat) == (2, 2)
        @test all(>=(0), Chat)
        for i in 1:2, j in 1:2
            @test abs(Chat[i, j] - C[i][j]) < 0.01
        end
        # rows are outcome distributions
        @test all(i -> isapprox(sum(Chat[i, :]), 1.0; atol = 0.01), 1:2)

        # seeded replay: the identical estimate, bit-exact
        twin2 = instantiate(fixture; drift = DriftPlan(), seed = 0x5EED)
        @test ext.estimate_readout_confusion(twin2, Dict("bosonic" => builder), meas;
                                             design = design) == Chat
    end
end

@testitem "the promotion runbook exists and states the human gate" begin
    using Strumento
    # The runbook is a repo document (docs/certification.md) — the campaign's
    # recipe for running the certs against the REAL vault record. It must
    # carry: the exact commands, the evidence format, where the evidence lands
    # in the vault, that the status flip is a HUMAN promotion, that rehearsal
    # evidence is marked (twin-derived results never claim device status),
    # and the fixtures-only CI boundary.
    path = joinpath(pkgdir(Strumento), "docs", "certification.md")
    @test isfile(path)
    text = read(path, String)

    # the exact commands: the two certification procedures, the machine's julia
    @test occursin("certify_parameter_recovery", text)
    @test occursin("certify_calibration_transfer", text)
    @test occursin("--startup-file=no", text)

    # the evidence format and where it lands in the vault
    @test occursin("twin-certification", text)      # the evidence note's type
    @test occursin("model-of-lab", text)            # the vault's record home
    @test occursin("frontmatter", text)

    # the human promotion: seed → validated is never a code change
    @test occursin("seed", text) && occursin("validated", text)
    @test occursin("human", text)

    # rehearsal evidence is marked
    @test occursin("rehearsal", text)

    # CI runs the machinery on committed fixtures only
    @test occursin("fixture", text)
end

@testitem "CI certification machinery reads fixtures only — no live vault paths" begin
    using Strumento
    # The certification machinery and the whole test corpus must be runnable
    # against COMMITTED fixtures: no test or extension source may carry a live
    # vault path. (The base twin core is path-parameterized by design — the
    # caller passes the record path; its docstrings describe the vault's
    # layout convention, which is documentation, not a read. The scan covers
    # the test corpus and the extension machinery — where reads would happen.)
    # The scan pattern strings are assembled at runtime so this item does not
    # itself contain them.
    pats = [join(["~", "/.amico"]),
            join([".amico", "/vaults"]),
            join(["model", "-of-lab"])]
    root = pkgdir(Strumento)
    scanned = 0
    violations = String[]
    for dir in ("ext", "test")
        for (rootdir, dirs, files) in walkdir(joinpath(root, dir))
            for f in files
                endswith(f, ".jl") || continue
                path = joinpath(rootdir, f)
                text = read(path, String)
                scanned += 1
                for p in pats
                    occursin(p, text) &&
                        push!(violations, relpath(path, root) * " contains a live vault path")
                end
            end
        end
    end
    @test isempty(violations)
    @test scanned > 20    # the scan actually covered the corpus
end

@testitem "the certification surface rides the Piccolo extension; the base package gains nothing" begin
    using Strumento
    # UNguarded (like the soc interface and bosonic-family items): the base
    # placement pin must hold in EVERY load configuration — the certification
    # names must never exist on the base module, extension or not.
    @test !isdefined(Strumento, :certify_parameter_recovery)
    @test !isdefined(Strumento, :certify_calibration_transfer)
    @test !isdefined(Strumento, :calibration_transfer_metric)
    @test !isdefined(Strumento, :BosonicCertDesign)
    if Base.identify_package("Piccolo") === nothing
        @info "skipping the extension side: no Piccolo in this environment"
        @test true
    else
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        @test ext !== nothing
        @test isdefined(ext, :certify_parameter_recovery)
        @test isdefined(ext, :certify_calibration_transfer)
        @test isdefined(ext, :calibration_transfer_metric)
        @test isdefined(ext, :BosonicCertDesign)
        @test isdefined(ext, :BosonicCalibration)
        @test isdefined(ext, :estimate_readout_confusion)
    end
end