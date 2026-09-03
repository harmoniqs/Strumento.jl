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
    print(f"wrote {len(FREQS_KHZ)} comb points + 1 cavity payload to {OUTDIR}")


if __name__ == "__main__":
    main()
