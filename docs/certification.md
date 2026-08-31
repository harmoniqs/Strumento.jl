# Certification runbook — the twin program's promotion gate

This is the recipe for running the M2 certification gates against the **real
vault record** — the campaign act that turns a `seed` record into promotion
*evidence*. The machinery itself lives in the Piccolo extension
(`ext/certification.jl`, reached via `Base.get_extension(Strumento,
:StrumentoPiccoloExt)`) and is exercised by CI on committed fixtures only.

**The two gates** (both seeded end-to-end — a result replays exactly from its
seed):

1. **Parameter recovery** — `certify_parameter_recovery(record_path; seed, …)`:
   the comb sweep (χ, the Kerr-free photon-number spacing) and the Ramsey
   ladder sweep (K_c, the anharmonic ladder under the contrast dip), measured
   through the soc face and fit by the Julia-side physics-model spectral fit.
   The recovery tolerance is *derived* (5·σ of the fit's own observed
   information — see the docstrings; never hand-picked), and the result's
   `agrees_with_record` flag is the promotion-relevant verdict.
2. **Calibration transfer** — `certify_calibration_transfer(record_path; …)`:
   twin A's calibration (fitted parameters plus the *measured* readout
   confusion) applied to same-class twin B must beat B's uncalibrated
   baseline (raw record defaults) on `calibration_transfer_metric` — the mean
   total-variation distance between the belief-predicted and the actual
   outcome distributions over the pinned probe set.

## 1. The environment

A scratch environment with this package dev'd and Piccolo added (once):

```bash
julia --startup-file=no -e 'using Pkg
    Pkg.activate("/tmp/strumento-cert")
    Pkg.develop(path = "/path/to/Strumento.jl")   # the campaign's checkout
    Pkg.add("Piccolo")
    Pkg.instantiate()'
```

## 2. The record

The vault record — the twin program's documents under `model-of-lab/`. Resolve
the mount path first (never hard-code it here; the vault governs):

```bash
amico vault resolve model-of-lab/<record-id>.md
```

The record must carry `family: bosonic` (the certification design is the
bosonic family's) and the wrapped noise entries the family factory requires
(`T1_q_us`, `kappa_c_per_us`, `readout_confusion`).

## 3. The commands

Run both gates with pinned seeds and the default design (the same design CI
exercises), printing the results for the evidence note:

```bash
julia --startup-file=no --project=/tmp/strumento-cert -e '
    using Strumento, Piccolo
    ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)

    record = "<the resolved vault record path>"
    seed_a = 0xC0FFEE          # pin and record these — replay is exact
    seed_b = 0xBEEF

    # Gate 1: parameter recovery. The REAL record certifies AS-IS — no
    # perturbation (the perturbation is the twin-rehearsal knob that hides a
    # truth; against the real record the question is whether the record's
    # own values agree with what the device family model fits).
    r = ext.certify_parameter_recovery(record; seed = seed_a)
    println("chi fitted   = ", r.chi_kHz,   " ± ", r.chi_sigma_kHz,
            "  (tol ", r.chi_tolerance_kHz, ", chi2/dof ", r.chi_chi2_dof, ")")
    println("K_c fitted   = ", r.K_c_kHz,   " ± ", r.K_c_sigma_kHz,
            "  (tol ", r.K_c_tolerance_kHz, ", chi2/dof ", r.K_c_chi2_dof, ")")
    println("agrees_with_record = ", r.agrees_with_record)
    println("provenance   = ", r.provenance)

    # Gate 2: calibration transfer across same-class twins (both truth-perturbed
    # at class-realistic scales — the rehearsal of the transfer property).
    t = ext.certify_calibration_transfer(record;
        seed_a = seed_a, perturbation_a = Dict(:chi_kHz => 8.0, :K_c_kHz => -2.0),
        seed_b = seed_b, perturbation_b = Dict(:chi_kHz => 10.5, :K_c_kHz => -2.8))
    println("transfer: baseline ", t.metric_baseline,
            " -> calibrated ", t.metric_calibrated, "  improved = ", t.improved)
'
```

The **promotion evidence** is gate 1 run *unperturbed*: `agrees_with_record =
true` means the record's stated parameters are within the derived tolerances
of what the measurements support. A `false` means the record's values have
drifted from its own device class — recalibrate the record's parameters (a
vault edit, with provenance) or do not promote.

## 4. The evidence

A vault note, in Markdown with YAML frontmatter, written next to the record:

`model-of-lab/certifications/<record-id>/<date>-m2-certification.md`

```markdown
---
type: twin-certification
record: model-of-lab/<record-id>.md
date: YYYY-MM-DD
campaign: strumento-twins-bringup
milestone: M2
seeds: {recovery: 0xC0FFEE, transfer_a: 0xC0FFEE, transfer_b: 0xBEEF}
evidence_class: twin-rehearsal
tags: [twin-certification, bosonic, m2]
---
# M2 certification — <record-id>

## Parameter recovery
- chi_kHz: fitted <χ̂> ± <σ>, tolerance <5σ>, chi2/dof <…>
- K_c_kHz: fitted <K̂_c> ± <σ>, tolerance <5σ> (incl. χ̂ propagation κ = <κ>), chi2/dof <…>
- agrees_with_record: <true|false>
- tooling: <Strumento version, Julia version, Piccolo version, checkout SHA>

## Calibration transfer
- metric_baseline: <…>   metric_calibrated: <…>   improved: <true|false>
- A's calibration: chi_kHz <…>, K_c_kHz <…>, confusion <matrix>

## Rehearsal marking
Twin-rehearsal evidence: these results are measurements of a DIGITAL TWIN
built from the record, not of a device. They certify the twin program's
machinery (the fit path, the derived tolerances, the transfer property) and
the record's internal consistency — they never claim device status.
```

The frontmatter's `evidence_class: twin-rehearsal` is mandatory: twin-derived
results never claim device status, and the note must say so in its body too.

## 5. The promotion

The record's status flip — `seed` → `validated` — is a **human promotion**:

- the director runs the gates, writes the evidence note, and requests the
  promotion with the evidence linked;
- a **human** edits the record's frontmatter (`status: validated`) and adds a
  provenance entry pointing at the evidence note (`validated: <date>, per
  model-of-lab/certifications/<record-id>/<date>-m2-certification.md`);
- the promotion is never a code change: records never become code. No PR, no
  fixture edit, no constant is moved from the vault into the repo by a
  promotion.

## 6. CI boundary

CI exercises the machinery on **committed fixtures only** — the suite's
certification testitems run against `test/fixtures/twins/*.md`, and the
fixtures-only audit testitem enforces that no test or extension source carries
a live vault path. The real-record run above is a campaign act whose evidence
lands in the vault, not in CI.

## 7. Replay (a failed certification reproduces exactly)

Every gate is a pure function of (record, seed, design). To reproduce or
verify a certification run, re-run with the same seed — the result is
bit-exact. The cross-process form follows the TwinSoc replay ritual:

```bash
julia --startup-file=no --project=/tmp/strumento-cert \
    test/configurations/cert_replay_check.jl <repo-path> > run1.txt
julia --startup-file=no --project=/tmp/strumento-cert \
    test/configurations/cert_replay_check.jl <repo-path> > run2.txt
diff run1.txt run2.txt   # must be empty
```