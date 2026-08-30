---
type: device-twin
id: synthetic-bosonic
family: bosonic
platform: bosonic
status: seed
route_intent: team
date: 2026-08-30
parameters:
  chi_kHz: -298.4          # dispersive shift χ/2π (synthetic)
  K_q_GHz: -0.161          # transmon anharmonicity/2π
  K_c_kHz: -12.3           # cavity Kerr/2π
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
  source: "Synthetic fixture — bosonic seed-family schema shape (Strumento twin-core tests)"
  measured: 2026-08-28
  note: "All values synthetic; schema mirrors the vault model-of-lab bosonic record, no device behind them."
tags: [device-twin, bosonic, fixture]
---

# Synthetic bosonic twin — test fixture

A test fixture in the bosonic seed family's shape: transmon ancilla dispersively
coupled to a storage cavity, GKP rehearsal as the target campaign. Every value
is synthetic — this record exists to pin the loader's schema, never to model a
device.
