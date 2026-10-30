"""
    Strumento

**Deprecated and archived.** Strumento.jl v0.4 is a re-export shim over
[Intonato](https://github.com/harmoniqs/Intonato.jl) ≥ 0.5, which now owns the soc
substrate (top level), the digital-twin core (`Intonato.Twins`) and the Python
delegation soc (`StrumentoSoc`, via the `IntonatoPythonCallExt` extension).

Every name exported here is the *same object* as its Intonato / `Intonato.Twins`
binding — not a copy — so code written against Strumento 0.3's base surface keeps
working while it migrates. Drop the `Strumento` dependency and use Intonato directly;
see the migration table in Intonato's README.

The 0.3 extension-defined types `MockSoc` and `TwinSoc` are exported directly (the
`Base.get_extension(Strumento, :StrumentoPiccoloExt)` reach no longer works — the
extensions are gone). The twin job server, wire client, bring-up procedures,
certification gates and Python bring-up bridge were removed, not migrated.
"""
module Strumento

# The soc substrate — the contract + verbs, the channel map, the slow-DC control
# class, the translation record + verb, readout conversion, the mock soc.
using Intonato:
    AbstractSoc,
    execute!, load_envelope!, play_program!, acquire, dac_rate, adc_rate,
    set_gate!, get_gate, gate_snapshot,
    QickChannelMap, QickGenChannel,
    DCAxis, DCAxisMap, gate_names, axis_for,
    pulse_to_envelopes, QickProgram,
    iq_to_measurements, Measurement,
    MockSoc

# The twin core, the twin wiring map, and the twin's soc face.
using Intonato.Twins:
    TwinWiringMap, TwinGenWiring, wiring_for,
    DriftProcess, OrnsteinUhlenbeck, step!,
    Ramp, RandomTelegraph, JumpSchedule, DriftPlan, apply,
    DigitalTwin, instantiate, believed, advance!, calibrate!,
    TwinRecord, RecordError, load_record,
    TwinSoc

export AbstractSoc
export execute!, load_envelope!, play_program!, acquire, dac_rate, adc_rate
export set_gate!, get_gate, gate_snapshot
export QickChannelMap, QickGenChannel
export DCAxis, DCAxisMap, gate_names, axis_for
export pulse_to_envelopes, QickProgram
export iq_to_measurements, Measurement
export MockSoc

export TwinWiringMap, TwinGenWiring, wiring_for
export DriftProcess, OrnsteinUhlenbeck, step!
export Ramp, RandomTelegraph, JumpSchedule, DriftPlan, apply
export DigitalTwin, instantiate, believed, advance!, calibrate!
export TwinRecord, RecordError, load_record
export TwinSoc

const MIGRATION_URL = "https://github.com/harmoniqs/Intonato.jl#migrating-from-strumentojl"

function __init__()
    # Not at precompile time: a dependent package precompiling against the shim
    # must not print the warning into its precompile log.
    ccall(:jl_generating_output, Cint, ()) == 1 && return
    @warn "Strumento.jl is deprecated and archived; use Intonato ≥ 0.5 (soc substrate at top level, twin in Intonato.Twins, StrumentoSoc via the IntonatoPythonCallExt extension). See $MIGRATION_URL" maxlog = 1
end

end # module Strumento
