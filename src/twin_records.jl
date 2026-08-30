# Twin records — typed views of the vault's `model-of-lab/<id>.md` documents.
# Code loads records; it never owns parameters (spec-20260803-043304).
#
# Absorbed from harmoniqs/Sosia.jl (spec-20260803-043304-digital-twins-sosia),
# issue #15 — ported faithfully; naming carried as-is.

using YAML

export TwinRecord, RecordError, load_record

"""
    TwinRecord

A parsed twin record: identity + family/platform/status, the machine-read
`parameters` / `noise` / `drift_priors` / `provenance` maps, and the prose body.
"""
struct TwinRecord
    id::String
    family::String
    platform::String
    status::String
    parameters::Dict{String, Any}
    noise::Dict{String, Any}
    drift_priors::Dict{String, Any}
    provenance::Dict{String, Any}
    body::String
end

"""Raised when a record is missing a required field (named in the message)."""
struct RecordError <: Exception
    msg::String
end
Base.showerror(io::IO, e::RecordError) = print(io, e.msg)

const _FM = r"^---\s*\n(.*?)\n---\s*\n(.*)$"s

function load_record(path::AbstractString)
    isfile(path) || throw(RecordError("record not found: $path"))
    text = read(path, String)
    m = match(_FM, text)
    m === nothing && throw(RecordError("$path: no YAML frontmatter block"))
    fm = YAML.load(m.captures[1]; dicttype = Dict{String, Any})
    body = strip(m.captures[2])

    type_ = get(fm, "type", nothing)
    type_ == "device-twin" || throw(RecordError("$path: `type` must be \"device-twin\", got $(repr(type_))"))
    for field in ("id", "family", "parameters")
        haskey(fm, field) || throw(RecordError("$path: missing required field `$field`"))
    end
    params = fm["parameters"]
    params isa Dict || throw(RecordError("$path: `parameters` must be a mapping"))

    return TwinRecord(
        string(fm["id"]),
        string(fm["family"]),
        string(get(fm, "platform", fm["family"])),
        string(get(fm, "status", "seed")),
        Dict{String, Any}(string(k) => v for (k, v) in params),
        Dict{String, Any}(string(k) => v for (k, v) in get(fm, "noise", Dict())),
        Dict{String, Any}(string(k) => v for (k, v) in get(fm, "drift_priors", Dict())),
        Dict{String, Any}(string(k) => v for (k, v) in get(fm, "provenance", Dict())),
        body,
    )
end

@testitem "load_record — parses a vault twin record" begin
    using Strumento
    fixture = joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "bosonic.md")
    rec = load_record(fixture)
    @test rec.id == "synthetic-bosonic"
    @test rec.family == "bosonic"
    @test rec.platform == "bosonic"
    @test rec.status == "seed"
    @test rec.parameters["chi_kHz"] == -298.4
    @test rec.parameters["N_fock"] == 12
    @test rec.drift_priors["chi_kHz"]["process"] == "ou"
    @test occursin("Synthetic", rec.provenance["source"])
    @test occursin("GKP", rec.body)
end

@testitem "load_record — errors name the missing field" begin
    using Strumento
    path = joinpath(mktempdir(), "bad-record.md")
    write(path, "---\ntype: device-twin\nfamily: bosonic\n---\n# no id\n")
    try
        load_record(path)
        @test false
    catch err
        @test err isa RecordError
        @test occursin("id", sprint(showerror, err))
    end
end

# ─── Spec-floor extensions (issue #15) ───────────────────────────────────────
# The four seed families' shapes (committed synthetic fixtures), provenance
# round-tripping, loader defaults, and the full validation-error matrix.

@testitem "load_record — parses the transmon seed family (telegraph priors)" begin
    using Strumento
    rec = load_record(joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "transmon.md"))
    @test rec.id == "synthetic-transmon"
    @test rec.family == "transmon"
    @test rec.platform == "transmon"
    @test rec.status == "seed"
    @test rec.parameters["omega_GHz"] == 4.7
    @test rec.parameters["levels"] == 3
    @test rec.parameters["drive_max_GHz"] == 0.06
    pri = rec.drift_priors["omega_GHz"]
    @test pri["process"] == "telegraph"          # the TLS signature family
    @test pri["gamma_up_per_day"] == 1.5
    @test pri["amplitude_rel"] == 4.0e-5         # scientific notation parses as Float64
    @test pri["also_ou"]["tau_days"] == 5        # a nested prior map survives
    @test rec.drift_priors["delta_GHz"]["process"] == "ou"
    @test rec.noise["T1_us"]["value"] == 65.0
    @test rec.noise["T1_us"]["estimate"] == true
    @test rec.noise["readout_confusion"]["value"] == [[0.98, 0.02], [0.04, 0.96]]
    @test occursin("TLS", rec.body)
end

@testitem "load_record — parses the atoms seed family (string parameter, ramp + jump priors)" begin
    using Strumento
    rec = load_record(joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "atoms.md"))
    @test rec.id == "synthetic-atoms"
    @test rec.family == "atoms"
    @test rec.platform == "rydberg"              # platform may differ from family
    @test rec.parameters["species"] == "Rb87"    # a string parameter is carried, not coerced
    @test rec.parameters["C6_MHz_um6"] == 542000.0
    @test rec.parameters["clock_ns"] == 4.0
    @test rec.drift_priors["omega_max_MHz"]["process"] == "ou"
    @test rec.drift_priors["detuning_offset_MHz"]["process"] == "ramp"
    @test rec.drift_priors["detuning_offset_MHz"]["rate_MHz_per_day"] == 0.35
    @test rec.drift_priors["atom_positions_um"]["process"] == "jump"
    @test rec.noise["tau_R_us"]["value"] == 75.0
    @test occursin("relock", rec.body)
end

@testitem "load_record — parses the spin seed family (measured noise flags)" begin
    using Strumento
    rec = load_record(joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "spin.md"))
    @test rec.id == "synthetic-spin"
    @test rec.family == "spin"
    @test rec.platform == "spin"
    @test rec.parameters["delta_MHz"] == 45.0
    @test rec.parameters["E_Z2_GHz"] - rec.parameters["E_Z1_GHz"] ≈ 0.05   # the Zeeman split
    @test rec.drift_priors["delta_MHz"]["process"] == "ou"
    @test rec.drift_priors["delta_MHz"]["tau_days"] == 1
    @test rec.drift_priors["J_max_MHz"]["sigma_rel"] == 0.008
    @test rec.noise["T2_star_us"]["value"] == 0.4
    @test rec.noise["T2_star_us"]["estimate"] == false   # measured, not placeholder
    @test rec.noise["gamma_cross_rel"]["estimate"] == false
    @test occursin("charge noise", rec.body)
end

@testitem "load_record — provenance round-trips across the four seed families" begin
    using Strumento
    for family in ("bosonic", "transmon", "atoms", "spin")
        rec = load_record(joinpath(pkgdir(Strumento), "test", "fixtures", "twins", "$family.md"))
        @test occursin("Synthetic fixture", rec.provenance["source"])   # exact source string
        @test string(rec.provenance["measured"]) == "2026-08-28"        # the date round-trips
        @test occursin("synthetic", rec.provenance["note"])             # the note round-trips
        @test Set(keys(rec.provenance)) == Set(["source", "measured", "note"])
    end
end

@testitem "load_record — defaults: platform ← family, status ← seed, empty maps" begin
    using Strumento
    path = joinpath(mktempdir(), "minimal.md")
    write(path, "---\ntype: device-twin\nid: minimal\nfamily: bosonic\nparameters:\n  a: 1.0\n---\n# body\n")
    rec = load_record(path)
    @test rec.platform == "bosonic"                 # falls back to family
    @test rec.status == "seed"                      # the default status
    @test rec.noise == Dict{String, Any}()
    @test rec.drift_priors == Dict{String, Any}()
    @test rec.provenance == Dict{String, Any}()
    @test rec.body == "# body"                      # prose body, stripped
end

@testitem "load_record — every missing required field is named in the error" begin
    using Strumento
    dir = mktempdir()
    cases = [
        ("no-id.md",     "---\ntype: device-twin\nfamily: bosonic\nparameters: {a: 1.0}\n---\nbody\n", "id"),
        ("no-family.md", "---\ntype: device-twin\nid: x\nparameters: {a: 1.0}\n---\nbody\n", "family"),
        ("no-params.md", "---\ntype: device-twin\nid: x\nfamily: bosonic\n---\nbody\n", "parameters"),
    ]
    for (name, text, field) in cases
        path = joinpath(dir, name)
        write(path, text)
        err = try
            load_record(path); nothing
        catch e
            e
        end
        @test err isa RecordError
        @test occursin("missing required field `$field`", sprint(showerror, err))
    end
end

@testitem "load_record — a wrong type is rejected, naming the requirement" begin
    using Strumento
    path = joinpath(mktempdir(), "wrong-type.md")
    write(path, "---\ntype: device\nid: x\nfamily: bosonic\nparameters: {a: 1.0}\n---\nbody\n")
    err = try
        load_record(path); nothing
    catch e
        e
    end
    @test err isa RecordError
    msg = sprint(showerror, err)
    @test occursin("type", msg)
    @test occursin("device-twin", msg)
end

@testitem "load_record — a record without frontmatter is rejected" begin
    using Strumento
    path = joinpath(mktempdir(), "no-fm.md")
    write(path, "# just prose, no YAML block\n")
    err = try
        load_record(path); nothing
    catch e
        e
    end
    @test err isa RecordError
    @test occursin("no YAML frontmatter", sprint(showerror, err))
end

@testitem "load_record — a missing file is rejected" begin
    using Strumento
    path = joinpath(mktempdir(), "does-not-exist.md")
    err = try
        load_record(path); nothing
    catch e
        e
    end
    @test err isa RecordError
    @test occursin("record not found", sprint(showerror, err))
end

@testitem "load_record — non-mapping parameters are rejected" begin
    using Strumento
    path = joinpath(mktempdir(), "params-list.md")
    write(path, "---\ntype: device-twin\nid: x\nfamily: bosonic\nparameters: [1, 2, 3]\n---\nbody\n")
    err = try
        load_record(path); nothing
    catch e
        e
    end
    @test err isa RecordError
    @test occursin("parameters", sprint(showerror, err))
    @test occursin("mapping", sprint(showerror, err))
end
