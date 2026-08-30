---
type: device-twin
id: synthetic-transmon
family: transmon
platform: transmon
status: seed
route_intent: team
date: 2026-08-30
parameters:
  omega_GHz: 4.7           # qubit frequency
  delta_GHz: 0.18          # anharmonicity
  levels: 3
  drive_max_GHz: 0.06
noise:
  T1_us: {value: 65.0, estimate: true, note: "synthetic; typical-of-class"}
  T2_us: {value: 45.0, estimate: true, note: "synthetic; T2 < 2*T1"}
  readout_confusion: {value: [[0.98, 0.02], [0.04, 0.96]], estimate: true}
drift_priors:
  omega_GHz:
    process: telegraph     # TLS signature: discrete jumps on top of OU wander
    gamma_up_per_day: 1.5
    gamma_down_per_day: 2.5
    amplitude_rel: 4.0e-5  # ~190 kHz jumps at 4.7 GHz
    also_ou: {sigma_rel: 1.5e-5, tau_days: 5}
  delta_GHz:
    process: ou
    sigma_rel: 0.004
    tau_days: 11
provenance:
  source: "Synthetic fixture — transmon seed-family schema shape (Strumento twin-core tests)"
  measured: 2026-08-28
  note: "All values synthetic; schema mirrors the vault model-of-lab transmon record — the TLS-drift rehearsal family."
tags: [device-twin, transmon, fixture]
---

# Synthetic transmon twin — test fixture

A test fixture in the transmon seed family's shape: the reference single
transmon with random-telegraph ω jumps (the TLS signature) on top of OU wander.
All values synthetic.
