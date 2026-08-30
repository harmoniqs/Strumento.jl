# MockSoc — a pure-Julia "board" that simulates QICK execution by rolling the
# played pulse through a known `QuantumSystem` (Intonato's own `rollout`, via a
# `SimulatedExperiment`) and emitting synthetic IQ. The forward model is explicit:
#   state → IQ blob = measurement_fn(state) packed as a real-valued complex vector,
# which the trivial discriminator `real` inverts EXACTLY. So a QILC loop run
# through `StrumentoBackend{MockSoc}` reproduces the same measurements a direct
# `SimulatedExperiment` would — the loop is validated without a board.
#
# The user passes the "true" (optionally mismatched) system as the mock's system;
# the nominal QCP is solved against the nominal system separately.

"""
    MockSoc(system, ψ_init, ψ_goal; measurement_fn=populations, dac_rate=1.0, adc_rate=1.0)

A simulated QICK SoC backed by `system`. `play_program!`/`acquire` reconstruct the
played pulse from the loaded envelopes and roll it out via a `SimulatedExperiment`,
returning IQ blobs `measurement_fn(state)` (packed as complex; invert with `real`).
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
    # Single simulation path: roll out via a SimulatedExperiment over the system.
    model = MeasurementModel(:ψ̃, [soc.measurement_fn for _ in prog.indices], prog.indices)
    exp = SimulatedExperiment(KetTrajectory(soc.system, recon, soc.ψ_init, soc.ψ_goal), model)
    ms = run_experiment(exp, recon)
    # Forward model state→IQ: pack each measurement's data as a complex blob.
    return [ComplexF64.(m.data) for m in ms]
end

@testitem "MockSoc round-trips a pulse to valid populations IQ" begin
    using Strumento
    using LinearAlgebra
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

@testitem "MockSoc IQ forward model is pinned to golden values (exact equality)" begin
    using Strumento
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
