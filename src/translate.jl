# QickProgram — the pulse → QICK waveform translation's data contract and
# duck-typed verb stub (pure Julia: no Piccolo name may appear here).
#
# The translation itself (sampling a Piccolo AbstractPulse onto each generator
# channel's DAC grid via Piccolo `sample`, packing the routed controls into
# complex (idata, qdata) envelopes) lives in the PICCOLO EXTENSION
# (ext/StrumentoPiccoloExt.jl): it is physics-stack code. This file keeps in
# base what the contract surface needs everywhere — the device-agnostic
# program record (plain data, exported) and the `pulse_to_envelopes` verb as a
# duck-typed stub with an actionable error (the same pattern the soc verbs
# use); the extension adds the typed method when Piccolo is loaded.

"""
    QickProgram

A device-agnostic description of a played pulse:
- `times` — the DAC-grid sample times (s).
- `envelopes` — `gen_ch => (idata, qdata)` complex envelope samples.
- `carrier_freqs` — `gen_ch => carrier frequency (Hz)`.
- `routing` — `(gen_ch, i_drive, q_drive)` per channel (so a SoC can invert
  envelopes back to drive controls — used by `MockSoc`).
- `n_drives` — control count of the source pulse.
- `indices` — measurement knot indices (into `1:N`) the readout should produce.
"""
struct QickProgram
    times::Vector{Float64}
    envelopes::Dict{Int,Tuple{Vector{Float64},Vector{Float64}}}
    carrier_freqs::Dict{Int,Float64}
    routing::Vector{Tuple{Int,Int,Union{Int,Nothing}}}
    n_drives::Int
    indices::Vector{Int}
end

"""
    pulse_to_envelopes(pulse, map, dac_rate, indices; max_len=DEFAULT_MAX_ENVELOPE_LEN) → QickProgram

Sample `pulse` onto the DAC grid (`0 : 1/dac_rate : duration`) and route each
control onto its generator channel's I/Q envelope per `map`. Errors if the
envelope would exceed `max_len` samples (envelope-memory limit).

The typed method (on a Piccolo `AbstractPulse`) is added by the Piccolo
extension when Piccolo is loaded; without it this stub errors actionably.
"""
function pulse_to_envelopes(args...; kwargs...)
    return error(
        "Strumento.pulse_to_envelopes: no translation method loaded for " *
        "$(typeof(args[1])) — this needs the Piccolo extension (add Piccolo " *
        "to the environment and load it)")
end

@testitem "pulse_to_envelopes stub errors actionably without the Piccolo extension" begin
    using Strumento
    # A pulse no extension will ever cover: the duck-typed stub must fire in
    # EVERY load configuration (the typed method dispatches only on Piccolo's
    # AbstractPulse).
    @test_throws ErrorException pulse_to_envelopes("not a pulse", nothing, 0.0, [0])
    # The data contract is loadable everywhere (the extension fills it in).
    @test fieldtypes(QickProgram) == (Vector{Float64},
                                     Dict{Int,Tuple{Vector{Float64},Vector{Float64}}},
                                     Dict{Int,Float64},
                                     Vector{Tuple{Int,Int,Union{Int,Nothing}}},
                                     Int, Vector{Int})
end