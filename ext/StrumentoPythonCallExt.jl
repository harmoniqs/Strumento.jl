# StrumentoPythonCallExt — the PythonCall-triggered package extension (issue #16).
#
# The real-board delegation soc lives here: `StrumentoSoc` hands a solved pulse
# to the Python `strumento` framework over PythonCall (the option-(a) seam).
# The bring-up compile bridge (issue #31, M4a) also lives here: `BringupBridge`
# loads the committed demo-class device instance and compiles the cqed pack's
# experiments to the `CompiledJob` wire form — Python never executes the job
# (the payload crosses the wire to the twin job server, or to a real board).
# The extension loads exactly when PythonCall is loaded; the base package
# references no PythonCall name. Julia's extension semantics (1.12): extension
# exports do NOT surface on the parent module — the soc contract verbs the
# base declares duck-typed (`execute!`) gain their delegation methods here, so
# bare-name calls work in every configuration; the extension-defined TYPE
# (`StrumentoSoc`) is reached through
# `Base.get_extension(Strumento, :StrumentoPythonCallExt)`.
#
# The soc contract is honored with a DUCK-TYPED `execute!` pulse argument: this
# extension's only trigger is PythonCall, so no Piccolo name may appear here
# either — the pulse sampling goes through the base pulse-sampling seam
# (`Strumento.pulse_duration` / `Strumento.sample_controls`), whose typed
# methods the Piccolo extension adds when Piccolo is also loaded. Without
# Piccolo, calling the seam errors actionably (the base stubs).
#
# Testitems in this file guard on `Base.identify_package("PythonCall")` and skip
# cleanly in configurations without the trigger.
module StrumentoPythonCallExt

import Strumento
import Strumento: AbstractSoc, execute!, dac_rate, adc_rate, QickChannelMap
using TestItems

using PythonCall

export StrumentoSoc
export BringupBridge

# ──── BringupBridge — the bring-up compile surface (issue #31) ────────────────
# The in-process Python bridge of the M4a rehearsal chain: the committed
# demo-class DEVICE instance loaded through Python `strumento`, the cqed
# pack's own pulse factories and the core compile path, and the `CompiledJob`
# wire form out — one JSON-safe dict per requested measurement. Python never
# EXECUTES anything: the payload crosses the wire to the twin job server
# (or, pointed at a real transport, to a board) — the production shape from
# day one.
#
# This extension's only trigger is PythonCall, so the bridge reaches the rig
# surface (the Piccolo+JSON bring-up extension) LAZILY at runtime — the same
# sibling-reach pattern the job server uses for TwinSoc. The geometry
# parameters come from the CALLER (the bring-up procedure owns the design);
# the envelope math goes through numpy so the bridge and the committed
# fixture-generation script share one bit-identical code path.

"""The v1 wire frame boundary, stated once: the twin's family systems are
rotating-frame models at the drive frequency, so a payload's CARRIER is the
frame (the twin's response is carrier-invariant) and the swept detuning must
ride the ENVELOPE. The bridge's comb probe is exactly that — a shaped Ancilla
probe whose Arb envelope rotates at the swept point frequency at a fixed
carrier; a carrier-swept const probe (the stock spectroscopy experiments'
swept axis) is frame-invisible to the v1 twin, and a frequency-stepped
CloseLoop ladder is outside the server's v1 swept-amp form. See
`compile_comb_point`."""
const BRIDGE_FRAME_NOTE = "the v1 wire frame boundary (the carrier is the frame; the swept detuning rides the envelope)"

"""
    BringupBridge(device_path; overlay_id = "") -> BringupBridge

The bring-up compile bridge: the committed demo-class device instance (a
cqed pack instance with cavity modes — the multimode class) loaded
in-process through Python `strumento`. `strumento` is imported lazily; an
actionable error is raised if the Python package is unavailable. The bridge
compiles requested measurements to the `CompiledJob` wire form:

- `compile_comb_point(bridge; ...)` — the resonator-sweep procedure's
  per-point comb job: the cavity displacement (the cqed pack's
  alpha-calibrated `displace_alpha` mode-library factory) followed by the
  shaped ancilla probe rotating at the point's frequency (see
  `BRIDGE_FRAME_NOTE`).
- `compile_cavity_point(bridge; ...)` — the stock
  `strumento.packs.cqed.experiments.cavity_spectroscopy.CavitySpectroscopy`
  experiment compiled at a fixed frequency: the seam's named target, the
  same compile + wire path exercised on the pack's own cavity-probe
  construction.
- `compile_rabi_sweep(bridge; ...)` — the pi-gain procedure's gain ladder
  (issue #33): the stock cqed `AmplitudeRabi` experiment — the ge_pi gauss
  swept in lab-native gain int codes — compiled to ONE wire payload whose
  swept axis rides the CloseLoop gain ladder (the v1-wire swept form the
  twin job server decodes).
- `compile_ge_pi(bridge; gain_frac = nothing, ...)` — the ge_pi factory
  compiled at one point: the downstream consumption path. Without
  `gain_frac`, the device calibration's own gain (the UNCALIBRATED
  baseline); with it, the believed pi_gain (the belief-scaled factory —
  `dev.qubit.ge_pi(gain = frac)` speaks v2 fractions directly).

All are deterministic given the device and the geometry (verified across
fresh processes; the committed fixture payloads in
`test/fixtures/_fixtures/` are this bridge's output, regenerable by the
committed `generate_rehearsal_payloads.py`).
"""
mutable struct BringupBridge
    strumento::Py             # the imported `strumento` module
    device::Py                # the loaded Device (Python)
    overlay_id::String
end

function BringupBridge(device_path::AbstractString; overlay_id::AbstractString = "")
    # Embedded-Python hygiene: a bare interpreter defaults to ASCII and
    # chokes on the µ/– in device YAMLs — force UTF-8 before it starts.
    ENV["PYTHONUTF8"] = "1"
    st = try
        pyimport("strumento")
    catch e
        error("BringupBridge requires the Python `strumento` package (the " *
              "reference bring-up env; see test/fixtures/_fixtures/" *
              "generate_rehearsal_payloads.py). `pyimport(\"strumento\")` " *
              "failed: $e")
    end
    isfile(device_path) || error(
        "BringupBridge: the device instance $device_path does not exist — the " *
        "bridge loads committed fixtures (the rig carries the path)")
    dev = try
        st.Device.load(string(device_path))
    catch e
        error("BringupBridge: Device.load($(device_path)) failed: $e")
    end
    return BringupBridge(st, dev, String(overlay_id))
end

# the JSON-safe hop: a Py object -> a canonical JSON string -> a Julia Dict.
# `json.dumps` on the Python side and `JSON.parse` on this side agree on
# primitives by construction (the D14 payload is JSON-safe all the way down).
# JSON.jl is a weakdep of Strumento; it is loaded on demand here (PythonCall
# is this extension's only trigger) and errors actionably when absent.
function _py_to_julia_dict(obj::Py)
    Base.identify_package("JSON") === nothing && error(
        "BringupBridge: JSON.jl is not in this environment — the CompiledJob " *
        "wire form is JSON by the D14 contract (add JSON and load it)")
    JSONjl = Base.require(Base.identify_package("JSON"))
    json = pyimport("json")
    return JSONjl.parse(pyconvert(String, json.dumps(obj)))
end

"""
    compile_comb_point(bridge; f_kHz, displacement_alpha, T_disp_us, T_spec_us,
                       probe_gain, qubit_freq_mhz, reps, soft_avgs = 1) -> Dict

Compile the resonator sweep's per-point comb job (the `CompiledJob` wire
form): the cavity displacement to `|beta| = displacement_alpha` (the cqed
pack's alpha-calibrated mode-library factory, calibration-fed) followed by
the shaped ancilla π-pulse (`probe_gain` = the peak drive fraction, the
shaped flip angle π) whose Arb envelope rotates at `f_kHz` — the swept
detuning riding the envelope, the v1 frame boundary (`BRIDGE_FRAME_NOTE`).

The geometry parameters come from the caller (the bring-up procedure owns
the design); the envelope math goes through numpy — the same code path as
the committed fixture-generation script, so the bridge's output and the
committed fixtures are bit-identical.
"""
function compile_comb_point(bridge::BringupBridge;
                            f_kHz,
                            displacement_alpha,
                            T_disp_us,
                            T_spec_us,
                            probe_gain,
                            qubit_freq_mhz,
                            reps::Integer,
                            soft_avgs::Integer = 1)
    np = pyimport("numpy")
    pulses = pyimport("strumento.core.pulses")
    LineRef = pyimport("strumento.core.wiring").LineRef
    StrumentoProgram = pyimport("strumento.core.program").StrumentoProgram

    dev = bridge.device
    fs = pyconvert(Float64, dev.soccfg_snapshot["gens"][3]["fs"])
    disp = dev.manipulate.displace_alpha(pyconvert(Py, displacement_alpha))
    n0 = pyconvert(Py, Int(round(T_disp_us * fs)))
    n1 = pyconvert(Py, Int(round(T_spec_us * fs)))
    t = np.arange(n1) / fs
    env = np.sin(np.pi * t / T_spec_us)^2 * np.exp(2im * np.pi * (f_kHz / 1000.0) * t)
    idata = np.concatenate((np.zeros(n0), np.real(env)))
    qdata = np.concatenate((np.zeros(n0), np.imag(env)))
    peak = max(1.0, pyconvert(Float64, np.max(np.hypot(idata, qdata))))
    probe = pulses.Pulse(
        line = LineRef("qubit", "drive"), freq_mhz = qubit_freq_mhz,
        gain = probe_gain,
        envelope = pulses.Arb(idata = (idata / peak).tolist(),
                              qdata = (qdata / peak).tolist()),
        label = "comb_probe",
    )
    seq = pulses.Seq().play(disp).play(probe).measure()
    prog = StrumentoProgram(dev; seq = seq, reps = pyconvert(Py, Int(reps)))
    job = prog.to_compiled_job(overlay_id = bridge.overlay_id,
                               soft_avgs = pyconvert(Py, Int(soft_avgs)))
    return _py_to_julia_dict(job.to_wire())
end

"""
    compile_cavity_point(bridge; freq_mhz, reps, soft_avgs = 1) -> Dict

Compile the stock cqed `CavitySpectroscopy` experiment at a FIXED frequency
(the `CompiledJob` wire form): the seam's named target through the pack's own
sequence construction — its probe pulse (the cavity mode's line, the
experiment's probe gain, a `Const` envelope) and its `Measure` op, compiled
by the same `StrumentoProgram` path. No sweep: the experiment's swept
frequency axis is the stock form's carrier sweep — frame-invisible to the v1
twin (`BRIDGE_FRAME_NOTE`) and outside the server's v1 ladder form — so the
seam-target job runs at one point, and the RESPONSE through the twin's
ancilla marginal is the honest flat physics (cavity transmission is not a
v1-twin observable; the resonator sweep's dispersive signature rides the
comb).
"""
function compile_cavity_point(bridge::BringupBridge;
                              freq_mhz,
                              reps::Integer,
                              soft_avgs::Integer = 1)
    CavitySpectroscopy = pyimport(
        "strumento.packs.cqed.experiments.cavity_spectroscopy").CavitySpectroscopy
    StrumentoProgram = pyimport("strumento.core.program").StrumentoProgram

    exp = CavitySpectroscopy(bridge.device, freqs = pyconvert(Py, freq_mhz), points = 1)
    seq, _ = exp.sequence()
    axes = exp.axes()
    prog = StrumentoProgram(bridge.device; seq = seq, axes = axes,
                            reps = pyconvert(Py, Int(reps)))
    job = prog.to_compiled_job(overlay_id = bridge.overlay_id,
                               soft_avgs = pyconvert(Py, Int(soft_avgs)))
    return _py_to_julia_dict(job.to_wire())
end

"""
    compile_rabi_sweep(bridge; gains_start, gains_stop, points, reps,
                       soft_avgs = 1) -> Dict

Compile the pi-gain procedure's gain ladder (issue #33, the `CompiledJob`
wire form): the stock cqed `AmplitudeRabi` experiment —
`dev.qubit.ge_pi(gain = Sweep(gains_start → gains_stop))`, the ge_pi gauss
swept in LAB-NATIVE gain int codes over `points` points on the declared
"amp" loop axis — through the pack's own sequence construction and the
core compile path. ONE payload comes back: the swept axis rides the CloseLoop
gain ladder (qick's encoding-A wave-memory form, the v1-wire swept axis the
twin job server decodes), the wave's gain stepping
`(gains_stop − gains_start)/(points − 1)` codes per expt — an integer by
construction of the declared span (the procedure refuses a non-integral
ladder step: a fractional step would quantize differently per point and the
decoded axis would not be the declared one).
"""
function compile_rabi_sweep(bridge::BringupBridge;
                           gains_start::Integer,
                           gains_stop::Integer,
                           points::Integer,
                           reps::Integer,
                           soft_avgs::Integer = 1)
    points ≥ 2 || error(
        "compile_rabi_sweep: points must be ≥ 2 (got $points) — a ladder needs " *
        "at least its two endpoints to step between")
    (gains_stop - gains_start) % (points - 1) == 0 || error(
        "compile_rabi_sweep: the gain span ($(gains_start) → $(gains_stop)) does not " *
        "divide into $(points) points — the CloseLoop ladder steps integer gain " *
        "codes, and a fractional step $(div(gains_stop - gains_start, points - 1)) " *
        "would quantize differently per point (the decoded axis would not be " *
        "the declared one)")
    gains_start ≥ 0 || error(
        "compile_rabi_sweep: gains_start must be ≥ 0 (got $gains_start) — a Rabi " *
        "sweep starts at zero drive")
    gains_stop > gains_start || error(
        "compile_rabi_sweep: gains_stop ($gains_stop) must exceed gains_start " *
        "($gains_start) — the sweep must rise")

    Sweep = pyimport("strumento.core.sweeps").Sweep
    AmplitudeRabi = pyimport(
        "strumento.packs.cqed.experiments.amplitude_rabi").AmplitudeRabi
    StrumentoProgram = pyimport("strumento.core.program").StrumentoProgram

    exp = AmplitudeRabi(bridge.device,
                        gains = Sweep(start = pyconvert(Py, Int(gains_start)),
                                      stop = pyconvert(Py, Int(gains_stop)),
                                      on = "amp"),
                        points = pyconvert(Py, Int(points)))
    seq, _ = exp.sequence()
    axes = exp.axes()
    prog = StrumentoProgram(bridge.device; seq = seq, axes = axes,
                            reps = pyconvert(Py, Int(reps)))
    job = prog.to_compiled_job(overlay_id = bridge.overlay_id,
                               soft_avgs = pyconvert(Py, Int(soft_avgs)))
    return _py_to_julia_dict(job.to_wire())
end

"""
    compile_ge_pi(bridge; gain_frac = nothing, reps, soft_avgs = 1) -> Dict

Compile ONE ge_pi pulse point (the `CompiledJob` wire form): the downstream
consumption path of the pi-gain calibration (issue #33). `gain_frac` is the
gain FRACTION the believed `pi_gain` carries — the factory's explicit
override speaks v2 fractions directly (`dev.qubit.ge_pi(gain = frac)`),
the production shape: Python compiles consume Julia-measured calibrations.
Without `gain_frac`, the device calibration's own gain (int code → fraction,
the UNCALIBRATED baseline the Rabi procedure exists to correct).
"""
function compile_ge_pi(bridge::BringupBridge;
                       gain_frac = nothing,
                       reps::Integer,
                       soft_avgs::Integer = 1)
    pulses = pyimport("strumento.core.pulses")
    StrumentoProgram = pyimport("strumento.core.program").StrumentoProgram

    dev = bridge.device
    gain = gain_frac === nothing ? pybuiltins.None : pyconvert(Py, Float64(gain_frac))
    seq = pulses.Seq().play(dev.qubit.ge_pi(gain = gain)).measure()
    prog = StrumentoProgram(dev; seq = seq, reps = pyconvert(Py, Int(reps)))
    job = prog.to_compiled_job(overlay_id = bridge.overlay_id,
                               soft_avgs = pyconvert(Py, Int(soft_avgs)))
    return _py_to_julia_dict(job.to_wire())
end

# ──── StrumentoSoc ───────────────────────────────────────────────────────────
# The real-board path, delegating to the Python `strumento` package over
# PythonCall. This is the option-(a) seam (spec D18 / §16.4): Julia does NOT
# assemble an AveragerProgramV2 itself; it hands the solved pulse to Python
# `strumento`, which owns the pulse-IR → compile → acquire → reduce path. One
# source of truth (Python), a Julia face here.
#
# `strumento` is imported LAZILY inside the constructor (runtime, not load-time), so
# loading this extension never initializes the interpreter and the whole MockSoc
# path runs without Python. The delegation body expresses the concrete calls, but
# the exact device wiring / drive_map / reduce conventions are finalized against
# a board with the QICK collaboration — so this path is NOT exercised in CI
# (constructing a StrumentoSoc requires the Python package).

"""
    StrumentoSoc(device; drive_map, dac_rate, adc_rate, board=nothing)

Real board reached by delegating to the Python `strumento` framework via PythonCall.
`device` is a strumento device-instance YAML path (or a Python `Device` handle);
`drive_map` maps each Piccolo drive index to a `(drive_index, line, role, carrier_mhz)`
tuple naming the strumento wiring line/role and its carrier. On `execute!`, the played
pulse is handed to `strumento.from_solution` and run through a `StrumentoProgram` on the
board — Julia never assembles the program.

`strumento` (and `qick`) are imported lazily here; an actionable error is raised if the
Python package is unavailable. The delegation path is exercised end-to-end against the
Python-side mock (`MockQickSocV2`) by a test that runs when Python + strumento are
importable and skips cleanly otherwise — the pure-Julia CI lane stays pure. Real-board
acquisition remains a collaboration session.
"""
mutable struct StrumentoSoc <: AbstractSoc
    strumento::Py          # the imported `strumento` module
    device::Py             # a strumento Device (Python)
    board::Py              # the board soc (a qick soc / strumento MockQickSocV2), or py-None
    drive_map::Vector{Tuple{Int,String,String,Float64}}   # (drive_index, line, role, carrier_mhz)
    dac_rate::Float64
    adc_rate::Float64
end

function StrumentoSoc(device; drive_map::Vector{<:Tuple}, dac_rate::Real, adc_rate::Real,
                      board = nothing)
    st = try
        pyimport("strumento")
    catch e
        error("StrumentoSoc requires the Python `strumento` package in the board's " *
              "Python environment (the open QICK tProc-v2 framework this package is the " *
              "Julia face of). `pyimport(\"strumento\")` failed: $e")
    end
    dev = device isa Py ? device : st.Device.load(string(device))
    bd = board === nothing ? pybuiltins.None : board
    dm = Tuple{Int,String,String,Float64}[
        (Int(d), String(line), String(role), Float64(f)) for (d, line, role, f) in drive_map
    ]
    return StrumentoSoc(st, dev, bd, dm, Float64(dac_rate), Float64(adc_rate))
end

dac_rate(soc::StrumentoSoc) = soc.dac_rate
adc_rate(soc::StrumentoSoc) = soc.adc_rate

# execute! — hand the pulse to Python `strumento` (from_solution → program → acquire →
# reduce). This replaces the old inline-qick-assembly stub: strumento owns translation.
# The pulse argument is DUCK-TYPED (this extension's only trigger is PythonCall, so
# no Piccolo type may annotate it); sampling goes through the base pulse-sampling
# seam, whose typed methods the Piccolo extension provides.
#
# Knot semantics (the AbstractSoc contract; see MockSoc): `indices` are MeasurementModel
# knots into 1:N, and each knot's blob must be the IQ measured AT that knot's time. The
# delegated path honors that with ONE PROGRAM PER KNOT: the pulse is handed to
# `from_solution` TRUNCATED at the knot (`times[1:k]`, `controls[:, 1:k]`), a `Measure` op
# is appended (`from_solution` plays pulses only — the compiler declares readout channels
# only when it sees one), the program compiles and acquires, and the averaged IQ becomes
# that knot's blob. The old placeholder (repeat the final average per index) is gone.
function execute!(soc::StrumentoSoc, pulse, ::QickChannelMap,
                  indices::Vector{Int})
    T = Strumento.pulse_duration(pulse)
    nsamp = floor(Int, T * soc.dac_rate) + 1
    times = collect(range(0.0, T, length = nsamp))
    ctrls = Strumento.sample_controls(pulse, times)    # (n_drives, nsamp)

    LineRef = soc.strumento.LineRef
    py_drive_map = pydict()
    for (d, line, role, carrier) in soc.drive_map
        py_drive_map[line] = pytuple((LineRef(line, role), carrier))
    end

    StrumentoProgram = pyimport("strumento.core.program").StrumentoProgram
    from_solution = pyimport("strumento.core.pulses").from_solution
    gain_calib = _pi_pulse_reference(soc)

    blobs = Vector{Vector{ComplexF64}}(undef, length(indices))
    for (j, k) in enumerate(indices)
        (2 ≤ k ≤ nsamp) || error("StrumentoSoc.execute!: knot index $k outside the " *
            "playable pulse ($nsamp samples); knot 1 (t=0, before any evolution) has no " *
            "delegated readout — the mock path owns that case")
        knot_solution = pydict([
            "times" => pylist(times[1:k]),
            "controls" => pydict([line => pylist(ctrls[d, 1:k])
                                  for (d, line, role, _) in soc.drive_map]),
        ])
        seq = from_solution(knot_solution; drive_map = py_drive_map,
                            gain_calib = gain_calib, dac_rate = soc.dac_rate)
        seq.measure()   # pulses-only seq compiles with no readout channels otherwise
        prog = StrumentoProgram(soc.device; seq = seq, soc = soc.board)
        result = prog.acquire(soc.board, progress = false)
        blobs[j] = [_averaged_iq(result)]
    end
    return blobs
end

# The physical-amplitude → v2-fraction reference `from_solution` needs (issue #2): read
# from the loaded device's own calibration, never a Julia-supplied constant.
#
# The gain FRACTION comes from the device's own factory (`dev.qubit.ge_pi()`): Python owns
# the D23 int-code → fraction conversion and the soccfg `maxv` resolution (TransmonOps'
# `_maxv` walks the wiring), so this side never re-implements them. The Rabi rate uses the
# mean-rate convention from the stored π-pulse timing: a π rotation over the played window
# gives Ω/2π = 0.5 / T_π (MHz). This fixes a LINEAR ruler (frac per MHz) — exact for
# pulses of the calibration pulse's shape class; the shape-exact reference (peak-Rabi for
# the imported envelope's window) is a hardware-session refinement with the collaboration.
function _pi_pulse_reference(soc::StrumentoSoc)
    pi_pulse = soc.device.qubit.ge_pi()
    gain_frac = pyconvert(Float64, pi_pulse.gain)
    pc = soc.device.calib.qubit.pulses["pi_ge"]
    length_us = pyconvert(Float64, pc.length)
    sigma_us = pyconvert(Float64, pc.sigma)
    T_pi = length_us > 0 ? length_us : 6 * sigma_us   # gauss: played window ≈ 6σ
    T_pi > 0 || error("StrumentoSoc: the calibration π pulse has no usable duration " *
                      "(length=$length_us µs, sigma=$sigma_us µs)")
    return pyimport("strumento.packs.cqed.calibration").PiPulseReference(
        pi_gain_frac = gain_frac, pi_rabi_mhz = 0.5 / T_pi)
end

# A single readout channel's averaged acquisition → one IQ sample. With no swept axis the
# result is 1-D — shape (n_reads,) = (1,) on this path; the readout channel exists because
# `Measure` was appended (its absence fails earlier, at compile). astype first: the
# acquisition may carry float32 (the ADC's native width), which pyconvert will not widen.
function _averaged_iq(result::Py)
    np = pyimport("numpy")
    avgi = pyconvert(Vector{Float64}, np.asarray(result.avgi, dtype = "float64").reshape(-1))
    avgq = pyconvert(Vector{Float64}, np.asarray(result.avgq, dtype = "float64").reshape(-1))
    length(avgi) == 1 || error("StrumentoSoc: expected a single averaged readout, got " *
                               "avgi with $(length(avgi)) entries")
    return ComplexF64(avgi[1], avgq[1])
end

@testitem "StrumentoSoc is an AbstractSoc (type only; no Python/board in CI)" begin
    using Strumento
    if Base.identify_package("PythonCall") === nothing
        @info "skipping: no PythonCall in this environment (PythonCall-extension surface)"
        @test true
    else
        using PythonCall
        # The delegation type is extension-defined: extension exports do not
        # surface on the parent module, so reach it through its canonical handle.
        StrumentoSoc = Base.get_extension(Strumento, :StrumentoPythonCallExt).StrumentoSoc
        @test StrumentoSoc <: Strumento.AbstractSoc
        # Not constructed here: that needs the Python `strumento` package + a board, and
        # would initialize PythonCall's interpreter. The delegation path is validated by
        # the collaboration on hardware.
    end
end

@testitem "StrumentoSoc delegation runs end-to-end on the Python mock (skips without Python strumento)" begin
    using Strumento
    if Base.identify_package("PythonCall") === nothing || Base.identify_package("Piccolo") === nothing
        @info "skipping: the delegation end-to-end needs PythonCall AND Piccolo in this environment"
        @test true
    else
        using PythonCall
        using Piccolo
        # The delegation type is extension-defined: extension exports do not
        # surface on the parent module, so reach it through its canonical handle.
        StrumentoSoc = Base.get_extension(Strumento, :StrumentoPythonCallExt).StrumentoSoc
        # Embedded-Python hygiene: a bare interpreter (no shell locale) defaults to ASCII and
        # chokes on the µ/– in device YAMLs — force UTF-8 mode before the interpreter starts.
        ENV["PYTHONUTF8"] = "1"
        st = try
            pyimport("strumento")
        catch e
            @info "skipping: Python `strumento` not importable in this environment ($e)"
            nothing
        end
        if st === nothing
            @test true   # vacuous pass: the pure-Julia CI lane carries no Python strumento
        else
            fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
            board = pyimport("strumento.core.mock").MockQickSocV2.from_snapshot(
                joinpath(fixtures, "_fixtures", "soccfg_v2_testbench.json"))
            dev = st.Device.load(joinpath(fixtures, "loopback_demo", "device.yaml"))

            # a small smooth pulse on one drive, sized in the testbench gen's REAL clocking:
            # f_fabric 599.04 MHz with samps_per_clk 16 → envelopes need ≥48 samples to clear
            # qick's 3-fabric-cycle minimum. T = 0.3 µs at 599.04 samples/µs → 180 samples.
            times = collect(range(0.0, 0.3, length = 180))
            pulse = LinearSplinePulse(0.05 .* sin.(range(0, π, length = 180))', times)
            cmap = QickChannelMap([QickGenChannel(0, 5e3; i_drive = 1)]; n_drives = 1)
            soc = StrumentoSoc(dev; drive_map = [(1, "qubit", "drive", 4000.0)],
                               dac_rate = 599.04, adc_rate = 599.04, board = board)

            blobs = execute!(soc, pulse, cmap, [180])   # final knot only
            @test length(blobs) == 1
            @test length(blobs[1]) == 1
            @test isfinite(real(blobs[1][1])) && isfinite(imag(blobs[1][1]))
            # MockQickSocV2 yields zero-valued IQ: the assertion that matters is that the
            # pipeline produced a SHAPED single-read result — i.e. the Measure op made the
            # compiler declare a readout channel, and acquire returned through it.
            @test blobs[1][1] == 0.0 + 0.0im

            # per-knot truncation: two knots on the same pulse produce two acquisitions
            blobs2 = execute!(soc, pulse, cmap, [90, 180])
            @test length(blobs2) == 2
            # knot 1 (t=0) is refused loudly on the delegated path
            @test_throws ErrorException execute!(soc, pulse, cmap, [1])
        end
    end
end

# ──── BringupBridge testitems (issue #31) ─────────────────────────────────────
# Python-optional (the established precedent): the items guard on PythonCall
# in the environment AND the Python `strumento` package being importable,
# skipping cleanly otherwise — the pure-Julia CI lane carries no Python
# strumento, and the Julia-only bring-up coverage rides the committed
# fixture payloads through the same procedure code path.

@testitem "BringupBridge compiles the comb point in-process (python-optional)" begin
    using Strumento
    if Base.identify_package("PythonCall") === nothing
        @info "skipping: no PythonCall in this environment (PythonCall-extension surface)"
        @test true
    else
        using PythonCall
        BringupBridge = Base.get_extension(Strumento, :StrumentoPythonCallExt).BringupBridge
        ENV["PYTHONUTF8"] = "1"
        st = try
            pyimport("strumento")
        catch e
            @info "skipping: Python `strumento` not importable in this environment ($e)"
            nothing
        end
        if st === nothing
            @test true   # vacuous pass: the pure-Julia CI lane carries no Python strumento
        else
            fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
            bridge = BringupBridge(joinpath(fixtures, "multimode_rehearsal", "device.yaml");
                                   overlay_id = "rehearsal-v2")

            # the geometry of the committed design (the fixture script's constants)
            kwargs = (f_kHz = 298.4, displacement_alpha = sqrt(2.0), T_disp_us = 4.0,
                      T_spec_us = 10.0, probe_gain = 2π / 10000.0,
                      qubit_freq_mhz = 4.0, reps = 50, soft_avgs = 1)
            job = Base.get_extension(Strumento, :StrumentoPythonCallExt).compile_comb_point(
                bridge; kwargs...)

            # the payload is the D14 wire form: overlay_id + program + acquire,
            # the program carrying qick's own dump_prog keys
            @test sort!(collect(keys(job))) == ["acquire", "overlay_id", "program"]
            @test job["overlay_id"] == "rehearsal-v2"
            for key in ("envelopes", "gen_chs", "ro_chs", "waves", "prog_list",
                        "loop_dims", "avg_level")
                @test haskey(job["program"], key)
            end
            @test job["acquire"]["reps"] == 50
            @test job["acquire"]["expts"] === nothing      # per-point jobs: no sweep
            @test job["acquire"]["reads_per_shot"] == [1]
            # the two played generators: the qubit line (2) and the manipulate
            # cavity line (3) — the wiring map's channels
            @test sort([parse(Int, k) for k in keys(job["program"]["gen_chs"])]) == [2, 3]

            # in-process determinism: the identical compile is bit-identical
            # (the replay contract's compile half; `==`, within-process)
            again = Base.get_extension(Strumento, :StrumentoPythonCallExt).compile_comb_point(
                bridge; kwargs...)
            @test again == job

            # the bridge reproduces the COMMITTED fixture bit-exactly (the
            # fixture-generation script and this bridge share one numpy code
            # path; a strumento/qick upgrade that shifts a register code fails
            # here loudly = regenerate the fixtures)
            using JSON
            fixture = JSON.parsefile(joinpath(fixtures, "_fixtures",
                                              "comb_rehearsal_04.json"))
            at290 = Base.get_extension(Strumento, :StrumentoPythonCallExt).compile_comb_point(
                bridge; kwargs..., f_kHz = 290.0)
            @test at290 == fixture
        end
    end
end

@testitem "BringupBridge compiles the stock cqed cavity-spectroscopy experiment (python-optional)" begin
    using Strumento
    if Base.identify_package("PythonCall") === nothing
        @info "skipping: no PythonCall in this environment (PythonCall-extension surface)"
        @test true
    else
        using PythonCall
        pext = Base.get_extension(Strumento, :StrumentoPythonCallExt)
        ENV["PYTHONUTF8"] = "1"
        st = try
            pyimport("strumento")
        catch e
            @info "skipping: Python `strumento` not importable in this environment ($e)"
            nothing
        end
        if st === nothing
            @test true
        else
            fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
            bridge = pext.BringupBridge(joinpath(fixtures, "multimode_rehearsal", "device.yaml");
                                        overlay_id = "rehearsal-v2")
            job = pext.compile_cavity_point(bridge; freq_mhz = 5.0, reps = 50, soft_avgs = 1)

            # the seam's named target compiled through the pack's own sequence:
            # ONE played generator (the manipulate cavity line, gen 3), no
            # sweep axis (the fixed-frequency form — see the docstring)
            @test job["overlay_id"] == "rehearsal-v2"
            @test [parse(Int, k) for k in keys(job["program"]["gen_chs"])] == [3]
            @test job["acquire"]["expts"] === nothing
            @test job["acquire"]["reads_per_shot"] == [1]

            # and it reproduces the committed fixture bit-exactly
            using JSON
            fixture = JSON.parsefile(joinpath(fixtures, "_fixtures",
                                               "cavity_rehearsal.json"))
            @test job == fixture
        end
    end
end

@testitem "BringupBridge placement: the PythonCall extension; base gains nothing" begin
    using Strumento
    # UNguarded (the placement pin must hold in EVERY configuration).
    @test !isdefined(Strumento, :BringupBridge)
    if Base.identify_package("PythonCall") === nothing
        @info "skipping the extension side: no PythonCall in this environment"
        @test true
    else
        ext = Base.get_extension(Strumento, :StrumentoPythonCallExt)
        @test ext !== nothing
        @test isdefined(ext, :BringupBridge)
    end
end

# ──── The Rabi-class compile surface (issue #33, M4a-2) ────────────────────────
# The pi-gain procedure's compile lane: the stock cqed `AmplitudeRabi`
# experiment (the Rabi-class named target) compiled to its CloseLoop
# gain-ladder wire payload, and the ge_pi factory compiled at an explicit gain
# fraction — the belief-scaled downstream path. Python-optional (the same
# precedent as the comb/cavity items): the committed fixtures are this
# surface's output, regenerable by the fixture-generation script.

@testitem "BringupBridge compiles the Rabi gain ladder + the ge_pi factory (python-optional)" begin
    using Strumento
    if Base.identify_package("PythonCall") === nothing
        @info "skipping: no PythonCall in this environment (PythonCall-extension surface)"
        @test true
    else
        using PythonCall
        pext = Base.get_extension(Strumento, :StrumentoPythonCallExt)
        ENV["PYTHONUTF8"] = "1"
        st = try
            pyimport("strumento")
        catch e
            @info "skipping: Python `strumento` not importable in this environment ($e)"
            nothing
        end
        if st === nothing
            @test true
        else
            fixtures = joinpath(pkgdir(Strumento), "test", "fixtures")
            bridge = pext.BringupBridge(joinpath(fixtures, "multimode_rehearsal", "device.yaml");
                                       overlay_id = "rehearsal-v2")

            # ── the Rabi ladder: the stock experiment's gain sweep rides the
            # CloseLoop ladder (the v1-wire swept axis): one expts axis, one
            # played generator (the qubit drive), the ge_pi gauss at gain 0
            # stepped +3 codes per expt (the declared 0..120 span over 41
            # points, the ladder step (stop-start)/(points-1) exactly).
            rabi = pext.compile_rabi_sweep(bridge; gains_start = 0, gains_stop = 120,
                                           points = 41, reps = 50, soft_avgs = 1)
            @test rabi["overlay_id"] == "rehearsal-v2"
            @test rabi["acquire"]["expts"] == 41
            @test rabi["acquire"]["reads_per_shot"] == [1]
            @test sort([parse(Int, k) for k in keys(rabi["program"]["gen_chs"])]) == [2]
            @test [w["gain"] for w in rabi["program"]["waves"]] == [0]

            # in-process determinism (the compile half of the replay contract)
            again = pext.compile_rabi_sweep(bridge; gains_start = 0, gains_stop = 120,
                                            points = 41, reps = 50, soft_avgs = 1)
            @test again == rabi

            # the bridge reproduces the COMMITTED fixture bit-exactly (a
            # strumento/qick upgrade that shifts a register code fails here
            # loudly = regenerate the fixtures)
            using JSON
            @test rabi == JSON.parsefile(joinpath(fixtures, "_fixtures",
                                                  "rabi_rehearsal.json"))

            # ── the ge_pi factory compile: the baseline (no gain override ->
            # the device calibration's own int code 8192, the STALE amplitude
            # calibration the Rabi procedure exists to correct) vs the
            # belief-scaled path (an explicit gain FRACTION, the unit the
            # believed pi_gain carries). The gain lands in the wave table as
            # the fraction's own code (frac * maxv, integer by the fraction's
            # quantization).
            baseline = pext.compile_ge_pi(bridge; reps = 50, soft_avgs = 1)
            @test baseline == JSON.parsefile(joinpath(fixtures, "_fixtures",
                                                     "gepi_baseline_rehearsal.json"))
            @test [w["gain"] for w in baseline["program"]["waves"]] == [8192]
            @test baseline["acquire"]["expts"] === nothing    # a fixed point, no sweep

            calibrated = pext.compile_ge_pi(bridge; gain_frac = 43 / 32766,
                                            reps = 50, soft_avgs = 1)
            @test [w["gain"] for w in calibrated["program"]["waves"]] == [43]
            @test calibrated["acquire"]["expts"] === nothing
            # everything but the gain is the SAME compile (the paired shape:
            # one knob differs)
            cal_nogain = deepcopy(calibrated)
            for w in cal_nogain["program"]["waves"]
                w["gain"] = 8192
            end
            @test cal_nogain == baseline
        end
    end
end

end # module StrumentoPythonCallExt