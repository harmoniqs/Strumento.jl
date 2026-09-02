# QickChannelMap — device policy: how Piccolo drive controls route onto QICK
# generator channels. A phase-modulated drive (Ω, φ(t)) is a single complex
# envelope on ONE gen channel: the two quadrature controls (I = Ω cos φ,
# Q = Ω sin φ) load to the SAME channel's idata/qdata, up-converted by that
# channel's NCO at `carrier_freq`. A purely real drive uses `q_drive = nothing`.

"""
    QickGenChannel(gen_ch, carrier_freq; i_drive, q_drive=nothing)

One generator channel: `gen_ch` plays a complex envelope built from Piccolo
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

Validated map from Piccolo drive controls → QICK generator channels.
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

# ──── TwinWiringMap — device-channel → twin-drive wiring (issue #31) ─────────
# The channel-map concept extended one rung DOWN the stack: `QickChannelMap`
# routes Piccolo drive CONTROLS onto QICK generator channels (the pulse side);
# `TwinWiringMap` routes DEVICE generator channels onto the TWIN's drive
# quadratures (the bring-up side — which family drives each device line feeds).
# The twin job server consumes it at execution (its per-gen routing) and the
# bring-up rig validates every submitted payload's played channels against
# it, so a payload that would silently land on the wrong twin drive is named,
# not executed.

"""
    TwinGenWiring(gen_ch, i_drive, q_drive; line="") 

One device generator channel's wiring into the twin: gen channel `gen_ch`
(the wire payload's 0-based generator channel) plays the twin's `i_drive`
(I quadrature) and `q_drive` (Q quadrature) controls. `line` documents which
device wiring line the channel serves (it rides the error messages).
"""
struct TwinGenWiring
    gen_ch::Int
    i_drive::Int
    q_drive::Int
    line::String
end

TwinGenWiring(gen_ch::Int, i_drive::Integer, q_drive::Integer; line::AbstractString = "") =
    TwinGenWiring(gen_ch, Int(i_drive), Int(q_drive), String(line))

"""
    TwinWiringMap(wirings; n_drives) -> TwinWiringMap

Validated device-channel → twin-drive wiring: every drive index referenced must
be in `1:n_drives`, no drive may be wired twice, gen channels must be distinct,
and the wirings must be ordered by gen channel (the wire payloads arrive with
their played generators sorted; the map's order is the wiring's declaration).
"""
struct TwinWiringMap
    wirings::Vector{TwinGenWiring}
    n_drives::Int
end

function TwinWiringMap(wirings::Vector{TwinGenWiring}; n_drives::Integer)
    used = Int[]
    for w in wirings
        for d in (w.i_drive, w.q_drive)
            (1 ≤ d ≤ n_drives) ||
                error("TwinWiringMap: twin drive index $d (gen channel $(w.gen_ch)) " *
                      "out of range 1:$n_drives")
            d in used && error("TwinWiringMap: twin drive index $d wired more than once")
            push!(used, d)
        end
    end
    gen_chs = [w.gen_ch for w in wirings]
    allunique(gen_chs) || error("TwinWiringMap: generator channels must be distinct")
    issorted(gen_chs) || error(
        "TwinWiringMap: wirings must be ordered by gen channel (got $gen_chs) — " *
        "the wire payloads arrive with their played generators sorted, and the " *
        "map's order is the wiring's declaration")
    return TwinWiringMap(wirings, Int(n_drives))
end

"""The twin drive pair a wired gen channel feeds, or `nothing` when the channel
is unwired (an unmapped device line — the actionable-error case)."""
function wiring_for(map::TwinWiringMap, gen_ch::Integer)
    for w in map.wirings
        w.gen_ch == gen_ch && return w
    end
    return nothing
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

@testitem "TwinWiringMap — the device-channel → twin-drive wiring, validated" begin
    using Strumento
    # The rig's canonical wiring: the transmon line's generator feeds the twin's
    # ancilla quadratures (drives 1/2), the cavity line's the cavity quadratures
    # (drives 3/4) — the bosonic family's documented drive order.
    m = TwinWiringMap([
        TwinGenWiring(2, 1, 2; line = "qubit.drive"),
        TwinGenWiring(3, 3, 4; line = "manipulate.main"),
    ]; n_drives = 4)
    @test m.wirings[1].gen_ch == 2 && m.wirings[2].gen_ch == 3
    @test wiring_for(m, 3) === m.wirings[2]
    @test wiring_for(m, 5) === nothing           # an unmapped device line

    # validation, each named: drive out of range, drive wired twice, duplicate
    # or unsorted gen channels.
    @test_throws ErrorException TwinWiringMap([TwinGenWiring(2, 1, 5)]; n_drives = 4)
    @test_throws ErrorException TwinWiringMap(
        [TwinGenWiring(2, 1, 3), TwinGenWiring(3, 3, 4)]; n_drives = 4)
    @test_throws ErrorException TwinWiringMap(
        [TwinGenWiring(2, 1, 2), TwinGenWiring(2, 3, 4)]; n_drives = 4)
    err = try
        TwinWiringMap([TwinGenWiring(3, 3, 4), TwinGenWiring(2, 1, 2)]; n_drives = 4);
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("ordered by gen channel", sprint(showerror, err))
end
