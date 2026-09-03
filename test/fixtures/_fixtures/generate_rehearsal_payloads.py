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
  device calibration's own ``pi_ge`` gain, 8192 int codes -> 8192/32766
  fraction): the same compile + wire path the downstream consumption takes
  (dev.qubit.ge_pi() + Measure), at the STALE calibration gain the Rabi
  procedure exists to correct. The calibrated counterpart is compiled live
  at the fitted gain (the bridge's ``compile_ge_pi`` at the believed pi_gain) —
  its payload is a function of the fit and is never a fixture.
- ramsey_rehearsal_NN.json — the Ramsey fringe's per-point jobs (issue #37):
  one wave whose envelope carries half-pi arm, an in-wave silence gap of
  ``RAMSEY_DELAYS_SAMPLES[k]`` samples, then the second half-pi arm. Swept
  delays are wire-DEFERRED in v1 (the pack's ``wait(Sweep)`` compiles to tProc
  TIME/register arithmetic, outside the payload reader's envelope-level lane,
  and the CloseLoop ladder realizes gain steps only), so the delay rides the
  ENVELOPE — the envelope-ride law — one payload per delay point.
- t1_rehearsal_NN.json — the T1 decay's per-point jobs (issue #37): the
  by-construction pi excitation then an in-wave silence gap of the declared
  delay (sample-integral at the overlay's 12.5 samples/us).
- confusion_g_rehearsal.json / confusion_e_rehearsal.json — the readout-
  confusion preparations (issue #37): the zero-drive ground window and the
  by-construction pi excited-prep, the counts the confusion recovery consumes.

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

# The calibration-set geometry (issue #37; the values are shared with
# RamseyDesign / T1Design / ConfusionDesign in ext/bringup.jl).
#
# THE ENVELOPE-RIDE LAW, verified against the pack's own experiments (read
# only): a swept DELAY — the pack's ``T1``/``T2Ramsey`` ``.wait(Sweep(on="t"))``
# — compiles to tProc TIME/register arithmetic (REG_WR r_k + #step inside the
# expts loop, a TIME-param site), which the twin job server's v1 payload
# reader DEFERS: the expts axis is realized from the declared loop structure,
# but per-expt VALUES ride the CloseLoop wave-memory ladder, which v1 realizes
# for GAIN steps only; a swept-delay payload would replay the identical
# envelope per expt and the delay would be invisible. The wire-realizable form
# of a swept time axis is the ENVELOPE ITSELF: the delay rides the played
# envelope as an in-wave silence gap (zeros — time-domain, not carrier), one
# payload per delay point (the comb precedent: one job per swept point). The
# probe shapes are envelope-authored sin^2 pulses at by-construction flip
# angles (the comb probe's discipline: peak amplitude x integral = the flip):
# half-pi for the Ramsey arms, pi for the T1 / confusion e-prep excitation.
FS_MHZ = 12.5          # the rehearsal overlay's generator fabric (samples/us)
T_HP_US = 4.0          # the sin^2 half-pi arm length (50 samples: clears qick's
                       # 3-fabric-cycle envelope minimum like the comb's disp)
T_PI_US = 4.0          # the sin^2 pi excitation length
RAMSEY_PROBE_GAIN = np.pi / (T_HP_US * 1000.0)    # shaped flip pi/2 (ns units)
T1_PROBE_GAIN = 2.0 * np.pi / (T_PI_US * 1000.0)  # shaped flip pi
QUBIT_FREQ_MHZ = 4.0   # the probe carrier (the frame)
# The Ramsey delay axis, in ENVELOPE SAMPLES (integer by construction: the
# decoded axis is exactly the declared one). 9 points 0..512 samples
# (0..40.96 us in 5.12-us steps): at the rehearsal twin's seeded detuning
# truth (20 kHz) the fringe period is 50 us, so the grid resolves the first
# minimum (~25 us) with ~5 points per fringe half-period.
RAMSEY_DELAYS_SAMPLES = list(range(0, 513, 64))
# The T1 delay axis, in MICROSECONDS chosen sample-integral at 12.5 samples/us
# (0.08-us resolution). 9 points 0..240 us ~ 2x the record's T1_q_us (120 us):
# the decay fit's information range.
T1_DELAYS_US = [0.0, 20.0, 40.0, 60.0, 90.0, 120.0, 160.0, 200.0, 240.0]


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


def _sin2_arm(n_samp, fs):
    """One sin^2 probe arm on the DAC grid (peak 1, the comb probe's shape
    class: starts and ends at ~0, so arms concatenate with silence gaps)."""
    t = np.arange(n_samp) / fs
    return np.sin(np.pi * t / (n_samp / fs)) ** 2


def ramsey_point(dev, delay_samples):
    """The Ramsey fringe point (issue #37): ONE wave whose envelope carries the
    whole sequence — half-pi arm, an in-wave silence gap of ``delay_samples``
    envelope samples (the envelope-ride law; see the geometry constants), then
    the second half-pi arm. The delay is the SCHEDULE point; the payload is the
    single source of truth for the decoded axis."""
    from strumento.core.pulses import Arb, Pulse, Seq
    from strumento.core.program import StrumentoProgram
    from strumento.core.wiring import LineRef

    n_hp = int(round(T_HP_US * FS_MHZ))
    arm = _sin2_arm(n_hp, FS_MHZ)
    idata = np.concatenate([arm, np.zeros(delay_samples), arm])
    probe = Pulse(
        line=LineRef("qubit", "drive"), freq_mhz=QUBIT_FREQ_MHZ,
        gain=RAMSEY_PROBE_GAIN,
        envelope=Arb(idata=idata.tolist(), qdata=np.zeros(len(idata)).tolist()),
        label="ramsey_probe",
    )
    prog = StrumentoProgram(dev, seq=Seq().play(probe).measure(), reps=REPS)
    return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()


def t1_point(dev, delay_samples):
    """The T1 decay point (issue #37): ONE wave whose envelope carries the
    by-construction pi excitation then an in-wave silence gap of
    ``delay_samples`` samples. The idle population decays at exactly the
    ancilla T1 (the cavity starts in vacuum), so the e-frequency vs the
    decoded delay is the exponential the fit consumes."""
    from strumento.core.pulses import Arb, Pulse, Seq
    from strumento.core.program import StrumentoProgram
    from strumento.core.wiring import LineRef

    n_pi = int(round(T_PI_US * FS_MHZ))
    idata = np.concatenate([_sin2_arm(n_pi, FS_MHZ), np.zeros(delay_samples)])
    probe = Pulse(
        line=LineRef("qubit", "drive"), freq_mhz=QUBIT_FREQ_MHZ,
        gain=T1_PROBE_GAIN,
        envelope=Arb(idata=idata.tolist(), qdata=np.zeros(len(idata)).tolist()),
        label="t1_probe",
    )
    prog = StrumentoProgram(dev, seq=Seq().play(probe).measure(), reps=REPS)
    return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()


def confusion_points(dev):
    """The readout-confusion preparations (issue #37): the g-prep (a zero-drive
    window — the ancilla stays in the ground state it starts in) and the e-prep
    (the by-construction pi excitation; the record's T1-corrected row-2
    recovery unwinds the decay over the played window)."""
    from strumento.core.pulses import Arb, Pulse, Seq
    from strumento.core.program import StrumentoProgram
    from strumento.core.wiring import LineRef

    n_pi = int(round(T_PI_US * FS_MHZ))

    def wire(label, gain, idata):
        probe = Pulse(
            line=LineRef("qubit", "drive"), freq_mhz=QUBIT_FREQ_MHZ, gain=gain,
            envelope=Arb(idata=idata.tolist(), qdata=np.zeros(len(idata)).tolist()),
            label=label,
        )
        prog = StrumentoProgram(dev, seq=Seq().play(probe).measure(), reps=REPS)
        return prog.to_compiled_job(overlay_id="rehearsal-v2", soft_avgs=1).to_wire()

    g = wire("confusion_zero", 0.0, np.zeros(n_pi))
    e = wire("confusion_pi", T1_PROBE_GAIN, _sin2_arm(n_pi, FS_MHZ))
    return g, e


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
    for k, d in enumerate(RAMSEY_DELAYS_SAMPLES):
        path = os.path.join(OUTDIR, f"ramsey_rehearsal_{k:02d}.json")
        with open(path, "w") as fh:
            json.dump(ramsey_point(dev, int(d)), fh)
    for k, us in enumerate(T1_DELAYS_US):
        path = os.path.join(OUTDIR, f"t1_rehearsal_{k:02d}.json")
        with open(path, "w") as fh:
            json.dump(t1_point(dev, int(round(us * FS_MHZ))), fh)
    g, e = confusion_points(dev)
    with open(os.path.join(OUTDIR, "confusion_g_rehearsal.json"), "w") as fh:
        json.dump(g, fh)
    with open(os.path.join(OUTDIR, "confusion_e_rehearsal.json"), "w") as fh:
        json.dump(e, fh)
    print(f"wrote {len(FREQS_KHZ)} comb points + 1 cavity + 1 rabi + 1 ge-pi baseline "
          f"+ {len(RAMSEY_DELAYS_SAMPLES)} ramsey + {len(T1_DELAYS_US)} t1 + 2 confusion "
          f"payloads to {OUTDIR}")


if __name__ == "__main__":
    main()
