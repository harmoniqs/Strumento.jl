# QickChannelMap — device policy: how Intonato drive controls route onto QICK
# generator channels. A phase-modulated drive (Ω, φ(t)) is a single complex
# envelope on ONE gen channel: the two quadrature controls (I = Ω cos φ,
# Q = Ω sin φ) load to the SAME channel's idata/qdata, up-converted by that
# channel's NCO at `carrier_freq`. A purely real drive uses `q_drive = nothing`.

"""
    QickGenChannel(gen_ch, carrier_freq; i_drive, q_drive=nothing)

One generator channel: `gen_ch` plays a complex envelope built from Intonato
control index `i_drive` (I quadrature) and optional `q_drive` (Q quadrature),
up-converted at `carrier_freq` (Hz). `q_drive = nothing` ⇒ a real envelope.
"""
struct QickGenChannel
    gen_ch::Int
    carrier_freq::Float64
    i_drive::Int
    q_drive::Union{Int,Nothing}
end

QickGenChannel(gen_ch::Int, carrier_freq::Real; i_drive::Int, q_drive=nothing) =
    QickGenChannel(gen_ch, Float64(carrier_freq), i_drive, q_drive)

"""
    QickChannelMap(channels; readout_chs, n_drives)

Validated map from Intonato drive controls → QICK generator channels.
`n_drives` is the control count of the pulses to be played; every drive index
referenced must be in `1:n_drives`, no drive may be mapped twice, and gen
channels must be distinct.
"""
struct QickChannelMap
    channels::Vector{QickGenChannel}
    readout_chs::Vector{Int}
    n_drives::Int
end

function QickChannelMap(channels::Vector{QickGenChannel};
                        readout_chs::Vector{Int} = Int[0],
                        n_drives::Int)
    used = Int[]
    for ch in channels
        for d in (ch.i_drive, ch.q_drive)
            d === nothing && continue
            (1 ≤ d ≤ n_drives) ||
                error("QickChannelMap: drive index $d out of range 1:$n_drives")
            d in used && error("QickChannelMap: drive index $d mapped more than once")
            push!(used, d)
        end
    end
    gen_chs = [ch.gen_ch for ch in channels]
    allunique(gen_chs) || error("QickChannelMap: generator channels must be distinct")
    return QickChannelMap(channels, readout_chs, n_drives)
end

@testitem "QickChannelMap validation" begin
    using Strumento
    # Two real drives on two gen channels — OK.
    m = QickChannelMap([QickGenChannel(0, 5e9; i_drive=1),
                        QickGenChannel(1, 5e9; i_drive=2)]; n_drives=2)
    @test length(m.channels) == 2
    # One complex drive (I+Q) on one channel — OK.
    m2 = QickChannelMap([QickGenChannel(0, 5e9; i_drive=1, q_drive=2)]; n_drives=2)
    @test m2.channels[1].q_drive == 2
    # Drive index out of range — throws.
    @test_throws ErrorException QickChannelMap([QickGenChannel(0, 5e9; i_drive=3)]; n_drives=2)
    # Drive mapped twice — throws.
    @test_throws ErrorException QickChannelMap(
        [QickGenChannel(0, 5e9; i_drive=1), QickGenChannel(1, 5e9; i_drive=1)]; n_drives=2)
    # Duplicate gen channel — throws.
    @test_throws ErrorException QickChannelMap(
        [QickGenChannel(0, 5e9; i_drive=1), QickGenChannel(0, 5e9; i_drive=2)]; n_drives=2)
end
