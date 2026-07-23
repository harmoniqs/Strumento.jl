# StrumentoSoc — the real-board path, delegating to the Python `strumento` package
# over PythonCall. This is the option-(a) seam (spec D18 / §16.4): Julia does NOT
# assemble an AveragerProgramV2 itself; it hands the solved pulse to Python
# `strumento`, which owns the pulse-IR → compile → acquire → reduce path. One source
# of truth (Python), a Julia face here.
#
# `strumento` is imported LAZILY inside the constructor (runtime, not load-time), so
# loading Strumento.jl and the whole MockSoc path never touch Python. The delegation
# body expresses the concrete calls, but the exact device wiring / drive_map / reduce
# conventions are finalized against a board with the QICK collaboration — so this path
# is NOT exercised in CI (constructing a StrumentoSoc requires the Python package).

"""
    StrumentoSoc(device; drive_map, dac_rate, adc_rate, board=nothing)

Real board reached by delegating to the Python `strumento` framework via PythonCall.
`device` is a strumento device-instance YAML path (or a Python `Device` handle);
`drive_map` maps each Intonato drive index to a `(drive_index, line, role, carrier_mhz)`
tuple naming the strumento wiring line/role and its carrier. On `execute!`, the played
pulse is handed to `strumento.from_solution` and run through a `StrumentoProgram` on the
board — Julia never assembles the program.

`strumento` (and `qick`) are imported lazily here; an actionable error is raised if the
Python package is unavailable. Hardware-only — not run in CI.
"""
mutable struct StrumentoSoc <: AbstractSoc
    strumento::Py          # the imported `strumento` module
    device::Py             # a strumento Device (Python)
    board::Py              # the board soc (a qick soc / strumento MockQickSocV2), or py-None
    drive_map::Vector{Tuple{Int,String,String,Float64}}   # (drive_index, line, role, carrier_mhz)
    dac_rate::Float64
    adc_rate::Float64
end

function StrumentoSoc(device; drive_map::Vector{<:Tuple}, dac_rate::Real, adc_rate::Real,
                      board = nothing)
    st = try
        pyimport("strumento")
    catch e
        error("StrumentoSoc requires the Python `strumento` package in the board's " *
              "Python environment (the open QICK tProc-v2 framework this package is the " *
              "Julia face of). `pyimport(\"strumento\")` failed: $e")
    end
    dev = device isa Py ? device : st.Device.load(string(device))
    bd = board === nothing ? pybuiltins.None : board
    dm = Tuple{Int,String,String,Float64}[
        (Int(d), String(line), String(role), Float64(f)) for (d, line, role, f) in drive_map
    ]
    return StrumentoSoc(st, dev, bd, dm, Float64(dac_rate), Float64(adc_rate))
end

dac_rate(soc::StrumentoSoc) = soc.dac_rate
adc_rate(soc::StrumentoSoc) = soc.adc_rate

# execute! — hand the pulse to Python `strumento` (from_solution → program → acquire →
# reduce). This replaces the old inline-qick-assembly stub: strumento owns translation.
function execute!(soc::StrumentoSoc, pulse::AbstractPulse, ::QickChannelMap,
                  indices::Vector{Int})
    T = duration(pulse)
    nsamp = floor(Int, T * soc.dac_rate) + 1
    times = collect(range(0.0, T, length = nsamp))
    ctrls = sample(pulse, times)                       # (n_drives, nsamp)

    # Build strumento's solution dict {times, controls: {line_name: samples}} and a
    # drive_map {line_name: (LineRef(line, role), carrier_mhz)}.
    LineRef = soc.strumento.LineRef
    controls = pydict()
    py_drive_map = pydict()
    for (d, line, role, carrier) in soc.drive_map
        controls[line] = pylist(ctrls[d, :])
        py_drive_map[line] = pytuple((LineRef(line, role), carrier))
    end
    solution = pydict(["times" => pylist(times), "controls" => controls])

    seq = soc.strumento.from_solution(solution; drive_map = py_drive_map,
                                      gain_calib = _gain_calib(soc), dac_rate = soc.dac_rate)
    StrumentoProgram = pyimport("strumento.core.program").StrumentoProgram
    prog = StrumentoProgram(soc.device; seq = seq, soc = soc.board)
    result = prog.acquire(soc.board; progress = false)

    # Reduce to per-index IQ blobs. The concrete reduce (readout-kind projection →
    # measurement vectors keyed by knot index) is finalized with the collaboration;
    # here we surface the averaged I/Q the result carries.
    return _result_to_blobs(result, indices)
end

# The physical-amplitude → v2-fraction reference strumento's from_solution needs. On a
# real device this comes from an amplitude-Rabi calibration (a strumento PiPulseReference);
# supplied by the collaboration's device config. Placeholder identity until then.
_gain_calib(::StrumentoSoc) = pyimport("strumento.packs.cqed.calibration").PiPulseReference(
    pi_gain_frac = 1.0, pi_rabi_mhz = 1.0)

function _result_to_blobs(result::Py, indices::Vector{Int})
    avgi = pyconvert(Vector{Float64}, result.avgi)
    avgq = pyconvert(Vector{Float64}, result.avgq)
    # one blob per requested knot index (the collaboration finalizes multi-knot readout)
    return [ComplexF64.(avgi) .+ im .* ComplexF64.(avgq) for _ in indices]
end

@testitem "StrumentoSoc is an AbstractSoc (type only; no Python/board in CI)" begin
    using Strumento
    @test StrumentoSoc <: Strumento.AbstractSoc
    # Not constructed here: that needs the Python `strumento` package + a board, and
    # would initialize PythonCall's interpreter. The delegation path is validated by
    # the collaboration on hardware.
end
