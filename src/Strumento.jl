"""
    Strumento

The Julia face of the Python **strumento** QICK tProc-v2 experiment framework — the
standalone substrate layer (the soc registry: real/mock/twin boards).

**One source of truth (option a).** The device model, pulse IR, compiler, and program
assembly live in Python `strumento`; this package is a *binding*, not a reimplementation.
The real-board path (`StrumentoSoc`) hands a solved pulse to Python `strumento` over
PythonCall (`from_solution → compile → acquire → reduce`) — Julia never assembles an
`AveragerProgramV2` itself. A pure-Julia `MockSoc` rolls the pulse through a
`QuantumSystem` (Piccolo-native propagation) so the whole board-free mock path runs and
is tested with no Python and no hardware.

**The substrate stands alone (v0.2):** the dependency edge on Intonato (the loop
chassis ABOVE this layer) is inverted — this package no longer depends on or reexports
Intonato. Piccolo is the direct physics dependency (the lingua franca: `QuantumSystem`
rollouts, `AbstractPulse` translation, reexported here). The closed-loop seam —
`StrumentoBackend` / `StrumentoExperiment` — relocated to Intonato (≥ its next
release, which depends on this package); the instrument layer no longer knows the
calibration loop.
"""
module Strumento

using Reexport
@reexport using Piccolo
# Piccolo is the substrate's physics lingua franca — previously reached through
# Intonato's reexports, now a direct public dependency. QuantumSystem,
# AbstractPulse, LinearSplinePulse, sample, rollout, KetTrajectory, ket_to_iso, …
# are all in scope here (and reexported for `using Strumento` consumers).
using LinearAlgebra
using PythonCall
using TestItems

# ──── SoC abstraction ────────────────────────────────────────────────────────
include("soc.jl")
include("channel_map.jl")

# ──── Pulse / readout translation ────────────────────────────────────────────
include("translate.jl")
include("readout.jl")

# ──── Backends ───────────────────────────────────────────────────────────────
include("mock_soc.jl")
include("strumento_soc.jl")

# ──── Digital twins (absorbed from harmoniqs/Sosia.jl) ──────────────────────
# Drift processes, the vault twin-record loader, and the truth/belief/record
# contract (vault spec-20260803-043304-digital-twins-sosia). Twin records are
# vault documents: code loads records, it never owns parameters.
include("twin_drift.jl")
include("twin_records.jl")

# ──── Exports ────────────────────────────────────────────────────────────────
export AbstractSoc, MockSoc, StrumentoSoc
export execute!, load_envelope!, play_program!, acquire, dac_rate, adc_rate
export QickChannelMap, QickGenChannel
export pulse_to_envelopes, QickProgram
export iq_to_measurements, Measurement

end # module Strumento
