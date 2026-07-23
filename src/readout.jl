# Readout conversion (pure function): raw per-measurement IQ → Vector{Measurement}.
#
# `raw` is indexed in alignment with `indices` (the MeasurementModel knot indices
# into 1:N): `raw[k]` is the IQ blob for measurement at knot `indices[k]`. The
# caller-supplied `discriminator` maps one IQ blob → a data vector (e.g. level
# populations or Pauli expectations). This is the only device/calibration-specific
# step on the readout side, so it is supplied by the user, not owned here.

"""
    iq_to_measurements(raw, discriminator, indices) → Vector{Measurement}

Map each raw IQ blob `raw[k]` through `discriminator` and tag it with knot index
`indices[k]`. `length(raw) == length(indices)` is required.
"""
function iq_to_measurements(raw::AbstractVector, discriminator, indices::Vector{Int})
    length(raw) == length(indices) ||
        error("iq_to_measurements: $(length(raw)) raw blobs vs $(length(indices)) indices")
    return [Measurement(collect(Float64, discriminator(raw[k])), indices[k])
            for k in eachindex(indices)]
end

@testitem "iq_to_measurements maps blobs to measurements at indices" begin
    using Strumento
    # Trivial discriminator: real part of a complex blob = populations.
    raw = [ComplexF64[0.7, 0.3], ComplexF64[0.2, 0.8]]
    indices = [5, 11]
    ms = iq_to_measurements(raw, b -> real.(b), indices)
    @test length(ms) == 2
    @test ms[1].data ≈ [0.7, 0.3]
    @test ms[1].index == 5
    @test ms[2].index == 11
    # length mismatch throws
    @test_throws ErrorException iq_to_measurements(raw, b -> real.(b), [1])
end
