---
type: device-twin
id: synthetic-toy
family: toy
platform: toy
status: seed
route_intent: team
date: 2026-08-30
parameters:
  omega: 1.0               # toy family: the σz drift coefficient (abstract units)
  drive_bound: 1.0          # toy family: the σx drive bound (symmetric)
noise:
  readout_confusion: {value: [[0.98, 0.02], [0.04, 0.96]], estimate: true, note: "synthetic; asymmetric 2-level readout — 2% spurious |1⟩, 4% spurious |0⟩"}
drift_priors:
  omega:
    process: ou             # toy family drift prior: OU wander on the drift coefficient
    sigma_rel: 0.05
    tau_days: 10
provenance:
  source: "Synthetic fixture — toy family schema shape (Strumento TwinSoc tests)"
  measured: 2026-08-28
  note: "All values synthetic; the toy family pins the TwinSoc family/response seam, never models a device."
tags: [device-twin, toy, fixture]
---

# Synthetic toy twin — TwinSoc test fixture

A test fixture for the toy family: a two-level abstract system whose
`QuantumSystem` is built straight from the record's truth parameters (the σz
coefficient `omega`, the σx drive bound `drive_bound`) with an asymmetric
readout-confusion matrix. It exists to pin the TwinSoc family seam, response
model, and drift wiring — never to model a device.
