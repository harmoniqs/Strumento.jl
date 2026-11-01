# The v0.4 deprecation-shim contract (issue #39): the 0.3 base names are
# Intonato's / Intonato.Twins' objects (identity, not copies), loading warns
# exactly once with the migration pointer, and the deleted layers are gone.

@testmodule ShimNames begin
    # The 0.3 base export surface whose home is now Intonato's top level, plus
    # MockSoc (0.3: the Piccolo extension).
    const INTONATO = [
        :AbstractSoc,
        :execute!, :load_envelope!, :play_program!, :acquire, :dac_rate, :adc_rate,
        :set_gate!, :get_gate, :gate_snapshot,
        :QickChannelMap, :QickGenChannel,
        :DCAxis, :DCAxisMap, :gate_names, :axis_for,
        :pulse_to_envelopes, :QickProgram,
        :iq_to_measurements, :Measurement,
        :MockSoc,
    ]
    # The 0.3 twin surface (base twin core + the wiring map), plus TwinSoc
    # (0.3: the Piccolo extension) — now Intonato.Twins.
    const TWINS = [
        :TwinWiringMap, :TwinGenWiring, :wiring_for,
        :DriftProcess, :OrnsteinUhlenbeck, :step!,
        :Ramp, :RandomTelegraph, :JumpSchedule, :DriftPlan, :apply,
        :DigitalTwin, :instantiate, :believed, :advance!, :calibrate!,
        :TwinRecord, :RecordError, :load_record,
        :TwinSoc,
    ]
    # Names from the deleted layers (twin job server, bring-up procedures,
    # certification gates, Python bring-up bridge) — not migrated anywhere.
    const DELETED = [
        :TwinJobServer, :BringupBridge,
        :RehearsalRig, :wire_address, :stop!,
        :ResonatorSweepDesign, :comb_geometry, :BringupSchedule, :BringupJob,
        :BringupResult, :ResonatorSweepFit, :propose, :run_over_wire, :write_back!,
        :run_resonator_sweep, :fixture_comb_jobs,
        :RabiSweepDesign, :rabi_axis, :rabi_geometry, :RabiSchedule, :RabiJob,
        :RabiResult, :RabiSweepFit, :propose_rabi, :run_rabi_over_wire,
        :run_rabi_sweep, :fixture_rabi_job,
        :BosonicCertDesign, :BosonicCertResult, :BosonicCalibration,
        :BosonicTransferResult, :certify_parameter_recovery,
        :certify_calibration_transfer, :estimate_readout_confusion,
        :calibration_transfer_metric,
    ]
end

@testitem "shim — the 0.3 base names are Intonato's objects (identity)" setup = [ShimNames] begin
    using Intonato
    exported = names(Strumento)
    for n in ShimNames.INTONATO
        @test n in exported
        @test getfield(Strumento, n) === getfield(Intonato, n)
    end
    @test Strumento.Measurement === Intonato.Measurement
    @test Strumento.MockSoc === Intonato.MockSoc
end

@testitem "shim — the twin names are Intonato.Twins' objects (identity)" setup = [ShimNames] begin
    using Intonato
    exported = names(Strumento)
    for n in ShimNames.TWINS
        @test n in exported
        @test getfield(Strumento, n) === getfield(Intonato.Twins, n)
    end
    @test Strumento.TwinSoc === Intonato.Twins.TwinSoc
    @test parentmodule(Strumento.DigitalTwin) === Intonato.Twins
end

@testitem "shim — the export surface is exactly the migrated names" setup = [ShimNames] begin
    @test Set(filter(!=(:Strumento), names(Strumento))) ==
          Set(vcat(ShimNames.INTONATO, ShimNames.TWINS))
end

@testitem "shim — the deleted layers are not defined" setup = [ShimNames] begin
    for n in ShimNames.DELETED
        @test !isdefined(Strumento, n)
    end
    # The 0.3 extensions are gone: no weakdep can trigger them.
    for ext in (:StrumentoPiccoloExt, :StrumentoPythonCallExt,
                :StrumentoBringupExt, :StrumentoJobServerExt)
        @test Base.get_extension(Strumento, ext) === nothing
    end
end

@testitem "shim — loading warns exactly once with the migration pointer" begin
    # A fresh child process: __init__ semantics (and maxlog=1 dedup across a
    # repeated __init__ call) are only observable on a first load.
    script = """
    using Strumento
    Strumento.__init__()
    """
    err = IOBuffer()
    out = IOBuffer()
    cmd = `$(Base.julia_cmd()) --startup-file=no --color=no --project=$(Base.active_project()) -e $script`
    @test success(pipeline(cmd; stdout = out, stderr = err))
    log = String(take!(err))
    @test count("Strumento.jl is deprecated", log) == 1
    @test occursin("Intonato", log)
    @test occursin("Intonato.Twins", log)
    @test occursin("IntonatoPythonCallExt", log)
    @test occursin("https://github.com/harmoniqs/Intonato.jl#migrating-from-strumentojl", log)
end
