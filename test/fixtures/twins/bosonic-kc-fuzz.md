---
type: device-twin
id: synthetic-bosonic-kc-fuzz
family: bosonic
platform: bosonic
status: seed
route_intent: team
date: 2026-08-31
parameters:
  chi_kHz: -298.4          # dispersive shift χ/2π (synthetic)
  K_q_GHz: -0.161          # transmon anharmonicity/2π
  K_c_kHz: -15.87          # cavity Kerr/2π — the float-fuzz value (see note)
  chi_p_kHz: 0.0           # χ′ — unmeasured; held at 0
  chi_ef_kHz: 0.0          # ef-path dispersive shift — unmeasured
  N_transmon: 2            # qubit levels in the model
  N_fock: 12               # cavity Fock cutoff
noise:
  T1_q_us: {value: 120.0, estimate: true, note: "synthetic; typical-of-class placeholder"}
  kappa_c_per_us: {value: 0.0008, estimate: true, note: "synthetic; κ placeholder"}
  readout_confusion: {value: [[0.97, 0.03], [0.06, 0.94]], estimate: true, note: "synthetic placeholder matrix"}
drift_priors:
  chi_kHz:
    process: ou
    sigma_rel: 0.008
    tau_days: 10
  K_c_kHz:
    process: ou
    sigma_rel: 0.02
    tau_days: 17
provenance:
  source: "Synthetic fixture — K_c grid float-fuzz regression (certification model cache)"
  measured: 2026-08-31
  note: "All values synthetic; schema mirrors the committed bosonic seed-family fixture. K_c = −15.87 kHz is the value class from the real-record certification run: the default design margin (K_c ± 8.0 kHz) puts the bracket's upper edge at −7.869999999999999 in Float64, and the fit grid's lo:step:hi construction dropped the last node. Regression fixture for the model-cache grid coverage."
tags: [device-twin, bosonic, fixture]
---

# Synthetic bosonic twin — K_c float-fuzz regression fixture

A test fixture in the bosonic seed family's shape, identical to the committed
`synthetic-bosonic` fixture except for the cavity Kerr: **K_c = −15.87 kHz**,
the value class the real-record certification run carried. With the default
design margin (halfbracket 8.0 kHz, grid step 2.0 kHz) the K_c Ramsey-ladder
bracket is [−23.87, −7.869999999999999] in Float64 — length
15.999999999999998 — and a `lo:step:hi` grid stops one node short of the
bracket's upper edge. The synthetic CI fixtures (K_c = −12.3 → an exact 16.0
bracket) never tripped that fuzz; the real record did. This fixture exists so
the regression testitem can drive `certify_parameter_recovery` through the
fuzz-producing bracket without touching any live vault record.
