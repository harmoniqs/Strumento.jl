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
    pulse_duration, sample_controls,    # the pulse-sampling seam (typed methods below)
    DigitalTwin,                        # the twin the soc face wraps (issue #20)
    advance!                            # the drift advance the soc wires per acquire
using TestItems

using Piccolo
using Piccolo.Quantum.Pulses: duration, n_drives, sample, get_knot_times

export MockSoc
export TwinSoc

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
        # to golden precision — a real behavior change must fail loudly here.
        #
        # TRANSPORT TOLERANCE (cross-environment form, run 33344813818): the
        # literals were captured on the-feynmachine (i9-12900KS, Julia 1.12.5) and
        # are bit-exact there. CI run 33320865313 (PR #19) reproduced them
        # BIT-EXACT on Julia 1.12.7; CI run 33344813818 (PR #23) — same Julia
        # 1.12.7, same resolution (DataInterpolations 8.10.0, Piccolo 2.0.2, …) —
        # drifted them 1–5 ulp: ubuntu-latest runner hardware rotation (the pool
        # mixes Xeon/EPYC families; Julia's multi-microarch cloning + OpenBLAS
        # kernel selection exercise different vectorized paths per CPU, and
        # FMA-fusion differences move last ulps). The literal comparison therefore
        # carries isapprox(rtol=1e-13, atol=1e-15): ~200× above the largest
        # observed drift (5.1e-16 relative), ~4 orders of magnitude below any
        # semantic forward-model change (≥1e-9). Within-process determinism pins
        # elsewhere in this suite stay `==` — they are box- and version-immune.
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

        @test isapprox(raw,
                       [ComplexF64[0.9987748357943047 + 0.0im, 0.0012251642056963555 + 0.0im],
                        ComplexF64[0.9552991750369558 + 0.0im, 0.044700824963045074 + 0.0im]];
                       rtol = 1e-13, atol = 1e-15)
    end
end

# ──── TwinSoc — the twin's soc face (issue #20) ──────────────────────────────
# A simulated QICK SoC backed by a `DigitalTwin` — the face that makes the
# twin contract (truth/belief/records/drift) reachable from the soc seam.
# `MockSoc` is the degenerate twin (exact response, static truth, hand-passed
# physics); `TwinSoc` generalizes exactly those three axes:
#   - the system is BUILT from the twin's CURRENT truth via family dispatch
#     (a builder keyed by the record's family field),
#   - the response is imperfect by construction (the record's readout
#     confusion matrix + binomial shot sampling, seeded from the twin's rng),
#   - the truth drifts between acquires (advance-after, a configurable dt).
#
# ONE stochastic source: the twin's own `rng` (a StableRNG) drives BOTH the
# drift draws and the shot sampling, in that order — identical seeds reproduce
# identical measurement sequences bit-exactly, across fresh processes.

"""
    TwinSoc(twin, ψ_init, ψ_goal; families, measurement_fn=populations,
            shots=100, exact=false, dt=0.0, dac_rate=1.0, adc_rate=1.0)

A simulated QICK SoC backed by a `DigitalTwin` — `MockSoc`'s drifting,
readout-confused generalization, pluggable wherever the mock plugs in
(same verbs, same IQ blob packing, same downstream discrimination).

The forward model per acquire:

1. **Roll the CURRENT-truth system** — `families[twin.record.family]` builds a
   `QuantumSystem` from `twin.truth` as it stands for THIS acquire (drifted
   truth is therefore felt exactly when it has evolved). The played pulse is
   reconstructed from the loaded envelopes exactly the way `MockSoc` does, and
   propagated with Piccolo-native `KetTrajectory` propagation.
2. **Response** — the measurement function (default `populations`) maps the
   rolled-out state to a probability vector `p`; the record's readout
   confusion matrix remaps it (`q = Cᵀ p` — rows of `C` are the TRUE state's
   outcome distributions, `C[i, j] = P(measured j | true i)`); then either
   * `exact = true`: `q` as-is (the deterministic mode — no sampling), or
   * the default: **binomial shot sampling** — each of `shots` shots draws one
     level from `q` (the blob is the per-level shot frequency), seeded from the
     twin's rng.
   The blob is packed exactly the way `MockSoc` packs blobs
   (`Vector{ComplexF64}`, real data) so `iq_to_measurements` and downstream
   discrimination are unchanged.
3. **Drift (advance-after)** — AFTER the response, the twin's truth is advanced
   by `dt` (twin-time, days by convention) when `dt > 0`: acquire *k* measures
   truth at twin-time `(k-1)·dt` — the FIRST acquire sees the record's pristine
   truth (t = 0, where belief and truth agree), and each subsequent acquire
   sees truth aged one `dt` further. `dt = 0` (the default) skips the advance
   entirely: static truth, no drift draws consumed, no scheduled jumps fired —
   MockSoc-like usage stays deterministic.

The record's readout confusion is required (the v1 response model): the soc
unwraps it from the vault's `noise.readout_confusion = {value, estimate, note}`
wrapper and validates it is square, non-negative, and row-stochastic. All
stochasticity flows from `twin.rng` — construct twins with
`instantiate(...; seed = s)` and identical seeds replay identically.
"""
mutable struct TwinSoc <: AbstractSoc
    twin::DigitalTwin
    family::String              # the record's family (the dispatch key used)
    system_builder::Function    # (truth::Dict{Symbol,Float64}) -> QuantumSystem
    confusion::Matrix{Float64}   # the record's readout confusion (rows = true states)
    ψ_init::Vector{ComplexF64}
    ψ_goal::Vector{ComplexF64}
    measurement_fn::Function
    shots::Int
    exact::Bool
    dt::Float64
    dac_rate::Float64
    adc_rate::Float64
    _env::Dict{Int,Tuple{Vector{Float64},Vector{Float64}}}
    _program::Union{Nothing,QickProgram}
end

function TwinSoc(twin::DigitalTwin, ψ_init::AbstractVector, ψ_goal::AbstractVector;
                 families::AbstractDict{<:AbstractString},
                 measurement_fn::Function = populations,
                 shots::Integer = 100,
                 exact::Bool = false,
                 dt::Real = 0.0,
                 dac_rate::Real = 1.0, adc_rate::Real = 1.0)
    family = twin.record.family
    haskey(families, family) || error(
        "TwinSoc: no system builder for family $(repr(family)) (record " *
        "$(repr(twin.record.id))) — known families: $(sort(collect(keys(families))))")
    shots ≥ 1 || error("TwinSoc: shots must be ≥ 1 (got $shots)")
    dt ≥ 0 || error("TwinSoc: dt must be ≥ 0 — twin-time only runs forward (got $dt)")
    return TwinSoc(twin, family, families[family], _record_confusion(twin),
                   ComplexF64.(ψ_init), ComplexF64.(ψ_goal), measurement_fn,
                   Int(shots), exact, Float64(dt),
                   Float64(dac_rate), Float64(adc_rate),
                   Dict{Int,Tuple{Vector{Float64},Vector{Float64}}}(), nothing)
end

# Unwrap + validate the record's readout confusion. The vault schema wraps
# noise values as {value, estimate, note}; the matrix lives under `value`.
# Convention: rows are the TRUE state's outcome distributions — C[i, j] =
# P(measured j | true i) — so each row is a probability vector and the remap
# is q = Cᵀ p (p = the true population vector, q = the expectation of the
# measured one).
function _record_confusion(twin::DigitalTwin)
    wrapped = get(twin.record.noise, "readout_confusion", nothing)
    wrapped === nothing && error(
        "TwinSoc: record $(repr(twin.record.id)) carries no " *
        "noise.readout_confusion — the v1 response model requires the readout " *
        "confusion matrix in the wrapped form {value: [[...]], estimate, note}")
    wrapped isa AbstractDict || error(
        "TwinSoc: noise.readout_confusion must be the wrapped form " *
        "{value: [[...]], estimate, note} (got $(typeof(wrapped)))")
    haskey(wrapped, "value") || error(
        "TwinSoc: noise.readout_confusion is missing its `value` key — the " *
        "wrapped form is {value: [[...]], estimate, note}")
    rows = wrapped["value"]
    (rows isa AbstractVector && !isempty(rows)) || error(
        "TwinSoc: noise.readout_confusion.value must be a non-empty list of " *
        "rows (got $(typeof(rows)))")
    n = length(rows)
    all(r -> r isa AbstractVector && length(r) == n, rows) || error(
        "TwinSoc: noise.readout_confusion.value must be square ($(n) rows, " *
        "lengths $(map(length, rows)))")
    C = Matrix{Float64}(undef, n, n)
    for i in 1:n, j in 1:n
        C[i, j] = Float64(rows[i][j])
    end
    all(≥(0), C) || error(
        "TwinSoc: readout_confusion entries must be ≥ 0 (the matrix maps " *
        "probabilities to probabilities)")
    for i in 1:n
        isapprox(sum(C[i, :]), 1.0; atol = 1e-9) || error(
            "TwinSoc: readout_confusion row $i sums to $(sum(C[i, :])) ≠ 1 — " *
            "rows are the TRUE state's outcome distributions (C[i, j] = " *
            "P(measured j | true i)), so each row must be a probability vector")
    end
    return C
end

# The response seam (v1): measurement vector → confusion remap → (binomial
# shot sampling | exact) → IQ blob, packed exactly the way MockSoc packs
# blobs so downstream discrimination is unchanged.
function _respond(soc::TwinSoc, p::AbstractVector{<:Real})
    C = soc.confusion
    (length(p) == size(C, 1) == size(C, 2)) || error(
        "TwinSoc: measurement vector length $(length(p)) ≠ the record's " *
        "$(size(C, 1))×$(size(C, 2)) readout_confusion — the confusion must " *
        "match the measurement dimension (family $(repr(soc.family)))")
    isapprox(sum(p), 1.0; atol = 1e-6) || error(
        "TwinSoc: the measurement vector must be a probability vector " *
        "(sum(p) = $(sum(p)); family $(repr(soc.family))) — the v1 confusion " *
        "model remaps populations")
    q = [sum(C[i, j] * p[i] for i in eachindex(p)) for j in eachindex(p)]
    soc.exact && return ComplexF64.(q)
    # Binomial shot sampling: each shot draws one level from q; the blob is
    # the per-level shot frequency (count / shots). One rng draw per shot,
    # taken from the twin's rng — the drift draws and the shot draws share
    # the single seeded source.
    counts = zeros(Int, length(q))
    for _ in 1:soc.shots
        u = rand(soc.twin.rng)
        j = length(q)               # float-accumulation edge: the last level
        acc = 0.0
        for k in eachindex(q)
            acc += q[k]
            u < acc && (j = k; break)
        end
        counts[j] += 1
    end
    return ComplexF64.(counts ./ soc.shots)
end

dac_rate(soc::TwinSoc) = soc.dac_rate
adc_rate(soc::TwinSoc) = soc.adc_rate

load_envelope!(soc::TwinSoc, gen_ch::Int, idata, qdata) =
    (soc._env[gen_ch] = (Vector{Float64}(idata), Vector{Float64}(qdata)); nothing)

play_program!(soc::TwinSoc, program::QickProgram) = (soc._program = program; nothing)

# execute! — the AbstractSoc verb: translate the pulse in Julia (the same
# QICK-shaped envelope path the mock runs), load + play, then acquire.
function execute!(soc::TwinSoc, pulse::AbstractPulse, channel_map::QickChannelMap,
                  indices::Vector{Int})
    prog = pulse_to_envelopes(pulse, channel_map, dac_rate(soc), indices)
    for (gen_ch, (idata, qdata)) in prog.envelopes
        load_envelope!(soc, gen_ch, idata, qdata)
    end
    play_program!(soc, prog)
    return acquire(soc, channel_map.readout_chs)
end

function acquire(soc::TwinSoc, _ro_chs)
    prog = soc._program
    prog === nothing && error("TwinSoc.acquire: no program played")
    # Reconstruct the drive controls from the loaded per-channel envelopes —
    # the same inversion MockSoc performs, so the played pulse is identical.
    nsamp = length(prog.times)
    ctrls = zeros(Float64, prog.n_drives, nsamp)
    for (gen_ch, i_drive, q_drive) in prog.routing
        idata, qdata = soc._env[gen_ch]
        ctrls[i_drive, :] .= idata
        q_drive === nothing || (ctrls[q_drive, :] .= qdata)
    end
    recon = LinearSplinePulse(ctrls, prog.times)
    # Roll the CURRENT-truth system: the family builder consumes the twin's
    # truth as it stands for THIS acquire.
    system = soc.system_builder(soc.twin.truth)
    qtraj = KetTrajectory(system, recon, soc.ψ_init, soc.ψ_goal)
    knot_times = get_knot_times(recon)
    blobs = [_respond(soc, soc.measurement_fn(ket_to_iso(qtraj(knot_times[k]))))
             for k in prog.indices]
    # Drift (advance-after, documented in the docstring): the acquire measures
    # the truth as it stands, THEN ages it by dt — acquire k measures truth at
    # twin-time (k-1)·dt; the first acquire sees the record's pristine truth.
    # dt = 0 (the default) skips the advance entirely: no drift draws consumed,
    # no scheduled jumps fired — static truth.
    soc.dt > 0 && advance!(soc.twin, soc.dt)
    return blobs
end

@testitem "TwinSoc executes the soc verbs over the twin's current truth (family seam)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using LinearAlgebra
        # The twin soc is extension-defined: reach it through its canonical handle.
        TwinSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).TwinSoc
        @test TwinSoc <: Strumento.AbstractSoc   # pluggable wherever the mock plugs in

        # The toy family (test-side): a QuantumSystem built from the twin's
        # CURRENT truth — two σx drives for the two envelope quadratures.
        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        toy_family(truth) = QuantumSystem(truth[:omega] * σz, [σx, σx],
                                          [truth[:drive_bound], truth[:drive_bound]])

        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "toy.md")
        twin = instantiate(fixture; drift = DriftPlan(), seed = 0xC0FFEE)

        # families is keyed by the RECORD's family field — dispatch, not registry
        soc = TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
                      families = Dict("toy" => toy_family),
                      exact = true, dac_rate = 20.0)

        # the fixed golden pulse — the MockSoc golden fixture's deterministic shape
        N = 11; T = 5.0
        times = collect(range(0.0, T, length = N))
        vals = 0.1 .* permutedims(hcat(sin.(range(0.0, 2.4π, length = N)),
                                       cos.(range(0.3π, 1.7π, length = N))))
        pulse = LinearSplinePulse(vals, times)
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive = 1, q_drive = 2)]; n_drives = 2)

        raw = execute!(soc, pulse, map, [11, 101])

        # IQ blobs packed exactly the way MockSoc packs them (real data, zero imag)
        @test length(raw) == 2
        @test raw[1] isa Vector{ComplexF64}
        @test all(iszero.(imag.(raw[1])))
        pops = real.(raw[2])
        @test length(pops) == 2
        @test all(pops .≥ 0) && all(pops .≤ 1)
        @test sum(pops) ≈ 1.0 atol = 1e-9    # confusion maps probabilities to probabilities

        # pluggable wherever the mock plugs in: downstream readout is unchanged
        ms = iq_to_measurements(raw, b -> real.(b), [11, 101])
        @test ms[1].data == real.(raw[1])
        @test ms[2].index == 101

        # the response is imperfect BY CONSTRUCTION: the exact (confusion-remap)
        # blob at the final knot is NOT the raw rollout population vector
        # (captured direct values: raw 0.9552991750369558 → confused 0.9379812245347385)
        @test real.(raw[2]) ≈ [0.9379812245347385, 0.06201877546526239] atol = 1e-12
        @test real.(raw[2]) != [0.9552991750369558, 0.044700824963045074]

        # the default response is sampled (binomial shots): a valid probability
        # vector that deviates from the exact remap
        soc_s = TwinSoc(instantiate(fixture; drift = DriftPlan(), seed = 0xC0FFEE),
                        ComplexF64[1, 0], ComplexF64[0, 1];
                        families = Dict("toy" => toy_family), dac_rate = 20.0)
        raw_s = execute!(soc_s, pulse, map, [101])
        @test sum(real.(raw_s[1])) ≈ 1.0 atol = 1e-9
        @test real.(raw_s[1]) != real.(raw[2])
    end
end

@testitem "TwinSoc validates its seams with actionable errors" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using LinearAlgebra
        TwinSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).TwinSoc
        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        toy_family(truth) = QuantumSystem(truth[:omega] * σz, [σx, σx],
                                          [truth[:drive_bound], truth[:drive_bound]])
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "toy.md")

        # ── the record's confusion must be present and well-formed ──
        dir = mktempdir()
        function bad_record(name, noise_yaml)
            path = joinpath(dir, name)
            write(path, "---\ntype: device-twin\nid: bad-$name\nfamily: toy\n" *
                        "parameters:\n  omega: 1.0\n  drive_bound: 1.0\n" * noise_yaml *
                        "---\n# body\n")
            return path
        end
        cases = [
            ("no-noise.md",        "",                                                    "readout_confusion"),
            ("no-key.md",          "noise:\n  T1_us: {value: 65.0, estimate: true}\n",     "readout_confusion"),
            ("bare-matrix.md",     "noise:\n  readout_confusion: [[0.9, 0.1], [0.2, 0.8]]\n", "wrapped"),
            ("no-value-key.md",    "noise:\n  readout_confusion: {estimate: true}\n",       "value"),
            ("non-square.md",      "noise:\n  readout_confusion: {value: [[0.9, 0.1], [0.2]]}\n", "square"),
            ("row-sums.md",        "noise:\n  readout_confusion: {value: [[0.9, 0.2], [0.1, 0.8]]}\n", "row"),
            ("negative.md",        "noise:\n  readout_confusion: {value: [[1.1, -0.1], [0.0, 1.0]]}\n", "≥ 0"),
        ]
        for (name, noise_yaml, needle) in cases
            local twin = instantiate(bad_record(name, noise_yaml); drift = DriftPlan(), seed = 1)
            local err = try
                TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
                        families = Dict("toy" => toy_family)); nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin(needle, sprint(showerror, err))
        end

        # ── family dispatch: a record family with no builder is named loudly ──
        twin = instantiate(fixture; drift = DriftPlan(), seed = 1)
        err = try
            TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
                    families = Dict("other" => toy_family)); nothing
        catch e
            e
        end
        @test err isa ErrorException
        msg = sprint(showerror, err)
        @test occursin("toy", msg)          # the record's family, named
        @test occursin("other", msg)        # the known families, listed

        # ── shots / dt bounds ──
        @test_throws ErrorException TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
                                            families = Dict("toy" => toy_family), shots = 0)
        @test_throws ErrorException TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
                                            families = Dict("toy" => toy_family), dt = -1.0)

        # ── the confusion must match the measurement dimension (at respond time) ──
        # a 3-level builder against the toy record's 2×2 confusion
        σx3 = zeros(ComplexF64, 3, 3); σx3[1, 2] = σx3[2, 1] = 1.0
        big_family(truth) = QuantumSystem(truth[:omega] * diagm([1.0, 0.0, -1.0]),
                                          [σx3], [truth[:drive_bound]])
        soc3 = TwinSoc(twin, ComplexF64[1, 0, 0], ComplexF64[0, 0, 1];
                       families = Dict("toy" => big_family), exact = true, dac_rate = 20.0)
        N = 11
        pulse = LinearSplinePulse(0.1 .* randn(1, N), collect(range(0.0, 5.0, length = N)))
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive = 1)]; n_drives = 1)
        err = try
            execute!(soc3, pulse, map, [N]); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("measurement dimension", sprint(showerror, err))
    end
end

@testitem "TwinSoc response: confusion + binomial shots at the expected statistics (seeded)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using Statistics
        TwinSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).TwinSoc
        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        toy_family(truth) = QuantumSystem(truth[:omega] * σz, [σx, σx],
                                          [truth[:drive_bound], truth[:drive_bound]])
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "toy.md")
        twin = instantiate(fixture; drift = DriftPlan(), seed = 0xBEEF)
        soc = TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
                      families = Dict("toy" => toy_family),
                      shots = 512, dac_rate = 20.0)

        # the fixed golden pulse (the MockSoc golden fixture's shape)
        N = 11; T = 5.0
        times = collect(range(0.0, T, length = N))
        vals = 0.1 .* permutedims(hcat(sin.(range(0.0, 2.4π, length = N)),
                                       cos.(range(0.3π, 1.7π, length = N))))
        pulse = LinearSplinePulse(vals, times)
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive = 1, q_drive = 2)]; n_drives = 2)

        # The exact response for THIS pulse at the final knot, captured from the
        # DIRECT Piccolo rollout + the record's confusion before implementation:
        # q = Cᵀ p, p = [0.9552991750369558, 0.044700824963045074].
        q = [0.9379812245347385, 0.06201877546526239]

        K = 40
        freq0 = Float64[]
        for _ in 1:K
            blob = execute!(soc, pulse, map, [101])[1]
            r = real.(blob)
            # a sampled blob IS shot counts / shots: exact dyadic multiples of 1/512
            @test all(x -> 512 * x == round(Int, 512 * x), r)
            @test sum(r) == 1.0
            push!(freq0, r[1])
        end

        σ = sqrt(q[1] * (1 - q[1]) / soc.shots)          # binomial(512, q) per-acquire std
        σ_mean = σ / sqrt(K)                              # std of the K-average

        # the empirical mean centers on the exact response (the confusion remap)
        @test abs(mean(freq0) - q[1]) < 4 * σ_mean
        # the deviation's SCALE matches binomial(shots, q) — not just its center
        @test std(freq0) ≈ σ rtol = 0.25
        # imperfect by construction: every seeded blob deviates from the exact
        # response, and stays within binomial bounds
        @test all(f -> f != q[1], freq0)
        @test all(f -> abs(f - q[1]) < 5σ, freq0)
    end
end

@testitem "TwinSoc drift: nonzero dt evolves truth between acquires; default static" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        TwinSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).TwinSoc
        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        toy_family(truth) = QuantumSystem(truth[:omega] * σz, [σx, σx],
                                          [truth[:drive_bound], truth[:drive_bound]])
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "toy.md")
        N = 11; T = 5.0
        times = collect(range(0.0, T, length = N))
        vals = 0.1 .* permutedims(hcat(sin.(range(0.0, 2.4π, length = N)),
                                       cos.(range(0.3π, 1.7π, length = N))))
        pulse = LinearSplinePulse(vals, times)
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive = 1, q_drive = 2)]; n_drives = 2)

        # advance-after semantics: acquire k measures truth at (k-1)·dt — the
        # FIRST acquire sees the record's pristine truth. Ramp(0.1/day), dt = 1.
        plan = DriftPlan(:omega => [Ramp(rate = 0.1)])
        twin = instantiate(fixture; drift = plan, seed = 0xC0FFEE)
        soc = TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
                      families = Dict("toy" => toy_family),
                      exact = true, dt = 1.0, dac_rate = 20.0)

        blob1 = execute!(soc, pulse, map, [11])[1]
        blob2 = execute!(soc, pulse, map, [11])[1]

        # acquire 1 measures the PRISTINE record truth — captured direct values
        # (transport tolerance as elsewhere: the literals crossed runners 1–5
        # ulp on CI run 33344813818 — hardware rotation, not semantics).
        @test isapprox(blob1,
                       [ComplexF64(0.9788483456466464 + 0.0im),
                        ComplexF64(0.021151654353354598 + 0.0im)];
                       rtol = 1e-13, atol = 1e-15)
        # acquire 2 measures truth aged one dt (ω = 1.0 + 0.1·1.0) — captured
        @test isapprox(blob2,
                       [ComplexF64(0.9788684314249929 + 0.0im),
                        ComplexF64(0.021131568575006088 + 0.0im)];
                       rtol = 1e-13, atol = 1e-15)
        # drift is real: consecutive acquires against the SAME pulse differ
        @test blob1 != blob2
        # the twin's clock advanced once per acquire
        @test soc.twin.t == 2.0
        # drift moved truth (two advances: 1.0 → 1.1 → 1.1+0.1), never belief —
        # the core invariant (≈: the Ramp ladder's float arithmetic)
        @test soc.twin.truth[:omega] ≈ 1.2
        @test believed(soc.twin)["omega"] == 1.0

        # dt defaults to STATIC (zero): a drift plan is installed, but the
        # advance is SKIPPED entirely — a jump scheduled at t = 0 must not
        # fire on every acquire — so consecutive acquires are identical and
        # the clock never moves.
        jump_plan = DriftPlan(:omega => [JumpSchedule(times = [0.0], deltas = [0.5])])
        twin0 = instantiate(fixture; drift = jump_plan, seed = 0xC0FFEE)
        soc0 = TwinSoc(twin0, ComplexF64[1, 0], ComplexF64[0, 1];
                       families = Dict("toy" => toy_family), exact = true, dac_rate = 20.0)
        b1 = execute!(soc0, pulse, map, [11])[1]
        b2 = execute!(soc0, pulse, map, [11])[1]
        b3 = execute!(soc0, pulse, map, [11])[1]
        @test b1 == b2 && b2 == b3
        @test b1 == blob1                    # static == the pristine golden
        @test soc0.twin.t == 0.0             # the clock never moved
        @test soc0.twin.truth[:omega] == 1.0  # the scheduled jump never fired
    end
end

@testitem "TwinSoc exact mode == direct QuantumSystem rollout (equivalence, golden)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        using Piccolo.Quantum.Pulses: get_knot_times
        ext = Base.get_extension(Strumento, :StrumentoPiccoloExt)
        TwinSoc = ext.TwinSoc
        populations = ext.populations
        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        toy_family(truth) = QuantumSystem(truth[:omega] * σz, [σx, σx],
                                          [truth[:drive_bound], truth[:drive_bound]])
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "toy.md")
        # drift OFF (empty plan; dt defaults to 0) + exact response
        twin = instantiate(fixture; drift = DriftPlan(), seed = 0xC0FFEE)
        soc = TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
                      families = Dict("toy" => toy_family),
                      exact = true, dac_rate = 20.0)

        N = 11; T = 5.0
        times = collect(range(0.0, T, length = N))
        vals = 0.1 .* permutedims(hcat(sin.(range(0.0, 2.4π, length = N)),
                                       cos.(range(0.3π, 1.7π, length = N))))
        pulse = LinearSplinePulse(vals, times)
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive = 1, q_drive = 2)]; n_drives = 2)
        indices = [11, 101]

        raw = execute!(soc, pulse, map, indices)

        # (a) GOLDEN PIN — captured from the DIRECT Piccolo rollout (same
        # system from the record's pristine truth, same played pulse, same
        # measurement function) + the record's confusion, BEFORE TwinSoc was
        # implemented, on the-feynmachine (i9-12900KS, Julia 1.12.5) — bit-exact
        # there. TRANSPORT TOLERANCE (cross-environment form, run 33344813818):
        # CI run 33320865313 (PR #19) reproduced captured literals like these
        # bit-exact on Julia 1.12.7; CI run 33344813818 (PR #23) — same Julia,
        # same resolution — drifted them 1–5 ulp (ubuntu-latest runner hardware
        # rotation: multi-microarch vectorized paths differ per CPU). The
        # literal carries isapprox(rtol=1e-13, atol=1e-15) — ~200× above the
        # largest observed drift (5.1e-16 rel), ~4 orders below a semantic
        # forward-model change (≥1e-9). The in-test mirror (b) below stays
        # `==`: CI itself proved it box-immune on the failing run.
        @test isapprox(raw,
                       [ComplexF64[0.9788483456466464 + 0.0im, 0.021151654353354598 + 0.0im],
                        ComplexF64[0.9379812245347385 + 0.0im, 0.06201877546526239 + 0.0im]];
                       rtol = 1e-13, atol = 1e-15)

        # (b) the direct forward model computed HERE from public pieces — the
        # same translation, the same played-pulse reconstruction, the same
        # rollout, the same measurement function, the same confusion remap.
        prog = pulse_to_envelopes(pulse, map, 20.0, indices)
        ctrls = zeros(Float64, prog.n_drives, length(prog.times))
        for (gen_ch, i_drive, q_drive) in prog.routing
            idata, qdata = prog.envelopes[gen_ch]
            ctrls[i_drive, :] .= idata
            q_drive === nothing || (ctrls[q_drive, :] .= qdata)
        end
        recon = LinearSplinePulse(ctrls, prog.times)
        direct = KetTrajectory(toy_family(twin.truth), recon,
                               ComplexF64[1, 0], ComplexF64[0, 1])
        kt = get_knot_times(recon)
        rows = twin.record.noise["readout_confusion"]["value"]
        C = Matrix{Float64}([rows[i][j] for i in eachindex(rows), j in eachindex(rows)])
        confuse(p) = [sum(C[i, j] * p[i] for i in eachindex(p)) for j in eachindex(p)]
        expected = [ComplexF64.(confuse(populations(ket_to_iso(direct(kt[k])))))
                    for k in indices]
        @test raw == expected

        # (c) the degenerate-twin relationship, demonstrated (not re-derived):
        # the direct rollout's RAW populations are MockSoc's own golden blobs
        # (bit-exact captures — its pinned forward model on this very pulse and
        # system shape). TwinSoc with an identity confusion and dt = 0 would
        # BE MockSoc; the confusion is the only difference. Same transport
        # tolerance as (a): the literals crossed runners 1–5 ulp on
        # 33344813818 (hardware rotation), a semantic change is ≥1e-9.
        pops11 = populations(ket_to_iso(direct(kt[11])))
        pops101 = populations(ket_to_iso(direct(kt[101])))
        @test isapprox(pops11, [0.9987748357943047, 0.0012251642056963555];
                       rtol = 1e-13, atol = 1e-15)
        @test isapprox(pops101, [0.9552991750369558, 0.044700824963045074];
                       rtol = 1e-13, atol = 1e-15)
    end
end

@testitem "TwinSoc replay: identical seeds → identical sequences bit-exact (drift + shots)" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing
        @info "skipping: no Piccolo in this environment (Piccolo-extension surface)"
        @test true
    else
        using Piccolo
        TwinSoc = Base.get_extension(Strumento, :StrumentoPiccoloExt).TwinSoc
        σx = ComplexF64[0 1; 1 0]; σz = ComplexF64[1 0; 0 -1]
        toy_family(truth) = QuantumSystem(truth[:omega] * σz, [σx, σx],
                                          [truth[:drive_bound], truth[:drive_bound]])
        fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "toy.md")
        plan = DriftPlan(:omega => [OrnsteinUhlenbeck(theta = 0.1, sigma = 0.2, mu = 1.0)])
        N = 11; T = 5.0
        times = collect(range(0.0, T, length = N))
        vals = 0.1 .* permutedims(hcat(sin.(range(0.0, 2.4π, length = N)),
                                       cos.(range(0.3π, 1.7π, length = N))))
        pulse = LinearSplinePulse(vals, times)
        map = QickChannelMap([QickGenChannel(0, 5e9; i_drive = 1, q_drive = 2)]; n_drives = 2)

        # the full stochastic path: OU drift ON (dt = 1), shot sampling ON
        # (64 shots), two knots per acquire, six acquires. FRESH process
        # objects each call — replay must not depend on shared state.
        function replay(seed)
            twin = instantiate(fixture; drift = plan, seed = seed)
            soc = TwinSoc(twin, ComplexF64[1, 0], ComplexF64[0, 1];
                          families = Dict("toy" => toy_family),
                          shots = 64, dt = 1.0, dac_rate = 20.0)
            omegas = Float64[]
            blobs = Vector{Vector{ComplexF64}}[]
            for _ in 1:6
                push!(blobs, execute!(soc, pulse, map, [11, 101]))
                push!(omegas, soc.twin.truth[:omega])
            end
            return omegas, blobs
        end

        # same seed → identical, always (fresh twins, fresh rngs, fresh socs)
        o1, b1 = replay(0x5EED)
        o2, b2 = replay(0x5EED)
        @test o1 == o2
        @test b1 == b2
        # different seed → a different measurement sequence
        o3, b3 = replay(0xFEED)
        @test o3 != o1
        @test b3 != b1

        # GOLDEN PIN — captured from the implemented rng-draw contract (the
        # ONE stochastic source drives shot uniforms and OU drift draws
        # interleaved: per acquire [shots: knots in order, shots in order]
        # then [drift: plan order]; the deterministic pieces were captured
        # pre-implementation in the drift and equivalence pins). `==`, no
        # tolerance: any deviation is a behavior change, never noise.
        @test o1 == [1.0037869394647132, 0.8864476509337655, 1.0193670001043336,
                     0.907558804064814, 1.004616903851481, 0.9007921139196429]
        @test b1 == [
            [ComplexF64[0.96875 + 0.0im, 0.03125 + 0.0im],
             ComplexF64[0.96875 + 0.0im, 0.03125 + 0.0im]],
            [ComplexF64[0.953125 + 0.0im, 0.046875 + 0.0im],
             ComplexF64[0.953125 + 0.0im, 0.046875 + 0.0im]],
            [ComplexF64[0.984375 + 0.0im, 0.015625 + 0.0im],
             ComplexF64[0.9375 + 0.0im, 0.0625 + 0.0im]],
            [ComplexF64[0.96875 + 0.0im, 0.03125 + 0.0im],
             ComplexF64[0.96875 + 0.0im, 0.03125 + 0.0im]],
            [ComplexF64[0.984375 + 0.0im, 0.015625 + 0.0im],
             ComplexF64[0.859375 + 0.0im, 0.140625 + 0.0im]],
            [ComplexF64[1.0 + 0.0im, 0.0 + 0.0im],
             ComplexF64[0.9375 + 0.0im, 0.0625 + 0.0im]],
        ]
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

# ──── The bosonic family (issue #21) ──────────────────────────────────────────
include("bosonic_family.jl")

end # module StrumentoPiccoloExt