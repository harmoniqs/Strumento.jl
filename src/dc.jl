# The DC control class (issue #35, M4b-1) — the soc contract's slow-DC sibling.
#
# QICK owns the FAST axes (envelopes, pulses, triggers — the waveform verbs of
# soc.jl); gate-defined devices also need SLOW DC gate biasing from an external
# voltage source (a QDAC-class instrument — the landed Python seam is
# strumento.core.dc, and the PythonCall extension's bridge maps these verbs
# onto it). Autotuning sweeps these axes and reads the charge sensor, so the
# class is first-class on the soc contract, not a waveform afterthought.
#
# ─── The three-way separation (the contract this class lives under) ──────────
#
# Gate voltages are a CONTROL class — the AUTOTUNER's actions:
#
#   - never TRUTH: drift (advance!/DriftPlan) moves truth only; nothing an
#     autotuner does to a gate ever appears in the twin's truth map.
#   - never BELIEF: calibration (calibrate!) moves belief only; gate voltages
#     are not calibrated knowledge, they are commanded inputs.
#   - never WAVEFORMS: the pulse verbs (execute! and its envelope family) are a
#     disjoint control class — two control classes, one twin.
#
# The twin's DC state therefore lives as a CONTROL FIELD on the soc face
# (TwinSoc.gates), beside truth and belief but touching neither. The family
# consumes it as an interaction with truth (the landscape is a function of the
# gate controls AND the current truth), which is what makes an autotuning sweep
# against the twin feel like a sweep against the device.

"""
    set_gate!(soc, gate, volts) -> soc

Set one named slow DC gate axis to `volts` (V). A CONTROL action (see the
three-way separation in the module docs): it commands the autotuner's gate
voltage, never truth, never belief, never a waveform.
"""
function set_gate!(soc::AbstractSoc, gate, volts)
    error("set_gate! not implemented for $(typeof(soc)) — this soc carries no " *
          "DC gate path (the slow DC control class; the twin face implements it)")
end

"""
    get_gate(soc, gate) -> Float64

Read one named slow DC gate axis back (V). The CONTROL state as the soc holds
it — not truth, not belief.
"""
function get_gate(soc::AbstractSoc, gate)
    error("get_gate not implemented for $(typeof(soc)) — this soc carries no " *
          "DC gate path (the slow DC control class)")
end

"""
    gate_snapshot(soc) -> Dict{String,Float64}

All gate voltages by name — the DC control state as it stands, for stamping
into a sweep's metadata (the dc.py `snapshot` precedent).
"""
function gate_snapshot(soc::AbstractSoc)
    error("gate_snapshot not implemented for $(typeof(soc)) — this soc carries " *
          "no DC gate path (the slow DC control class)")
end

# ─── DCAxis / DCAxisMap — the instrument-side DC data surface ─────────────────
# One named slow axis's instrument facts: which voltage-source channel serves
# it and its hard safety clamp. This is the Julia shape of the landed Python
# seam's `DCAxis` (strumento.core.dc: channel + max_v clamp; the cross-coupling
# lever-arm row is out of v1 — compensated moves are a procedure-layer
# concern). It lives in BASE like TwinWiringMap because more than one extension
# consumes it (the PythonCall bridge builds the Python `DCSource` axes from it;
# the twin-side family seam declares its gates independently, from the record).

"""
    DCAxis(channel, max_v)

One named slow axis: voltage-source `channel` plus the hard safety clamp
`max_v` (V, enforced on every move — |volts| ≤ max_v or the move is refused).
"""
struct DCAxis
    channel::Int
    max_v::Float64
    # validation rides the (sole) inner constructor: an outer method with typed
    # args loses dispatch to the exact-type default constructor for e.g.
    # (Int, Float64) args, and the clamp would silently vanish.
    function DCAxis(channel::Integer, max_v::Real)
        max_v > 0 || error(
            "DCAxis: max_v must be > 0 (got $max_v) — a safety clamp that clamps " *
            "nothing is no clamp")
        return new(Int(channel), Float64(max_v))
    end
end

"""
    DCAxisMap(axes) -> DCAxisMap

Validated gate-name → `DCAxis` map: gate names must be non-empty and instrument
channels distinct. `gate_names` returns the names (sorted); `axis_for` resolves
one gate, refusing an unknown gate actionably with the known gates listed.
"""
struct DCAxisMap
    axes::Dict{String,DCAxis}
    # validation rides the (sole) inner constructor — see DCAxis for the
    # outer-constructor dispatch pitfall this avoids.
    function DCAxisMap(axes::AbstractDict{<:AbstractString})
        isempty(axes) && error("DCAxisMap: no axes — a DC wiring maps at least one gate")
        channels = Int[]
        for (name, axis) in axes
            isempty(name) && error(
                "DCAxisMap: a DC gate name must be non-empty (got $(repr(name)))")
            axis isa DCAxis || error(
                "DCAxisMap: axis $(repr(name)) must be a DCAxis (got $(typeof(axis)))")
            axis.channel in channels && error(
                "DCAxisMap: instrument channel $(axis.channel) serves more than one " *
                "gate — channels must be distinct")
            push!(channels, axis.channel)
        end
        return new(Dict{String,DCAxis}(string(k) => v for (k, v) in axes))
    end
end

DCAxisMap(pairs::Pair...) = DCAxisMap(Dict(pairs))

"""The map's gate names, sorted (a stable listing for errors and stamps)."""
gate_names(map::DCAxisMap) = sort!(collect(keys(map.axes)))

"""The axis serving `gate`, or an actionable error naming it and the known gates."""
function axis_for(map::DCAxisMap, gate::AbstractString)
    haskey(map.axes, gate) || error(
        "unknown DC gate $(repr(gate)) — the wiring carries gates " *
        "$(join((repr.(gate_names(map))), ", "))")
    return map.axes[gate]
end

@testitem "the DC verbs refuse actionably on a soc with no DC path" begin
    using Strumento
    struct _BareSocDC <: Strumento.AbstractSoc end
    s = _BareSocDC()
    err = try
        set_gate!(s, "L", 0.1); nothing
    catch e
        e
    end
    @test err isa ErrorException
    msg = sprint(showerror, err)
    @test occursin("DC", msg)
    @test occursin("_BareSocDC", msg)
    err = try
        get_gate(s, "L"); nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("get_gate", sprint(showerror, err))
    err = try
        gate_snapshot(s); nothing
    catch e
        e
    end
    @test err isa ErrorException
end

@testitem "DCAxisMap — the instrument-side DC data surface, validated" begin
    using Strumento
    m = DCAxisMap(Dict("L" => DCAxis(0, 1.0), "R" => DCAxis(1, 1.0)))
    @test gate_names(m) == ["L", "R"]            # sorted, stable
    @test axis_for(m, "L").channel == 0
    @test axis_for(m, "R").max_v == 1.0

    # a non-positive clamp is refused (a safety clamp that clamps nothing)
    err = try
        DCAxis(0, 0.0); nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("max_v", sprint(showerror, err))

    # duplicate instrument channels are refused
    err = try
        DCAxisMap(Dict("L" => DCAxis(0, 1.0), "R" => DCAxis(0, 1.0))); nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("distinct", sprint(showerror, err))

    # an empty gate name is refused
    err = try
        DCAxisMap(Dict("" => DCAxis(0, 1.0))); nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("gate name", sprint(showerror, err))

    # an unknown gate is named actionably, with the known gates listed
    err = try
        axis_for(m, "barrier"); nothing
    catch e
        e
    end
    @test err isa ErrorException
    msg = sprint(showerror, err)
    @test occursin("barrier", msg)
    @test occursin("\"L\"", msg) && occursin("\"R\"", msg)
end
