"""
    Strumento

The Julia face of the Python **strumento** QICK tProc-v2 experiment framework, and
Intonato's hardware backend for closed-loop optimal control (QILC).

**One source of truth (option a).** The device model, pulse IR, compiler, and program
assembly live in Python `strumento`; this package is a *binding*, not a reimplementation.
The real-board path (`StrumentoSoc`) hands a solved pulse to Python `strumento` over
PythonCall (`from_solution → compile → acquire → reduce`) — Julia never assembles an
`AveragerProgramV2` itself. A pure-Julia `MockSoc` rolls the pulse through a `QuantumSystem`
so the whole QILC→board loop runs and is tested with no Python and no hardware.

The seam Intonato plugs into is `StrumentoBackend <: AbstractHardwareBackend`, wrapped as a
`HardwareExperiment` by `StrumentoExperiment`.
"""
module Strumento

using Reexport
@reexport using Intonato

# Intonato reexports Piccolo + NamedTrajectories, so AbstractPulse, sample,
# QuantumSystem, KetTrajectory, SimulatedExperiment, MeasurementModel,
# Measurement, run_experiment, AbstractHardwareBackend, HardwareExperiment, …
# are all in scope here.
using Intonato
# The AbstractHardwareBackend contract — upload_pulse! / trigger! / readout /
# sample_rate — is declared AND exported by Intonato; Strumento extends those
# generics for StrumentoBackend (backend.jl) and reexports them above. The
# explicit `import` is load-bearing: `using` alone lets a method definition
# SILENTLY shadow the imported generic with a fresh local function object (the
# accident this seam used to work by), while `import` makes backend.jl's methods
# attach to Intonato's own generics — the contract Intonato documents for
# backends ("a backend `import`s and extends them").
import Intonato: upload_pulse!, trigger!, readout, sample_rate
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
include("backend.jl")
include("strumento_soc.jl")

# ──── Experiment factory ─────────────────────────────────────────────────────
include("experiment.jl")

# ──── Integration tests (mock QILC→QICK loop) ────────────────────────────────
include("integration_test.jl")

# ──── Exports ────────────────────────────────────────────────────────────────
export AbstractSoc, MockSoc, StrumentoSoc
export execute!, load_envelope!, play_program!, acquire, dac_rate, adc_rate
export QickChannelMap, QickGenChannel
export pulse_to_envelopes, QickProgram
export iq_to_measurements
export StrumentoBackend
export StrumentoExperiment

end # module Strumento
