---
type: device-twin
id: synthetic-atoms
family: atoms
platform: rydberg
status: seed
route_intent: team
date: 2026-08-30
parameters:
  species: Rb87
  C6_MHz_um6: 542000.0     # ×2π MHz·µm⁶ (synthetic)
  distance_um: 6.4
  omega_max_MHz: 12.5      # ×2π
  delta_max_MHz: 98.0      # ×2π
  omega_slew_MHz_per_us: 210.0
  delta_slew_MHz_per_us: 1600.0
  min_atom_distance_um: 4.5
  clock_ns: 4.0
noise:
  tau_R_us: {value: 75.0, estimate: true, note: "synthetic; gate-zone figure placeholder"}
  dephasing_us: {value: 40.0, estimate: true, note: "synthetic; Doppler + laser phase"}
  atom_loss_per_shot: {value: 0.003, estimate: true}
drift_priors:
  omega_max_MHz:
    process: ou            # beam alignment / power wander
    sigma_rel: 0.008
    tau_days: 3
  detuning_offset_MHz:
    process: ramp          # slow alignment drift between relocks
    rate_MHz_per_day: 0.35
  atom_positions_um:
    process: jump          # register reloads / loss events
    note: "positions re-drawn with loss probability per jump event"
provenance:
  source: "Synthetic fixture — atoms seed-family schema shape (Strumento twin-core tests)"
  measured: 2026-08-28
  note: "All values synthetic; schema mirrors the vault model-of-lab atoms record (string parameter included)."
tags: [device-twin, atoms, rydberg, fixture]
---

# Synthetic neutral-atoms twin — test fixture

A test fixture in the atoms seed family's shape: ⁸⁷Rb register with global
drive, detuning ramp between relocks, atom loss as scheduled jump events. The
string parameter (`species`) is deliberate — the loader must keep it in the
record while the twin's numeric truth ignores it. All values synthetic.
