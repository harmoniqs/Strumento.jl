# AbstractSoc — the abstraction over a QICK board controller. The mock
# (`MockSoc`, pure Julia) and the real proxy (`StrumentoSoc`, lazy qick) both
# implement it, so `StrumentoBackend` is written once against this interface.

"""
    AbstractSoc

Abstraction over a board controller. The one verb every soc implements is
**`execute!`** — it owns *translation*, so the two soc kinds differ exactly where
they should:

- `execute!(soc, pulse, channel_map, indices) → raw` — translate + run `pulse`,
  returning raw per-measurement IQ blobs (aligned with `indices`). `MockSoc`
  translates in Julia and rolls out a `QuantumSystem`; `StrumentoSoc` hands the
  pulse to Python `strumento` (which owns the pulse-IR → program → acquire path).
- `dac_rate(soc) → Float64`, `adc_rate(soc) → Float64` — sample rates (Hz).

The lower-level `load_envelope!` / `play_program!` / `acquire` verbs are the
MockSoc's internal machinery (a board-free QICK-shaped translation); a soc that
delegates translation elsewhere need not implement them.
"""
abstract type AbstractSoc end

# Generic fallbacks give an actionable error if a subtype forgets a method.
execute!(soc::AbstractSoc, args...) =
    error("execute! not implemented for $(typeof(soc))")
load_envelope!(soc::AbstractSoc, args...) =
    error("load_envelope! not implemented for $(typeof(soc))")
play_program!(soc::AbstractSoc, args...) =
    error("play_program! not implemented for $(typeof(soc))")
acquire(soc::AbstractSoc, args...) =
    error("acquire not implemented for $(typeof(soc))")
dac_rate(soc::AbstractSoc) =
    error("dac_rate not implemented for $(typeof(soc))")
adc_rate(soc::AbstractSoc) =
    error("adc_rate not implemented for $(typeof(soc))")

@testitem "AbstractSoc interface fallbacks error" begin
    using Strumento
    struct _BareSoc <: Strumento.AbstractSoc end
    s = _BareSoc()
    @test_throws ErrorException load_envelope!(s, 0, [1.0], [0.0])
    @test_throws ErrorException play_program!(s)
    @test_throws ErrorException acquire(s, [0])
    @test_throws ErrorException adc_rate(s)
    @test_throws ErrorException dac_rate(s)
    @test_throws ErrorException execute!(s, 0)
end

# ──── Pulse-sampling seam (extension-provided) ───────────────────────────────
# Base is pulse-agnostic BY CONSTRUCTION: no Piccolo name may appear here, so
# the delegation soc's sampling of a played pulse goes through this seam. These
# are the duck-typed base signatures; the Piccolo extension adds the typed
# methods (`duration` / `sample` on a Piccolo `AbstractPulse`) when it loads —
# and exactly like the verb fallbacks above, an actionable error names what is
# missing when the seam is called without it (a PythonCall-only environment:
# the delegation soc exists, but no pulse-sampling method is loaded).

pulse_duration(pulse) = error(
    "Strumento.pulse_duration: no pulse-sampling method for $(typeof(pulse)) — " *
    "this needs the Piccolo extension (add Piccolo to the environment and load it)")

sample_controls(pulse, times) = error(
    "Strumento.sample_controls: no pulse-sampling method for $(typeof(pulse)) — " *
    "this needs the Piccolo extension (add Piccolo to the environment and load it)")

@testitem "pulse-sampling seam errors actionably without the Piccolo extension" begin
    using Strumento
    # A type no extension will ever cover: the duck-typed stub must fire in
    # EVERY load configuration (the typed methods dispatch only on
    # Piccolo's AbstractPulse).
    struct _DuckPulse end
    @test_throws ErrorException Strumento.pulse_duration(_DuckPulse())
    @test_throws ErrorException Strumento.sample_controls(_DuckPulse(), 0.0:1.0)
end
