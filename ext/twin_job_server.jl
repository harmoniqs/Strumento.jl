# twin_job_server.jl — the server module body (included from
# StrumentoJobServerExt). The wire contract types, the payload reader, the
# envelope-level translation, the twin execution path, the job queue, and the
# stdlib HTTP server. Developed slice by slice (issue #29).

"""
    TwinJobServer

A board-shaped job server fronting a `TwinSoc`: it receives the D14 wire
contract's `CompiledJob` form, executes it through the twin face, and answers
`RawAcquisition`. See the extension module docstring for the boundary (the
twin models the DEVICE response at the envelope level — never tProc-v2
control flow) and the wire protocol.
"""
struct TwinJobServer end

@testitem "the twin job server rides its own Piccolo+JSON extension" begin
    using Strumento
    if Base.identify_package("Piccolo") === nothing ||
       Base.identify_package("JSON") === nothing
        @info "skipping: no Piccolo + JSON in this environment (job-server extension surface)"
        @test true
    else
        using Piccolo       # the physics trigger: loads StrumentoPiccoloExt
        using JSON          # the wire trigger: with Piccolo, attaches THIS extension
        ext = Base.get_extension(Strumento, :StrumentoJobServerExt)
        @test ext !== nothing
        @test isdefined(ext, :TwinJobServer)
        # the extension never leaks onto the parent (Julia 1.12 semantics)
        @test !isdefined(Strumento, :TwinJobServer)
    end
end
