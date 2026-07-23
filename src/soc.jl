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
    @test_throws ErrorException acquire(s, [0])
    @test_throws ErrorException dac_rate(s)
end
