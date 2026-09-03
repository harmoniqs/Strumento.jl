# StrumentoBringupExt — the Piccolo+JSON-triggered package extension (issue #31).
#
# THE REHEARSAL RIG + THE BRING-UP PROCEDURE LAYER — the M4a keystone: the
# first surface that turns a device belief plus a drift-aware schedule into
# requested measurements that run through the seam (the twin job server's
# wire), fit, and write back into the twin's belief.
#
# The rig is the registry concept made concrete: (twin record, device
# instance, wiring, transport). Swapping the twin job server for a real
# transport is a registry-id change — the same wire contract, the same
# payloads, the same procedure. Everything here is REHEARSAL: results
# produced against the twin are twin-rehearsal evidence, never device
# results (the provenance marking carries this on every result).
#
# ─── The extension split (documented) ────────────────────────────────────────
#
# - Triggers: Piccolo AND JSON — the same pair as the twin job server (the
#   rig fronts a `TwinJobServer` over the wire and reaches the Piccolo
#   extension's twin face + fit machinery). It must NOT join
#   StrumentoPiccoloExt: the bring-up layer is not physics-stack code, and it
#   must not make MockSoc/TwinSoc/the families load only when JSON is present.
# - The Python bridge (device → cqed experiment → CompiledJob) rides the
#   PYTHONCALL extension (its own trigger) and reaches this extension's rig
#   lazily at runtime — the same sibling-reach pattern the job server uses
#   for TwinSoc. The bridge testitems skip cleanly when Python `strumento`
#   is absent (the established python-optional precedent); the rig, the
#   procedure, the fit, and the write-back run Julia-only against committed
#   fixture payloads.
# - The sibling reaches happen at runtime, never at top level: extension load
#   order between siblings is not guaranteed (the _twinsoc_type precedent).
module StrumentoBringupExt

import Strumento
import Strumento:
    DigitalTwin,
    TwinRecord,
    load_record,
    instantiate,
    believed,
    advance!,
    calibrate!,
    DriftPlan,
    TwinWiringMap,
    TwinGenWiring,
    wiring_for,
    QickProgram,
    AbstractSoc,
    load_envelope!,
    play_program!,
    acquire
using TestItems

using JSON
using Piccolo
using Sockets

export RehearsalRig, wire_address, stop!
export ResonatorSweepDesign, comb_geometry,
    BringupSchedule, BringupJob, BringupResult, ResonatorSweepFit,
    propose, run_over_wire, write_back!, run_resonator_sweep, fixture_comb_jobs
export RabiSweepDesign, rabi_axis, rabi_geometry,
    RabiSchedule, RabiJob, RabiResult, RabiSweepFit,
    propose_rabi, run_rabi_over_wire, run_rabi_sweep, fixture_rabi_job
export RamseyDesign, ramsey_axis_us, ramsey_geometry,
    RamseySchedule, RamseyJob, RamseyResult, RamseyFit,
    propose_ramsey, run_ramsey_over_wire, fit_ramsey, run_ramsey_sweep,
    fixture_ramsey_jobs
export T1Design, t1_axis_us, t1_geometry,
    T1Schedule, T1Job, T1Result, T1Fit,
    propose_t1, run_t1_over_wire, fit_t1, run_t1_sweep, fixture_t1_jobs
export ConfusionDesign, confusion_geometry,
    ConfusionSchedule, ConfusionJobs, ConfusionResult, ConfusionFit,
    propose_confusion, run_confusion_over_wire, fit_confusion, run_confusion,
    fixture_confusion_jobs

include("bringup.jl")

end # module StrumentoBringupExt
