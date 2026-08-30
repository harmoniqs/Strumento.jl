---
type: device-twin
id: synthetic-spin
family: spin
platform: spin
status: seed
route_intent: team
date: 2026-08-30
parameters:
  delta_MHz: 45.0          # ×2π — charge-noise detuning scale
  J_max_MHz: 95.0          # ×2π — max exchange
  omega_max_MHz: 5.5       # ×2π — EDSR Rabi ceiling
  E_Z1_GHz: 17.9           # ×2π — Zeeman qubit 1
  E_Z2_GHz: 17.95          # ×2π — Zeeman qubit 2 (50 MHz split)
noise:
  T2_star_us: {value: 0.4, estimate: false, note: "synthetic canonical-style value"}
  T1_us: {value: 180.0, estimate: false, note: "same source"}
  gamma_cross_rel: {value: 0.08, estimate: false, note: "cross-correlated dephasing ratio"}
drift_priors:
  delta_MHz:
    process: ou            # charge noise around the operating point
    sigma_rel: 0.04
    tau_days: 1
  J_max_MHz:
    process: ou            # gate-voltage dependence drift
    sigma_rel: 0.008
    tau_days: 7
provenance:
  source: "Synthetic fixture — spin seed-family schema shape (Strumento twin-core tests)"
  measured: 2026-08-28
  note: "All values synthetic; schema mirrors the vault model-of-lab spin record."
tags: [device-twin, spin, fixture]
---

# Synthetic spin-pair twin — test fixture

A test fixture in the spin seed family's shape: two-qubit exchange/EDSR pair
with quasi-static charge noise (slow-OU limit) and a 50 MHz Zeeman split. All
values synthetic.
