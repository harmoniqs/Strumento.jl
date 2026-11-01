# Strumento.jl — deprecated and archived

> [!WARNING]
> **Strumento.jl is retired.** Its soc substrate and digital-twin core moved into
> [Intonato.jl](https://github.com/harmoniqs/Intonato.jl) **0.5**, and its Python-duplicating
> layers were removed in favour of using Python [`strumento`](https://github.com/harmoniqs/strumento)
> directly. v0.4.0 is a **deprecation shim**: it depends only on Intonato, re-exports the 0.3
> base names bound to Intonato's own objects (identity, not copies), and warns once on load.
> Drop the `Strumento` dependency and use Intonato. See Intonato's
> [Migrating from Strumento.jl](https://github.com/harmoniqs/Intonato.jl#migrating-from-strumentojl)
> section.

## Migration table

| Strumento.jl 0.3 | New home (Intonato ≥ 0.5) |
|---|---|
| `AbstractSoc`, `execute!`, `load_envelope!`, `play_program!`, `acquire`, `dac_rate`, `adc_rate` | `Intonato` (same names) |
| `set_gate!`, `get_gate`, `gate_snapshot`, `DCAxis`, `DCAxisMap`, `gate_names`, `axis_for` | `Intonato` |
| `QickChannelMap`, `QickGenChannel`, `pulse_to_envelopes`, `QickProgram`, `iq_to_measurements` | `Intonato` |
| `Measurement` | `Intonato.Measurement` (one `Measurement` type) |
| `MockSoc` (via `Base.get_extension(Strumento, :StrumentoPiccoloExt)`) | `Intonato.MockSoc` |
| `DriftProcess`, `OrnsteinUhlenbeck`, `step!`, `Ramp`, `RandomTelegraph`, `JumpSchedule`, `DriftPlan`, `apply` | `Intonato.Twins` |
| `DigitalTwin`, `instantiate`, `believed`, `advance!`, `calibrate!`, `TwinRecord`, `RecordError`, `load_record` | `Intonato.Twins` |
| `TwinWiringMap`, `TwinGenWiring`, `wiring_for` | `Intonato.Twins` |
| `TwinSoc` (via `Base.get_extension(Strumento, :StrumentoPiccoloExt)`) | `Intonato.Twins.TwinSoc` |
| `read_charge_sensor`, `charge_sensor_sweep`, `bosonic_system_builder`, `bosonic_ancilla_populations`, `spin_landscape_builder`, `DoubleDotLandscape` (Piccolo extension) | `Intonato.Twins` (not re-exported by the shim) |
| `StrumentoSoc`, `StrumentoDCSource` (PythonCall extension) | `Base.get_extension(Intonato, :IntonatoPythonCallExt)` (not re-exported by the shim) |

**What the shim exports.** Every name in the first nine rows of the table is exported from
`Strumento` as the *same object* as its Intonato / `Intonato.Twins` binding
(`Strumento.MockSoc === Intonato.MockSoc`). `MockSoc` and `TwinSoc` are exported directly.
The 0.3 route through `Base.get_extension(Strumento, …)` **no longer works**, because the
shim has no extensions. It now returns `nothing`.

## Deleted layers (not migrated)

These layers duplicated the Python `strumento` stack. They are deleted and **not exported**
anywhere:

- **Twin job server** (`StrumentoJobServerExt`: `TwinJobServer`, the wire codec and client).
- **Bring-up procedures and rehearsal rig** (`StrumentoBringupExt`: `RehearsalRig`,
  `wire_address`, `stop!`, `ResonatorSweepDesign`, `comb_geometry`, `BringupSchedule`,
  `BringupJob`, `BringupResult`, `ResonatorSweepFit`, `propose`, `run_over_wire`,
  `write_back!`, `run_resonator_sweep`, `fixture_comb_jobs`, `RabiSweepDesign`, `rabi_axis`,
  `rabi_geometry`, `RabiSchedule`, `RabiJob`, `RabiResult`, `RabiSweepFit`, `propose_rabi`,
  `run_rabi_over_wire`, `run_rabi_sweep`, `fixture_rabi_job`).
- **Certification gates** (`BosonicCertDesign`, `BosonicCertResult`, `BosonicCalibration`,
  `BosonicTransferResult`, `certify_parameter_recovery`, `certify_calibration_transfer`,
  `estimate_readout_confusion`, `calibration_transfer_metric`, and `docs/certification.md`).
- **Python bring-up bridge** (`BringupBridge`, PythonCall extension).

Their ideas were re-filed against Python `strumento`:

- [harmoniqs/strumento#2](https://github.com/harmoniqs/strumento/issues/2) covers **bring-up
  orchestration** (resonator, then Rabi, then the π reference) over `SimulatorSoc` /
  `JobServerSoc`. It includes fit-recovery gates and calibration-store write-back, and it
  replaces the bring-up rig, the job-server wire, the certification gates and the bridge.
- [harmoniqs/strumento#1](https://github.com/harmoniqs/strumento/issues/1) covers
  **time-varying truth**, meaning seeded drift processes on `SimulatorSoc`. This is the twin's
  drift idea, made available on the Python simulator path. The Julia twin itself lives on in
  `Intonato.Twins`.

## Using the shim (transitional only)

```julia
using Strumento   # ┌ Warning: Strumento.jl is deprecated and archived; use Intonato ≥ 0.5 …
Strumento.MockSoc === Intonato.MockSoc   # true
```

Prefer:

```julia
using Intonato                 # soc substrate, MockSoc
using Intonato.Twins           # DigitalTwin, drift processes, TwinSoc, …
```

## License

MIT — see [LICENSE](LICENSE).
