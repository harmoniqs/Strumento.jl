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
    print(f"wrote {len(FREQS_KHZ)} comb points + 1 cavity + 1 rabi + 1 ge-pi baseline payload to {OUTDIR}")


if __name__ == "__main__":
    main()
