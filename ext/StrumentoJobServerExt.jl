# StrumentoJobServerExt — the Piccolo+JSON-triggered package extension (issue #29).
#
# THE TWIN JOB SERVER — the Julia side of the D14 wire contract: a board-shaped
# actor that receives the Python stack's `CompiledJob` wire form (qick's own
# `dump_prog()` dict serialized through `NpEncoder` — JSON primitives all the
# way down), translates it at the ENVELOPE level, executes it through the twin
# face, and answers in the `RawAcquisition` wire form. Swapping the twin for a
# real device is a registry-id change — that is the whole point (D14).
#
# ─── The boundary, stated up front ────────────────────────────────────────────
#
# THE TWIN MODELS THE DEVICE RESPONSE, NOT tProc-v2 CONTROL-FLOW SEMANTICS.
# The server consumes the compiled payload at the envelope level — the
# envelope pages, the wave-table assignments, the declared loop structure, the
# acquire block — and never interprets the tProc program (register semantics,
# trigger scheduling, branching, and binary ISA simulation are out of scope:
# the assembly-faithful lane is Python SimulatorSoc's; the two lanes are
# COMPLEMENTARY — M3's rehearsal claim runs at the envelope level, where the
# physics lives). Concretely: the played drive is reconstructed from the
# wave-table assignments (envelope samples scaled from DAC codes, gain and
# carrier phase applied per wave) and the readout samples the post-drive state
# per declared read; the sweep axis is realized from the payload's declared
# loop structure (`loop_dims`/`avg_level`), never from simulating the loop
# registers.
#
# ─── The extension split + the wire-stack decisions (documented) ─────────────
#
# - The server rides its OWN extension (triggers: Piccolo AND JSON — the
#   payload is JSON by contract, "JSON primitives all the way down"; JSON.jl
#   is the light, pure-Julia wire codec). It must NOT join StrumentoPiccoloExt:
#   adding JSON to that extension's triggers would make MockSoc/TwinSoc/the
#   families load only when JSON is present, breaking the piccolo-only
#   configuration the load-configuration checks pin. Consumers that never
#   add JSON keep the light package by construction ("nothing new in base").
# - HTTP rides the STANDARD LIBRARY (`Sockets`), not a dep: the wire protocol
#   is two routes (submit + poll) over HTTP/1.1, one request per connection —
#   a ~hundred lines of stdlib, no new dependency edge for a server whose
#   deployment shape (the reference board-side agent) is deliberately dumb.
# - The extension reaches its sibling's type lazily (TwinSoc is defined by
#   StrumentoPiccoloExt; extension load order between siblings is not
#   guaranteed, so the reach happens at construction time, never at top level).
#
# ─── The wire protocol (exactly what the Python JobServerClient expects) ──────
#
#   POST /jobs        body = the CompiledJob wire JSON   -> {"job_id": "..."}
#   GET  /jobs/<id>   the status dict: {"status": "pending"} | {"status": "done", "acquisition": {...}}
#                    | {"status": "error", "error": "..."}     (404 on unknown ids)
#
# One job in, raw IQ out — the same coarse shape as the reference board-side
# agent (`strumento`'s examples/jobserver/server.py): submit enqueues, a poll
# is the single worker's turn (a deployment gives the worker its own thread —
# hardware exclusivity is structural either way), a failed job never takes the
# server down.
module StrumentoJobServerExt

import Strumento
import Strumento:
    AbstractSoc,
    load_envelope!,
    play_program!,
    acquire,
    QickProgram,
    TwinRecord,
    load_record,
    DigitalTwin,
    instantiate,
    DriftPlan,
    advance!
using TestItems

using JSON
using Piccolo

export TwinJobServer

include("twin_job_server.jl")

end # module StrumentoJobServerExt
