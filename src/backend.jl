# StrumentoBackend — the AbstractHardwareBackend over an AbstractSoc. Implements
# Intonato's documented hardware interface (upload_pulse! / trigger! / readout /
# sample_rate). The QILC chassis never calls these directly; the StrumentoExperiment
# `run` closure (experiment.jl) does, once per experiment evaluation.
#
# The soc owns *translation* — this is the option-(a) division of labour (see the
# module docstring / README): a MockSoc translates the pulse in Julia (board-free
# rollout), while a StrumentoSoc hands the pulse to Python `strumento`, which owns
# the pulse-IR → AveragerProgramV2 → acquire → reduce path. So `execute!` is the one
# verb each soc implements; the backend just chains upload → trigger → readout onto it.

"""
    StrumentoBackend(soc, channel_map, indices; discriminator = b -> real.(b))

Hardware backend bridging a pulse to a soc. `indices` are the measurement knot
indices (into `1:N`) the readout produces; `discriminator` maps one IQ blob to a
data vector (default: real part, matching `MockSoc`'s populations forward model).
`last_raw` holds the most recent raw readout.

`channel_map` is the QICK device policy the **MockSoc** uses to route drives → gen
channels; a **StrumentoSoc** ignores it (Python `strumento` owns routing via its own
`Device`/wiring), so it may be an empty map there.

Note: under line search the QILC chassis evaluates the experiment several times per
outer iteration, so `last_raw` reflects the *last probe*, not necessarily the
accepted iterate.
"""
mutable struct StrumentoBackend{S<:AbstractSoc} <: AbstractHardwareBackend
    soc::S
    channel_map::QickChannelMap
    indices::Vector{Int}
    discriminator::Function
    _pulse::Union{Nothing,AbstractPulse}
    last_raw::Any
end

StrumentoBackend(soc::AbstractSoc, channel_map::QickChannelMap, indices::Vector{Int};
                 discriminator::Function = b -> real.(b)) =
    StrumentoBackend(soc, channel_map, indices, discriminator, nothing, nothing)

function upload_pulse!(b::StrumentoBackend, pulse::AbstractPulse)
    b._pulse = pulse
    return nothing
end

function trigger!(b::StrumentoBackend)
    b._pulse === nothing && error("StrumentoBackend.trigger!: upload a pulse first")
    # Each soc translates + runs the pulse its own way (Julia rollout for the mock,
    # Python-strumento delegation for the real board).
    b.last_raw = execute!(b.soc, b._pulse, b.channel_map, b.indices)
    return nothing
end

readout(b::StrumentoBackend) = b.last_raw

sample_rate(b::StrumentoBackend) = dac_rate(b.soc)

@testitem "StrumentoBackend upload/trigger/readout against MockSoc" begin
    using Strumento
    using LinearAlgebra
    σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
    sys = QuantumSystem(1.0 * σz, [σx], [1.0])
    N = 11
    pulse = LinearSplinePulse(0.1 .* randn(1, N), collect(range(0.0, 5.0, length=N)))
    map = QickChannelMap([QickGenChannel(0, 5e9; i_drive=1)]; n_drives=1)
    soc = MockSoc(sys, ComplexF64[1, 0], ComplexF64[0, 1]; dac_rate=20.0)
    b = StrumentoBackend(soc, map, [N])

    @test b.last_raw === nothing
    Strumento.upload_pulse!(b, pulse)
    Strumento.trigger!(b)
    raw = Strumento.readout(b)
    @test b.last_raw === raw
    @test sum(real.(raw[1])) ≈ 1.0 atol=1e-6
    @test Strumento.sample_rate(b) == 20.0
end
