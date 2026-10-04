"""Generate the committed rehearsal wire payloads (issue #31).

The bring-up fixtures in this directory are COMPILED by the Python reference
stack (strumento, editable at the campaign's fixture-generation clone) against
the committed demo-class device instance at
test/fixtures/multimode_rehearsal/device.yaml. Regeneration:

    python3 test/fixtures/_fixtures/generate_rehearsal_payloads.py /path/to/Strumento.jl

The emitted payloads are the D14 CompiledJob wire form (qick's own dump_prog
serialized through NpEncoder — JSON primitives all the way down):

- comb_rehearsal_NN.json — the resonator-sweep schedule's per-point jobs (one
  per swept ancilla-probe frequency): the cavity displacement (the cqed pack's
  alpha-calibrated `displace_alpha` factory) followed by the shaped ancilla
  probe, whose Arb envelope rotates at the point's frequency (the v1 wire
  frame boundary: the twin is a rotating-frame model, so the swept detuning
  rides the ENVELOPE — a carrier-swept const probe is frame-invisible and a
  frequency-stepped CloseLoop ladder is outside the server's v1 swept-amp
  form).
- cavity_rehearsal.json — the stock `CavitySpectroscopy` experiment compiled
  at a fixed frequency (the seam's named target: the same compile + wire path
  exercised; its const cavity probe is the honest flat response through the
  ancilla marginal — cavity transmission is not a v1-twin observable).
- rabi_rehearsal.json — the pi-gain procedure's gain-ladder payload (issue
  #33): the stock cqed `AmplitudeRabi` experiment — the ge_pi gauss swept in
  lab-native gain int codes over `RABI_POINTS` points from 0 to
  `RABI_GAIN_STOP` — compiled through the pack's own sequence + the core
  compile path. The sweep rides the CloseLoop gain ladder (the v1-wire swept
  axis the twin job server decodes): one payload, one expts axis, the
  per-expt drive amplitude stepped in gain codes.
- gepi_baseline_rehearsal.json — the uncalibrated-baseline pi pulse (the
  device calibration's own `pi_ge` gain, 8192 int codes -> 8192/32766
  fraction): the same compile + wire path the downstream consumption takes
  (dev.qubit.ge_pi() + Measure), at the STALE calibration gain the Rabi
  procedure exists to correct. The calibrated counterpart is compiled live
  at the fitted gain (the bridge's `compile_ge_pi` at the believed pi_gain) —
  its payload is a function of the fit and is never a fixture.
- t1_rehearsal_NN.json — the T1 procedure's per-delay-point jobs (issue #37):
  ge_pi at the Rabi-calibrated operating-point gain, a scalar `wait(delay_us)` (the
  tProc literal TIME advance — the wire's TIME-param form), then Measure. One
  payload per schedule point over T1_DELAYS_US; the ancilla decay the twin
  rolls through the idle IS the observable (the exponential fit is
  prep-agnostic: the excited population decays at 1/T1 from whatever
  preparation the pulse leaves).
- ramsey_rehearsal_NN.json — the Ramsey procedure's per-delay-point jobs
  (issue #37): the comb geometry's cavity displacement (displace_alpha at
  RAMSEY_DISPLACEMENT_ALPHA -> mean photon number nbar = alpha^2, the
  ancilla-precession axis), the first half-pi (ge_hpi at RAMSEY_HPI_GAIN_FRAC),
  a scalar `wait(delay_us)`, the second half-pi at +RAMSEY_SECOND_PHASE_DEG
  (the distinct phase breaks the wave-table degeneracy — the same factory at
  the same phase compiles to ONE wave-table entry played twice, which the
  envelope-level reconstruction cannot distinguish), then Measure. The
  fringe: the |e,n> component accumulates phase at chi*n per photon during
  the idle (the only in-frame ancilla precession the v1 family carries), so
  the delay fringe carries the transition's detuning from its believed
  position at the calibration photon number.
- confusion_g_rehearsal.json / confusion_e_rehearsal.json — the readout
  confusion procedure's two preparations (issue #37): ge_pi at gain 0 (the
  ground preparation — a played zero drive over the pi window) and ge_pi at
  CAL_PI_GAIN_FRAC (the excited preparation, at the rehearsal's
  Rabi-calibrated operating point). The counts over each prep's shots are
  the confusion rows (the e row T1-corrected over the played window by the
  procedure).

Every payload is deterministic given the device and the geometry (verified
across fresh processes); the JSON is integer-dominated (register codes, int16
envelope samples), no float goldens.
"""

import json
import os
import sys

import numpy as np

REPO = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", ".."))
DEVICE = os.path.join(REPO, "test", "fixtures", "multimode_rehearsal", "device.yaml")
OUTDIR = os.path.join(REPO, "test", "fixtures", "_fixtures")

# The resonator-sweep geometry — the certification design's comb, restated for
# the wire (see ResonatorSweepDesign in ext/bringup.jl; the values are shared).
DISPLACEMENT_ALPHA = 2.0 ** 0.5    # |beta| = sqrt(2): mean photon number 2
T_DISP_US = 4.0                    # the displacement gauss's 4-sigma window
T_SPEC_US = 10.0                   # the shaped ancilla pi-pulse's length
PROBE_GAIN = 2.0 * np.pi / (T_SPEC_US * 1000.0)   # shaped flip angle pi (ns units)
QUBIT_FREQ_MHZ = 4.0               # the probe carrier (the rehearsal device's f_ge)
REPS = 50
FREQS_KHZ = np.concatenate([np.arange(230.0, 350.1, 15.0), np.arange(520.0, 640.1, 15.0)])

# The pi-gain ladder's geometry (issue #33; the values are shared with
# RabiSweepDesign in ext/bringup.jl). Lab-native gain int codes; the span
# covers the twin's true pi gain (~43 codes at the 1-us-sigma gauss on the
# 12.5 MHz fabric) with ~3x margin on the far side, so the measured sweep
# exhibits the first oscillation maximum well inside the span. The ladder
# step is (stop - 0)/(points - 1) = 3 codes exactly (integer by construction).
RABI_GAIN_STOP = 120
RABI_POINTS = 41

# The calibration-set geometries (issue #37; the values are shared with the
# designs in ext/bringup.jl). The T1/Ramsey delay grids are authored in EXACT
# DAC samples (12.5 samples/us -> 0.08 us granularity) so the literal TIME
# advance quantizes onto the generator grid cleanly. The Ramsey half-pi gain
# and the T1/confusion pi gains are the rehearsal world's committed operating
# points: the twin-class pi-gain scale the Rabi procedure recovers (~43 int
# codes). At the STALE calibration gain (8192 codes, ~190x the pi scale) the
# gauss rotates with a ~25 ns period against the fabric's 80 ns sample grid —
# an under-resolved overdrive whose rollout is knot-grid-dependent; the
# calibration set's pi-based preparations ride the RESOLVED operating point
# instead (the stale baseline keeps its role in the Rabi paired proof).
T1_DELAYS_US = [0.0, 40.0, 80.0, 120.0, 160.0, 200.0, 240.0, 280.0]
RAMSEY_DELAYS_US = [round(0.4 * k, 10) for k in range(0, 18)]   # 0.0 .. 6.8 us
RAMSEY_DISPLACEMENT_ALPHA = 2.0 ** 0.5    # nbar = 2: the comb operating point
RAMSEY_HPI_GAIN_FRAC = 0.0007             # ~half the twin-class pi-gain scale
RAMSEY_SECOND_PHASE_DEG = 90.0            # the quadrature fringe; breaks the
                                          # wave-table degeneracy
CAL_PI_GAIN_FRAC = 43.0 / 32766.0   # the Rabi-calibrated operating point (the confusion e-prep rides it too)


def comb_point(dev, f_khz):
    from strumento.core.pulses import Arb, Pulse, Seq
    from strumento.core.program import StrumentoProgram
    from strumento.core.wiring import LineRef

    fs = dev.soccfg_snapshot["gens"][3]["fs"]
    disp = dev.manipulate.displace_alpha(DISPLACEMENT_ALPHA)
    n0, n1 = int(round(T_DISP_US * fs)), int(round(T_SPEC_US * fs))
    t = np.arange(n1) / fs
    env = np.sin(np.pi * t / T_SPEC_US) ** 2 * np.exp(2j * np.pi * (f_khz / 1000.0) * t)
    idata = np.concatenate([np.zeros(n0), np.real(env)])
    qdata = np.concatenate([np.zeros(n0), np.imag(env)])
    peak = max(1.0, float(np.max(np.hypot(idata, qdata))))
    probe = Pulse(
        line=LineRef("qubit", "drive"), freq_mhz=QUBIT_FREQ_MHZ, gain=PROBE_GAIN,
        envelope=Arb(idata=(idata / peak).tolist(), qdata=(qdata / peak).tolist()),
        label="comb_probe",
    )
    prog = StrumentoProgram(dev, seq=Seq().play(disp).play(probe).measure(), reps=REPS)
    return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()


def cavity_point(dev):
    from strumento.core.program import StrumentoProgram
    from strumento.packs.cqed.experiments.cavity_spectroscopy import CavitySpectroscopy

    exp = CavitySpectroscopy(dev, freqs=5.0, points=1)
    seq, _ = exp.sequence()
    prog = StrumentoProgram(dev, seq=seq, axes=exp.axes(), reps=REPS)
    return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()


def rabi_point(dev):
    """The pi-gain ladder payload: the stock AmplitudeRabi experiment (issue #33).

    The gain span is lab-native int codes 0..RABI_GAIN_STOP over RABI_POINTS
    points (the ladder step is (stop-start)/(points-1) codes, an integer by
    construction of the constants below). The span is authored to cover the
    twin's true pi gain with margin (see RabiSweepDesign in ext/bringup.jl).
    """
    from strumento.core.program import StrumentoProgram
    from strumento.core.sweeps import Sweep
    from strumento.packs.cqed.experiments.amplitude_rabi import AmplitudeRabi

    exp = AmplitudeRabi(dev, gains=Sweep(start=0, stop=RABI_GAIN_STOP, on="amp"),
                        points=RABI_POINTS)
    seq, _ = exp.sequence()
    prog = StrumentoProgram(dev, seq=seq, axes=exp.axes(), reps=REPS)
    return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()


def gepi_baseline_point(dev):
    """The uncalibrated-baseline pi pulse: ge_pi() at the device calibration's
    own gain (8192 int codes), the compile the downstream consumption takes
    when no pi_gain belief exists."""
    from strumento.core.program import StrumentoProgram
    from strumento.core.pulses import Seq

    seq = Seq().play(dev.qubit.ge_pi()).measure()
    prog = StrumentoProgram(dev, seq=seq, reps=REPS)
    return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()


def t1_point(dev, delay_us):
    """The T1 procedure's per-delay-point payload (issue #33's follow-on,
    issue #37): ge_pi at the Rabi-calibrated operating-point gain, a scalar
    wait, then Measure. The wait compiles to the tProc's literal TIME advance
    (the wire's TIME-param form) between the pi's played extent and the
    readout trigger."""
    from strumento.core.program import StrumentoProgram
    from strumento.core.pulses import Seq

    seq = Seq().play(dev.qubit.ge_pi(gain=CAL_PI_GAIN_FRAC)).wait(delay_us).measure()
    prog = StrumentoProgram(dev, seq=seq, reps=REPS)
    return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()


def ramsey_point(dev, delay_us):
    """The Ramsey procedure's per-delay-point payload (issue #37): the cavity
    displacement (the comb geometry's alpha), half-pi, scalar wait, the second
    half-pi at +90 deg, Measure. The second pulse's distinct phase gives it
    its own wave-table entry (a same-wave double play is invisible to the
    envelope-level reconstruction)."""
    from strumento.core.program import StrumentoProgram
    from strumento.core.pulses import Seq

    disp = dev.manipulate.displace_alpha(RAMSEY_DISPLACEMENT_ALPHA)
    hpi1 = dev.qubit.ge_hpi(gain=RAMSEY_HPI_GAIN_FRAC)
    hpi2 = dev.qubit.ge_hpi(gain=RAMSEY_HPI_GAIN_FRAC, phase=RAMSEY_SECOND_PHASE_DEG)
    seq = Seq().play(disp).play(hpi1).wait(delay_us).play(hpi2).measure()
    prog = StrumentoProgram(dev, seq=seq, reps=REPS)
    return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()


def confusion_point(dev, gain_frac):
    """One confusion preparation (issue #37): ge_pi at `gain_frac` (0.0 = the
    ground preparation; CONFUSION_PI_GAIN_FRAC = the excited preparation at
    the Rabi-calibrated operating point), then Measure."""
    from strumento.core.program import StrumentoProgram
    from strumento.core.pulses import Seq

    seq = Seq().play(dev.qubit.ge_pi(gain=gain_frac)).measure()
    prog = StrumentoProgram(dev, seq=seq, reps=REPS)
    return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()


def main():
    from strumento import Device

    dev = Device.load(DEVICE)
    os.makedirs(OUTDIR, exist_ok=True)
    for k, f in enumerate(FREQS_KHZ):
        path = os.path.join(OUTDIR, f"comb_rehearsal_{k:02d}.json")
        with open(path, "w") as fh:
            json.dump(comb_point(dev, float(f)), fh)
    with open(os.path.join(OUTDIR, "cavity_rehearsal.json"), "w") as fh:
        json.dump(cavity_point(dev), fh)
    with open(os.path.join(OUTDIR, "rabi_rehearsal.json"), "w") as fh:
        json.dump(rabi_point(dev), fh)
    with open(os.path.join(OUTDIR, "gepi_baseline_rehearsal.json"), "w") as fh:
        json.dump(gepi_baseline_point(dev), fh)
    for k, delay in enumerate(T1_DELAYS_US):
        path = os.path.join(OUTDIR, f"t1_rehearsal_{k:02d}.json")
        with open(path, "w") as fh:
            json.dump(t1_point(dev, float(delay)), fh)
    for k, delay in enumerate(RAMSEY_DELAYS_US):
        path = os.path.join(OUTDIR, f"ramsey_rehearsal_{k:02d}.json")
        with open(path, "w") as fh:
            json.dump(ramsey_point(dev, float(delay)), fh)
    with open(os.path.join(OUTDIR, "confusion_g_rehearsal.json"), "w") as fh:
        json.dump(confusion_point(dev, 0.0), fh)
    with open(os.path.join(OUTDIR, "confusion_e_rehearsal.json"), "w") as fh:
        json.dump(confusion_point(dev, CAL_PI_GAIN_FRAC), fh)
    print(
        f"wrote {len(FREQS_KHZ)} comb + 1 cavity + 1 rabi + 1 ge-pi baseline + "
        f"{len(T1_DELAYS_US)} t1 + {len(RAMSEY_DELAYS_US)} ramsey + 2 confusion "
        f"payloads to {OUTDIR}"
    )


if __name__ == "__main__":
    main()
