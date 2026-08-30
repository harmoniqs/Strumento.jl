# Twin records — typed views of the vault's `model-of-lab/<id>.md` documents.
# Code loads records; it never owns parameters (spec-20260803-043304).
#
# Absorbed from harmoniqs/Sosia.jl (spec-20260803-043304-digital-twins-sosia),
# issue #15 — ported tests first (RED), implementation follows.

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
