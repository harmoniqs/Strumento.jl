# Strumento.jl

The Julia face of the [**strumento**](https://github.com/harmoniqs/strumento) QICK
tProc-v2 experiment framework, and [Intonato](https://github.com/harmoniqs/Intonato.jl)'s
hardware backend for closed-loop quantum optimal control (QILC).

> Renamed from `IntonatoQICK.jl` on Jul 23, 2026 (the old repo is archived). The package's
> job narrowed to "hand a solved pulse to `strumento`, get measurements back," so the name
> follows: it is the Julia binding to `strumento`, not an Intonato-specific QICK translator.

## One source of truth (why a *face*, not a port)

The device model, the pulse IR, the compiler, and `AveragerProgramV2` assembly all live in
the Python `strumento` package. Strumento.jl is a **binding**, not a reimplementation — there
is one authority for the pulse to program to acquire path, in Python, and two idiomatic front
doors (Python and Julia) onto it. On a real board, Julia never assembles a program: it hands
the solved pulse to `strumento.from_solution` over
[PythonCall](https://github.com/JuliaPy/PythonCall.jl) and reads measurements back.

## What it provides

- **`StrumentoBackend <: AbstractHardwareBackend`** — the seam Intonato's `PulseTuningProblem`
  chassis consumes (`upload_pulse!` / `trigger!` / `readout` / `sample_rate`) over an
  abstract `AbstractSoc`.
- **`MockSoc`** — a pure-Julia "board" that translates the pulse in Julia and rolls it through
  a known `QuantumSystem`, emitting synthetic IQ. The whole QILC to board loop runs and is
  tested with **no Python and no hardware**.
- **`StrumentoSoc`** — the real board, reached by **delegating to Python `strumento`** over
  PythonCall (lazy import; only on a board). `execute!` hands the pulse to
  `from_solution` then `StrumentoProgram` then `acquire` then `reduce`; the exact device
  wiring / drive-map / reduce conventions are finalized with the QICK collaboration on hardware.
- **`QickChannelMap`** (device policy the mock uses: drive to gen-channel/carrier/IQ) and a
  caller-supplied discriminator (IQ to state).
- **`StrumentoExperiment(backend; measurement_model)`** to an Intonato `HardwareExperiment` you
  drop straight into `PulseTuningProblem`.

## The division of labour

```
Intonato (Julia)   ->  AbstractPulse / solution      (QILC chassis)
  Strumento.jl     ->  StrumentoBackend / StrumentoExperiment  <- this package (the face)
    StrumentoSoc   ->  PythonCall -> Python strumento  (from_solution -> compile -> acquire -> reduce)
      strumento    ->  device model . pulse IR . compiler . program     (the authority)
        board
```

The pure-Julia `MockSoc` short-circuits the bottom rungs with a `QuantumSystem` rollout, so the
chassis-to-backend contract is exercised board-free.

## Usage (mock)

```julia
using Strumento

# True device dynamics the "board" has (here with a model mismatch):
sys_true = QuantumSystem(1.1 * σz, [σx], [1.0])
soc = MockSoc(sys_true, ψ_init, ψ_goal; dac_rate = 80.0)

map   = QickChannelMap([QickGenChannel(0, 5e9; i_drive = 1)]; n_drives = 1)
model = MeasurementModel(:ψ̃, [populations], [N])
qexp  = StrumentoExperiment(StrumentoBackend(soc, map, [N]); measurement_model = model)

# Plug into Intonato's QILC chassis (a concrete tuning strategy is supplied separately):
ptp = PulseTuningProblem(qcp, qexp, model; R_tr = (u = 0.1,), Q_meas = 10.0)
solve!(ptp; max_iter = 10)
```

On a real board, swap `MockSoc` for a `StrumentoSoc` pointed at a `strumento` device instance:

```julia
soc = StrumentoSoc("devices/multimode_demo/device.yaml";
                   drive_map = [(1, "qubit", "drive", 4000.0)],   # (drive index, line, role, carrier MHz)
                   dac_rate = 9.6e9, adc_rate = 2.4576e9, board = pyqicksoc)
```

## Data-provenance note

Intonato's `ExperimentRecord` logging is **not** triggered inside the QILC chassis loop today
(the chassis calls `run_experiment` with no logger, and the record's `raw` field is hardcoded
`nothing`). So `StrumentoBackend` stashes the most recent raw IQ in `backend.last_raw`, and a
*manual* `run_experiment(qexp, pulse; logger=…)` logs measurement-level records. Full
raw-IQ-into-record provenance during closed-loop runs is a planned Intonato enhancement.

## Status

Interface-complete with a tested mock loop (38 tests). The real-board `StrumentoSoc`
delegation path is validated with the QICK collaboration on hardware (it needs the Python
`strumento` package + a board and is not exercised in CI). Calibration routines and multi-board
orchestration are out of scope for v0.
