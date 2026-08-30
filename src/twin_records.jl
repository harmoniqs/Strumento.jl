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
