# StrumentoPiccoloExt — the Piccolo-triggered package extension (issue #16).
#
# Everything on the substrate that touches the physics stack lives here: the
# pulse → QICK-envelope translation method (AbstractPulse sampling; the
# duck-typed verb and its QickProgram data contract stay in base) and the
# pure-Julia `MockSoc` (QuantumSystem rollouts through Piccolo-native
# propagation). The extension loads when Piccolo is loaded; the base package
# references no Piccolo name.
#
# Julia's extension semantics (1.12): extension exports do NOT surface on the
# parent module — `using Strumento` never brings `MockSoc` into scope. The
# function verbs base declares duck-typed (`pulse_to_envelopes`, the
# pulse-sampling seam) gain their typed methods here, so bare-name CALLS work
# in every configuration; the extension-defined TYPE (`MockSoc`) is reached
# through `Base.get_extension(Strumento, :StrumentoPiccoloExt)`.
#
# The pulse-sampling API is bound from its defining module: Piccolo's TOP-LEVEL
# reexport of `duration` is ambiguous against NamedTrajectories' TimeWarp
# `duration` export in the same reexport chain (NamedTrajectories ≥ 0.9.3),
# which leaves the name unbound at Piccolo's top level. The function itself is
# unchanged — same object, same method — and `pulse_to_envelopes`' golden pin
# is captured against it.
#
# Testitems in this file guard on `Base.identify_package("Piccolo")` and skip
# cleanly in configurations without the trigger (the same pattern the
# Python-strumento delegation item uses for the Python package).
module StrumentoPiccoloExt

import Strumento
import Strumento: AbstractSoc, execute!, load_envelope!, play_program!, acquire,
    dac_rate, adc_rate, QickChannelMap,
    pulse_to_envelopes,                 # the base verb: typed method added below
    QickProgram,                        # the base data contract: filled here
    pulse_duration, sample_controls     # the pulse-sampling seam (typed methods below)
using TestItems

using Piccolo
using Piccolo.Quantum.Pulses: duration, n_drives, sample, get_knot_times

export MockSoc

# Default per-gen-channel envelope sample-memory cap (typical QICK firmware is
# O(few k) samples per generator). Configurable per call.
const DEFAULT_MAX_ENVELOPE_LEN = 16_384

# ──── Pulse / envelope translation (the typed method on the base verb) ──────
# Samples a Piccolo pulse onto each generator channel's DAC grid (via Piccolo
# `sample`) and packs the routed controls into complex (idata, qdata)
# envelopes plus the metadata a board needs to play and read them back.

function pulse_to_envelopes(pulse::AbstractPulse, map::QickChannelMap,
                            dac_rate::Real, indices::Vector{Int};
                            max_len::Int = DEFAULT_MAX_ENVELOPE_LEN)
    n_drives(pulse) == map.n_drives ||
        error("pulse has $(n_drives(pulse)) drives but channel map expects $(map.n_drives)")
    T = duration(pulse)
    nsamp = floor(Int, T * dac_rate) + 1
    nsamp ≤ max_len ||
        error("envelope length $nsamp exceeds max $max_len at dac_rate=$dac_rate, T=$T")
    times = collect(range(0.0, T, length = nsamp))
    ctrls = sample(pulse, times)               # (n_drives, nsamp)

    envelopes = Dict{Int,Tuple{Vector{Float64},Vector{Float64}}}()
    carrier_freqs = Dict{Int,Float64}()
    routing = Tuple{Int,Int,Union{Int,Nothing}}[]
    for ch in map.channels
        idata = Vector{Float64}(ctrls[ch.i_drive, :])
        qdata = ch.q_drive === nothing ? zeros(Float64, nsamp) :
                Vector{Float64}(ctrls[ch.q_drive, :])
        envelopes[ch.gen_ch] = (idata, qdata)
        carrier_freqs[ch.gen_ch] = ch.carrier_freq
        push!(routing, (ch.gen_ch, ch.i_drive, ch.q_drive))
    end
    return QickProgram(times, envelopes, carrier_freqs, routing, map.n_drives, indices)
end

@testitem "pulse_to_envelopes samples + routes correctly" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using LinearAlgebra
        N = 11; T = 5.0
        times = collect(range(0.0, T, length=N))
        vals = 0.1 .* randn(2, N)
        pulse = LinearSplinePulse(vals, times)
        # drive 1 → ch0 I, drive 2 → ch0 Q (one complex drive on one channel)
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive=1, q_drive=2)]; n_drives=2)
        dac_rate = 10.0   # 10 Hz → 51 samples over T=5
        prog = pulse_to_envelopes(pulse, map, dac_rate, [N])
        @test length(prog.times) == 51
        @test haskey(prog.envelopes, 0)
        idata, qdata = prog.envelopes[0]
        @test length(idata) == 51 && length(qdata) == 51
        # idata/qdata equal the pulse's two controls sampled at the DAC grid.
        @test idata ≈ [pulse(t)[1] for t in prog.times]
        @test qdata ≈ [pulse(t)[2] for t in prog.times]
        @test prog.carrier_freqs[0] == 5e9
    end
end

@testitem "pulse_to_envelopes enforces envelope memory cap" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        N = 11; T = 5.0
        pulse = LinearSplinePulse(0.1 .* randn(1, N), collect(range(0.0, T, length=N)))
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive=1)]; n_drives=1)
        @test_throws ErrorException pulse_to_envelopes(pulse, map, 1e6, [N]; max_len=1000)
    end
end

@testitem "pulse_to_envelopes rejects drive-count mismatch" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        pulse = LinearSplinePulse(0.1 .* randn(1, 11), collect(range(0.0, 5.0, length=11)))
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive=1, q_drive=2)]; n_drives=2)
        @test_throws ErrorException pulse_to_envelopes(pulse, map, 10.0, [11])
    end
end

# ──── MockSoc ────────────────────────────────────────────────────────────────
# A pure-Julia "board" that simulates QICK execution by rolling the played
# pulse through a known `QuantumSystem` (Piccolo-native propagation: `rollout`
# on a `KetTrajectory`) and emitting synthetic IQ. The forward model is
# explicit:
#   state → IQ blob = measurement_fn(state) packed as a real-valued complex vector,
# which the trivial discriminator `real` inverts EXACTLY. So a QILC loop run
# through the (relocated, Intonato-side) `StrumentoBackend{MockSoc}` reproduces
# the same measurements a direct simulated rollout would — the loop is validated
# without a board.
#
# The user passes the "true" (optionally mismatched) system as the mock's system;
# the nominal QCP is solved against the nominal system separately.

"""
    populations(x::AbstractVector)

Level populations |ψ_j|² from iso-vec ket (Re(ψ), Im(ψ)) — MockSoc's default
forward model. Substrate-local since v0.2 (issue #14): the identical function
Intonato exports on the loop side, kept unexported here so `using Strumento,
Intonato` consumers keep a single `populations` binding (Intonato's).
"""
function populations(x::AbstractVector)
    n = length(x) ÷ 2
    x_re = @view x[1:n]
    x_im = @view x[(n+1):2n]
    return x_re .^ 2 .+ x_im .^ 2
end

"""
    MockSoc(system, ψ_init, ψ_goal; measurement_fn=populations, dac_rate=1.0, adc_rate=1.0)

A simulated QICK SoC backed by `system`. `play_program!`/`acquire` reconstruct the
played pulse from the loaded envelopes and roll it out via Piccolo's `rollout`
(`KetTrajectory` propagation through `system`), returning IQ blobs
`measurement_fn(state)` (packed as complex; invert with `real`).

The `MockSoc` type is defined by the Piccolo extension — reach it via
`Base.get_extension(Strumento, :StrumentoPiccoloExt).MockSoc` (extension
exports do not surface on the parent module).
"""
mutable struct MockSoc <: AbstractSoc
    system::QuantumSystem
    ψ_init::Vector{ComplexF64}
    ψ_goal::Vector{ComplexF64}
    measurement_fn::Function
    dac_rate::Float64
    adc_rate::Float64
    _env::Dict{Int,Tuple{Vector{Float64},Vector{Float64}}}
    _program::Union{Nothing,QickProgram}
end

function MockSoc(system::QuantumSystem,
                     ψ_init::AbstractVector, ψ_goal::AbstractVector;
                     measurement_fn::Function = populations,
                     dac_rate::Real = 1.0, adc_rate::Real = 1.0)
    return MockSoc(system, ComplexF64.(ψ_init), ComplexF64.(ψ_goal),
                       measurement_fn, Float64(dac_rate), Float64(adc_rate),
                       Dict{Int,Tuple{Vector{Float64},Vector{Float64}}}(), nothing)
end

dac_rate(soc::MockSoc) = soc.dac_rate
adc_rate(soc::MockSoc) = soc.adc_rate

load_envelope!(soc::MockSoc, gen_ch::Int, idata, qdata) =
    (soc._env[gen_ch] = (Vector{Float64}(idata), Vector{Float64}(qdata)); nothing)

play_program!(soc::MockSoc, program::QickProgram) = (soc._program = program; nothing)

# execute! — the AbstractSoc verb: translate the pulse in Julia (QICK-shaped
# envelopes), then roll it out. This is the board-free path the QILC loop tests.
function execute!(soc::MockSoc, pulse::AbstractPulse, channel_map::QickChannelMap,
                  indices::Vector{Int})
    prog = pulse_to_envelopes(pulse, channel_map, dac_rate(soc), indices)
    for (gen_ch, (idata, qdata)) in prog.envelopes
        load_envelope!(soc, gen_ch, idata, qdata)
    end
    play_program!(soc, prog)
    return acquire(soc, channel_map.readout_chs)
end

function acquire(soc::MockSoc, _ro_chs)
    prog = soc._program
    prog === nothing && error("MockSoc.acquire: no program played")
    # Reconstruct the drive controls from the loaded per-channel envelopes.
    nsamp = length(prog.times)
    ctrls = zeros(Float64, prog.n_drives, nsamp)
    for (gen_ch, i_drive, q_drive) in prog.routing
        idata, qdata = soc._env[gen_ch]
        ctrls[i_drive, :] .= idata
        q_drive === nothing || (ctrls[q_drive, :] .= qdata)
    end
    recon = LinearSplinePulse(ctrls, prog.times)
    # Piccolo-native propagation (v0.2, issue #14 — the same `rollout` the
    # Intonato `SimulatedExperiment` path called under the hood, so the forward
    # model is bit-for-bit unchanged; pinned by the golden testitem below):
    # propagate ψ through the system under the reconstructed controls, then
    # evaluate the forward model at each measurement knot (indices index into
    # the reconstructed pulse's DAC-grid knot times).
    qtraj = rollout(KetTrajectory(soc.system, recon, soc.ψ_init, soc.ψ_goal), recon)
    knot_times = get_knot_times(recon)
    # Forward model state→IQ: pack each measurement's data as a complex blob.
    return [ComplexF64.(soc.measurement_fn(ket_to_iso(qtraj(knot_times[k]))))
            for k in prog.indices]
end

@testitem "MockSoc round-trips a pulse to valid populations IQ" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using LinearAlgebra
        # The mock type is extension-defined: extension exports do not surface
        # on the parent module, so reach it through its canonical handle.
        MockSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).MockSoc
        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        sys = QuantumSystem(1.0 * σz, [σx], [1.0])
        N = 11; T = 5.0
        times = collect(range(0.0, T, length=N))
        pulse = LinearSplinePulse(0.1 .* randn(1, N), times)
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive=1)]; n_drives=1)

        soc = MockSoc(sys, ComplexF64[1, 0], ComplexF64[0, 1]; dac_rate=20.0)
        prog = pulse_to_envelopes(pulse, map, dac_rate(soc), [N])
        for (gen_ch, (idata, qdata)) in prog.envelopes
            load_envelope!(soc, gen_ch, idata, qdata)
        end
        play_program!(soc, prog)
        raw = acquire(soc, [0])

        @test length(raw) == 1                 # one measurement (final knot)
        pops = real.(raw[1])
        @test length(pops) == 2                # dim-2 populations
        @test sum(pops) ≈ 1.0 atol=1e-6        # valid probability vector
        @test all(pops .≥ -1e-9)
    end
end

@testitem "MockSoc IQ forward model is pinned to golden values (exact equality)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        MockSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).MockSoc
        # GOLDEN PIN — captured from the Intonato-`SimulatedExperiment` rollout (the
        # pre-re-grounding forward model, Strumento v0.1.x, Piccolo 2.0.2, Julia 1.12)
        # for this FIXED fixture: 2-drive system, deterministic analytic I/Q pulse,
        # one complex-envelope gen channel, two measurement knots (DAC-grid samples
        # 11 and 101), dac_rate = 20 Hz. The rollout swap (issue #14: Piccolo-native
        # propagation replacing the SimulatedExperiment) must reproduce these blobs
        # BIT-FOR-BIT — `==`, no tolerance. A last-ulp deviation here is a behavior
        # change, not noise: report it, never silently widen.
        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        sys = QuantumSystem(1.0 * σz, [σx, σx], [1.0, 1.0])
        N = 11; T = 5.0
        times = collect(range(0.0, T, length=N))
        vals = 0.1 .* permutedims(hcat(sin.(range(0.0, 2.4π, length=N)),
                                       cos.(range(0.3π, 1.7π, length=N))))
        pulse = LinearSplinePulse(vals, times)
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive=1, q_drive=2)]; n_drives=2)

        soc = MockSoc(sys, ComplexF64[1, 0], ComplexF64[0, 1]; dac_rate=20.0)
        raw = execute!(soc, pulse, map, [11, 101])

        @test raw == [ComplexF64[0.9987748357943047 + 0.0im, 0.0012251642056963555 + 0.0im],
                      ComplexF64[0.9552991750369558 + 0.0im, 0.044700824963045074 + 0.0im]]
    end
end

@testitem "Piccolo extension surface: typed methods + the mock type reachable" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        @test ext !== nothing
        # The extension-defined type is reachable through its canonical handle …
        @test isdefined(ext, :MockSoc)
        @test ext.MockSoc <: Strumento.AbstractSoc
        # … and the base-declared duck-typed surface now has its Piccolo
        # methods (zero functional surface loss: bare-name calls dispatch).
        @test hasmethod(Strumento.pulse_to_envelopes,
                        Tuple{AbstractPulse, Strumento.QickChannelMap,
                              Float64, Vector{Int}})
        # the pulse-sampling seam (the delegation soc's path) is typed
        @test hasmethod(Strumento.pulse_duration, Tuple{AbstractPulse})
        @test hasmethod(Strumento.sample_controls, Tuple{AbstractPulse, Vector{Float64}})
    end
end

# ──── The pulse-sampling seam's typed methods ────────────────────────────────
# The delegation soc (the PythonCall extension) samples a played pulse through
# the base seam — it cannot name a Piccolo function itself (PythonCall is its
# only trigger). These methods give the seam its Piccolo implementation; in a
# PythonCall-without-Piccolo environment, calling them errors actionably (the
# base stubs).
pulse_duration(pulse::AbstractPulse) = duration(pulse)
sample_controls(pulse::AbstractPulse, times) = sample(pulse, times)

end # module StrumentoPiccoloExt