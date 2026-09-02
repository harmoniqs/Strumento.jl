"""
    Strumento

The Julia face of the Python **strumento** QICK tProc-v2 experiment framework — the
standalone substrate layer (the soc registry: real/mock/twin boards).

**One source of truth (option a).** The device model, pulse IR, compiler, and program
assembly live in Python `strumento`; this package is a *binding*, not a reimplementation.
The real-board path (`StrumentoSoc`, the PythonCall extension) hands a solved pulse to
Python `strumento` over PythonCall (`from_solution → compile → acquire → reduce`) —
Julia never assembles an `AveragerProgramV2` itself. A pure-Julia `MockSoc` (the
Piccolo extension) rolls the pulse through a `QuantumSystem` (Piccolo-native
propagation) so the whole board-free mock path runs and is tested with no Python and
no hardware.

**The substrate stands alone (v0.2):** the dependency edge on Intonato (the loop
chassis ABOVE this layer) is inverted — this package no longer depends on or reexports
Intonato. The closed-loop seam — `StrumentoBackend` / `StrumentoExperiment` —
relocated to Intonato (≥ its next release, which depends on this package); the
instrument layer no longer knows the calibration loop.

**Dependency-light by construction (issue #16):** the base package carries only the
contract surface — the `AbstractSoc` abstraction and its verbs, the `QickChannelMap`
device policy, readout conversion, the `QickProgram` translation record — plus the
twin core, over stdlib and light deps only. Piccolo and PythonCall are package
*extensions* (weakdeps): the Piccolo-triggered extension (`StrumentoPiccoloExt`)
carries the mock soc and the pulse → QICK-envelope translation; the
PythonCall-triggered extension (`StrumentoPythonCallExt`) carries the Python
delegation soc. Function verbs the base declares duck-typed (`pulse_to_envelopes`,
the pulse-sampling seam) gain their typed Piccolo methods when the extension loads;
extension-defined *types* (`MockSoc`, `StrumentoSoc`) are reachable through
`Base.get_extension(Strumento, …)` once loaded. Consumers that never load the
trigger deps get the light package by construction — a sysimage, the board, a
twin-light consumer.

**Digital twins (absorbed from harmoniqs/Sosia.jl, spec-20260803-043304):** the
twin core — drift processes (OU with the exact Gaussian transition, ramp, random
telegraph, scheduled jumps; `DriftPlan` composition), the vault twin-record loader
(`TwinRecord` / `load_record` / `RecordError`), and the `DigitalTwin` truth/belief/
record contract (`instantiate`, `believed`, `advance!`, `calibrate!`). Twin records
are vault documents: code loads records, it never owns parameters.
"""
module Strumento

using TestItems

# ──── SoC abstraction ────────────────────────────────────────────────────────
include("soc.jl")
include("channel_map.jl")

# ──── Pulse / readout translation ────────────────────────────────────────────
# The QickProgram data contract + the duck-typed translation verb live in base;
# the AbstractPulse sampling method rides the Piccolo extension.
include("translate.jl")
include("readout.jl")

# ──── Digital twins (absorbed from harmoniqs/Sosia.jl) ──────────────────────
# Drift processes, the vault twin-record loader, and the truth/belief/record
# contract (vault spec-20260803-043304-digital-twins-sosia). Twin records are
# vault documents: code loads records, it never owns parameters.
include("twin_drift.jl")
include("twin_records.jl")
include("twin.jl")

# ──── Exports ────────────────────────────────────────────────────────────────
# Base carries the soc contract, the channel map, the readout + translation
# data contracts, and the twin core — every name below is loadable WITHOUT any
# trigger dep (the translation verb errors actionably until the Piccolo
# extension adds its typed method). The extension-defined TYPES — MockSoc
# (Piccolo extension), StrumentoSoc (PythonCall extension) — are reached
# through Base.get_extension once the trigger loads: extension exports do not
# surface on the parent module.
export AbstractSoc
export execute!, load_envelope!, play_program!, acquire, dac_rate, adc_rate
export QickChannelMap, QickGenChannel
export TwinWiringMap, TwinGenWiring, wiring_for
export pulse_to_envelopes, QickProgram
export iq_to_measurements, Measurement

end # module Strumento