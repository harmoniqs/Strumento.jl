# Strumento.jl

The Julia face of the [**strumento**](https://github.com/harmoniqs/strumento) QICK
tProc-v2 experiment framework — the standalone substrate layer (the soc registry:
real/mock/twin boards).

> Renamed from `IntonatoQICK.jl` on Jul 23, 2026 (the old repo is archived). The package's
> job narrowed to "hand a solved pulse to `strumento`, get measurements back," so the name
> follows: it is the Julia binding to `strumento`, not an Intonato-specific QICK translator.
> Since v0.2 (issue #14) the dependency edge is inverted: this package stands alone on
> [Piccolo](https://github.com/harmoniqs/Piccolo.jl) and no longer depends on or reexports
> Intonato — the closed-loop seam (`StrumentoBackend` / `StrumentoExperiment`) relocated to
> [Intonato](https://github.com/harmoniqs/Intonato.jl) (≥ its next release, which depends on
> this package).

## One source of truth (why a *face*, not a port)

The device model, the pulse IR, the compiler, and `AveragerProgramV2` assembly all live in
the Python `strumento` package. Strumento.jl is a **binding**, not a reimplementation — there
is one authority for the pulse to program to acquire path, in Python, and two idiomatic front
doors (Python and Julia) onto it. On a real board, Julia never assembles a program: it hands
the solved pulse to `strumento.from_solution` over
[PythonCall](https://github.com/JuliaPy/PythonCall.jl) and reads measurements back.

## What it provides

- **`AbstractSoc`** and its verbs (`execute!`, `dac_rate`, `adc_rate`) — the board-controller
  abstraction every soc implements.
- **`MockSoc`** — a pure-Julia "board" that translates the pulse in Julia and rolls it
  through a known `QuantumSystem` (Piccolo-native propagation), emitting synthetic IQ. The
  mock path runs and is tested with **no Python and no hardware**.
- **`StrumentoSoc`** — the real board, reached by **delegating to Python `strumento`** over
  PythonCall (lazy import; only on a board). `execute!` hands the pulse to
  `from_solution` then `StrumentoProgram` then `acquire` then `reduce`; the exact device
  wiring / drive-map / reduce conventions are finalized with the QICK collaboration on hardware.
- **`QickChannelMap`** (device policy the mock uses: drive to gen-channel/carrier/IQ),
  **`pulse_to_envelopes`** (pulse → QICK-shaped envelopes, with the 16,384-sample
  envelope-memory cap), and **`iq_to_measurements`** (IQ blob → `Measurement` via a
  caller-supplied discriminator) — the substrate-side translation and readout surface.

## The division of labour

```
Intonato (Julia)   ->  QILC chassis + StrumentoBackend / StrumentoExperiment  (the loop)
  Strumento.jl     ->  AbstractSoc registry: MockSoc / StrumentoSoc           <- this package (the substrate)
    StrumentoSoc   ->  PythonCall -> Python strumento  (from_solution -> compile -> acquire -> reduce)
      strumento    ->  device model . pulse IR . compiler . program     (the authority)
        board
```

Intonato (the loop chassis) sits **above** this package and depends on it; the substrate is
loadable without the control stack. The pure-Julia `MockSoc` short-circuits the bottom rungs
with a `QuantumSystem` rollout (Piccolo `rollout`), so the soc contract is exercised
board-free.

## Usage (mock)

```julia
using Strumento

# True device dynamics the "board" has (here with a model mismatch):
sys_true = QuantumSystem(1.1 * σz, [σx], [1.0])
soc = MockSoc(sys_true, ψ_init, ψ_goal; dac_rate = 80.0)

map = QickChannelMap([QickGenChannel(0, 5e9; i_drive = 1)]; n_drives = 1)

# Translate + play + read: raw per-knot IQ blobs (default forward model:
# populations, packed complex — invert with `real`).
raw = execute!(soc, pulse, map, [N])

# Or convert to measurements with a discriminator:
ms = iq_to_measurements(raw, b -> real.(b), [N])
```

Closing the loop (upload/trigger/readout through `StrumentoBackend`, wrapping the soc as a
`HardwareExperiment` for `PulseTuningProblem`) is the Intonato-side seam — see Intonato ≥
its next release.

On a real board, swap `MockSoc` for a `StrumentoSoc` pointed at a `strumento` device instance:

```julia
soc = StrumentoSoc("devices/multimode_demo/device.yaml";
                   drive_map = [(1, "qubit", "drive", 4000.0)],   # (drive index, line, role, carrier MHz)
                   dac_rate = 9.6e9, adc_rate = 2.4576e9, board = pyqicksoc)
```

## Data-provenance note

`StrumentoBackend`'s `last_raw` stash and the `ExperimentRecord` logging discussion moved
with the seam to Intonato (its QILC chassis calls `run_experiment` with no logger today;
full raw-IQ-into-record provenance during closed-loop runs is a planned Intonato
enhancement).

## Status

Interface-complete with a tested pure-Julia mock suite. The real-board `StrumentoSoc`
delegation path is validated with the QICK collaboration on hardware (it needs the Python
`strumento` package + a board and is not exercised in CI). Calibration routines, multi-board
orchestration, and the twin core are out of scope for v0.2; the weakdeps/extensions split
(PythonCall out of the hard deps) is a planned follow-up.
