module SpeakerModel

using LinearAlgebra, Printf, TOML, Dates
export Driver, Cabinet, Design, Response, demo, simulate, validate, net_volume,
       tuning, crossover, save_design, load_design, export_report, export_room_bundle, read_frd, piston

const RHO = 1.204
const SOUND = 343.0
const PREF = 20e-6

Base.@kwdef struct Driver
    name::String = "Example woofer"
    fs::Float64 = 35.0
    qes::Float64 = 0.42
    qms::Float64 = 5.0
    vas::Float64 = 55.0 # litres
    sd::Float64 = 220.0 # cm²
    re::Float64 = 5.6
    le::Float64 = 0.5 # mH
    xmax::Float64 = 6.0 # one-way peak mm
    diameter::Float64 = 210.0 # outside frame diameter, mm
    x::Float64 = 0.15 # baffle coordinates, m, origin bottom left
    y::Float64 = 0.32
    depth::Float64 = 0.0 # acoustic center behind front panel, mm
    chamber::Float64 = 0.0 # 0 = shared main enclosure; >0 = own sealed chamber, L
    highpass::Float64 = 0.0 # 0 bypass
    lowpass::Float64 = 2200.0
    hp_slope::Int = 24
    lp_slope::Int = 24
    family::String = "Linkwitz-Riley"
    polarity::Int = 1
    delay::Float64 = 0.0 # ms
    enabled::Bool = true
    frd::String = "" # measured mounted response at 2.83 V / 1 m; empty = T/S model
end

Base.@kwdef struct Cabinet
    width::Float64 = 0.30 # outside dimensions, m
    height::Float64 = 0.90
    depth::Float64 = 0.32
    thickness::Float64 = 18.0 # mm
    displacement::Float64 = 2.0 # drivers/braces, L, extra to chambers + port
    kind::String = "Vented"
    port_diameter::Float64 = 50.0 # mm
    port_length::Float64 = 180.0 # physical length, mm
    ports::Int = 1
    loss_q::Float64 = 15.0 # lumped parallel enclosure loss
    port_q::Float64 = 10.0
    port_x::Float64 = 0.15
    port_y::Float64 = 0.13
    baffle_step::Bool = true
end

Base.@kwdef struct Design
    cabinet::Cabinet = Cabinet()
    drivers::Vector{Driver} = [Driver()]
    voltage::Float64 = 2.83 # RMS, independent ideal voltage source per driver
    distance::Float64 = 2.0 # listener radius from baffle center
    horizontal::Float64 = 0.0 # deg
    vertical::Float64 = 0.0
end

function demo()
    tweeter = Driver(name="Example tweeter",fs=950,qes=0.8,qms=3,vas=0.025,
        sd=7,re=5.4,le=0.04,xmax=0.3,diameter=95,x=0.15,y=0.64,chamber=0.2,
        highpass=2200,lowpass=0)
    Design(drivers=[Driver(),tweeter])
end

function net_volume(d::Design)
    c = d.cabinet; t = c.thickness/1000
    gross = (c.width-2t)*(c.height-2t)*(c.depth-2t)*1000
    port_l = c.kind == "Vented" ? c.ports*π*(c.port_diameter/2000)^2*c.port_length : 0.0
    # Chamber volumes reserve cabinet space even if a driver is electrically disabled.
    gross - c.displacement - sum(x.chamber for x in d.drivers) - port_l
end

function tuning(d::Design)
    c = d.cabinet
    c.kind == "Sealed" && return 0.0
    a = c.port_diameter/2000
    effective_length = c.port_length/1000 + 1.46a # one flanged + one unflanged end
    SOUND/(2π)*sqrt(c.ports*π*a^2/(net_volume(d)/1000*effective_length))
end

function validate(d::Design)
    c = d.cabinet
    for name in fieldnames(Cabinet)
        v = getfield(c,name)
        v isa Real && !isfinite(v) && throw(ArgumentError("Cabinet $name must be finite."))
    end
    for name in (:width,:height,:depth)
        0.08 <= getfield(c,name) <= 4 || throw(ArgumentError("Cabinet $name must be between 0.08 and 4 m."))
        getfield(c,name) > 2c.thickness/1000 || throw(ArgumentError("Wall thickness leaves no internal space."))
    end
    1 <= c.thickness <= 100 || throw(ArgumentError("Wall thickness must be 1–100 mm."))
    c.displacement >= 0 || throw(ArgumentError("Displacement cannot be negative."))
    c.kind in ("Sealed","Vented") || throw(ArgumentError("Select Sealed or Vented."))
    1 <= c.loss_q <= 100 && 1 <= c.port_q <= 100 || throw(ArgumentError("Loss Q values must be 1–100."))
    1 <= length(d.drivers) <= 8 || throw(ArgumentError("Use 1–8 drivers."))
    for (i,x) in enumerate(d.drivers)
        for name in fieldnames(Driver)
            v = getfield(x,name)
            v isa Real && !isfinite(v) && throw(ArgumentError("Driver $i $name must be finite."))
        end
        !isempty(strip(x.name)) || throw(ArgumentError("Driver $i needs a name."))
        10 <= x.fs <= 6000 && 0.05 <= x.qes <= 20 && 0.1 <= x.qms <= 100 ||
            throw(ArgumentError("Driver $i: check Fs (10–6000 Hz), Qes (0.05–20) and Qms (0.1–100)."))
        0.001 <= x.vas <= 2000 && 0.5 <= x.sd <= 3000 || throw(ArgumentError("Driver $i: check Vas and Sd."))
        0.5 <= x.re <= 100 && 0 <= x.le <= 20 && 0.01 <= x.xmax <= 100 ||
            throw(ArgumentError("Driver $i: check Re, Le and Xmax."))
        10 <= x.diameter <= 1000 || throw(ArgumentError("Driver $i: frame diameter must be 10–1000 mm."))
        sqrt(x.sd/1e4/π) <= x.diameter/2000 || throw(ArgumentError("Driver $i: piston area exceeds frame area."))
        r = x.diameter/2000
        r <= x.x <= c.width-r && r <= x.y <= c.height-r ||
            throw(ArgumentError("Driver $i frame must fit on the front baffle."))
        0 <= x.depth <= 500 && 0 <= x.chamber <= 500 || throw(ArgumentError("Driver $i: depth/chamber cannot be negative or excessive."))
        all(f->f==0 || 10 <= f <= 20000,(x.highpass,x.lowpass)) ||
            throw(ArgumentError("Driver $i: crossover frequencies must be 0 (bypass) or 10–20000 Hz."))
        x.highpass == 0 || x.lowpass == 0 || x.highpass < x.lowpass ||
            throw(ArgumentError("Driver $i: high-pass must be below low-pass."))
        x.family in ("Butterworth","Linkwitz-Riley") || throw(ArgumentError("Unknown crossover family."))
        for slope in (x.hp_slope,x.lp_slope)
            slope in (6,12,18,24,48) || throw(ArgumentError("Choose a slope of 6, 12, 18, 24 or 48 dB/oct."))
            x.family == "Linkwitz-Riley" && !(slope in (12,24,48)) &&
                throw(ArgumentError("Linkwitz-Riley supports 12, 24 and 48 dB/oct; use Butterworth for 6 or 18."))
        end
        x.polarity in (-1,1) && 0 <= x.delay <= 100 || throw(ArgumentError("Check polarity and delay."))
    end
    # Frames must not physically overlap, including muted drivers.
    for i in eachindex(d.drivers),j in 1:i-1
        a,b = d.drivers[i],d.drivers[j]
        hypot(a.x-b.x,a.y-b.y) >= (a.diameter+b.diameter)/2000 ||
            throw(ArgumentError("Driver frames $j and $i overlap."))
    end
    if c.kind == "Vented"
        10 <= c.port_diameter <= 300 && 10 <= c.port_length <= 2000 && 1 <= c.ports <= 4 ||
            throw(ArgumentError("Port: diameter 10–300 mm, length 10–2000 mm, count 1–4."))
        c.port_length/1000 < c.depth-2c.thickness/1000 || throw(ArgumentError("Straight port is longer than the internal cabinet depth."))
        r = c.port_diameter/2000
        # Multiple ports are shown side-by-side with one radius of clearance.
        halfspan = (c.ports-1)*1.5r+r
        halfspan <= c.port_x <= c.width-halfspan && r <= c.port_y <= c.height-r ||
            throw(ArgumentError("Port openings must fit on the front baffle."))
        for k in 1:c.ports, x in d.drivers
            px = c.port_x+(k-(c.ports+1)/2)*3r
            hypot(px-x.x,c.port_y-x.y) >= r+x.diameter/2000 || throw(ArgumentError("Port opening overlaps a driver frame."))
        end
    end
    net_volume(d) >= 0.1 || throw(ArgumentError("Net main volume must be at least 0.1 L after chambers, port and displacement."))
    all(isfinite,(d.voltage,d.distance,d.horizontal,d.vertical)) || throw(ArgumentError("Listening settings must be finite."))
    0.01 <= d.voltage <= 100 && 0.2 <= d.distance <= 50 || throw(ArgumentError("Voltage: 0.01–100 V RMS; distance: 0.2–50 m."))
    abs(d.horizontal) <= 80 && abs(d.vertical) <= 80 || throw(ArgumentError("Listening angles must be within ±80°."))
    d
end

function butter(s,n,high)
    poles = (cis(π*(2k+n-1)/(2n)) for k in 1:n)
    denominator = prod(s-p for p in poles)
    (high ? s^n : 1)/denominator
end

function filter_response(f,cut,slope,family,high)
    cut == 0 && return 1.0+0im
    n = slope ÷ 6
    s = im*f/cut
    family == "Linkwitz-Riley" ? butter(s,n÷2,high)^2 : butter(s,n,high)
end

function crossover(x::Driver,f)
    filter_response(f,x.highpass,x.hp_slope,x.family,true)*
    filter_response(f,x.lowpass,x.lp_slope,x.family,false)*x.polarity*cis(-2π*f*x.delay/1000)
end

# J1 power series at small/moderate arguments, asymptotic expansion beyond 12.
# Enough accuracy for an illustrative rigid-piston directivity model.
function bessel1(x)
    x < 0 && return -bessel1(-x)
    if x <= 12
        term = x/2; total = term
        for k in 1:80
            term *= -(x/2)^2/(k*(k+1))
            total += term
            abs(term) < 1e-15 && break
        end
        return total
    end
    χ = x-3π/4
    sqrt(2/(π*x))*((1+15/(128x^2)-14175/(98304x^4))*cos(χ)-
        (3/(8x)-315/(3072x^3))*sin(χ))
end
piston(ka_sine) = abs(ka_sine) < 1e-7 ? 1.0 : 2bessel1(ka_sine)/ka_sine

struct Measured
    f::Vector{Float64}
    db::Vector{Float64}
    phase::Vector{Float64} # unwrapped radians
end

function read_frd(path)
    rows = NTuple{3,Float64}[]
    for (i,line) in enumerate(eachline(path))
        line = strip(line)
        (isempty(line) || any(p->startswith(line,p),("#","*",";"))) && continue
        cols = split(replace(line,','=>' '))
        length(cols) >= 3 || throw(ArgumentError("FRD line $i: need frequency, SPL dB, phase degrees."))
        vals = tryparse.(Float64,cols[1:3])
        any(isnothing,vals) && throw(ArgumentError("FRD line $i is not numeric (use # for comments)."))
        all(isfinite,vals) && vals[1] > 0 || throw(ArgumentError("Invalid FRD values at line $i."))
        push!(rows,Tuple(Float64.(vals)))
    end
    length(rows) >= 2 || throw(ArgumentError("FRD requires at least two data rows."))
    f = first.(rows)
    all(diff(f) .> 0) || throw(ArgumentError("FRD frequencies must increase strictly."))
    phase = deg2rad.(getindex.(rows,3))
    for i in 2:length(phase)
        phase[i] = phase[i-1]+mod(phase[i]-phase[i-1]+π,2π)-π
    end
    Measured(f,getindex.(rows,2),phase)
end

function interpolate(m::Measured,f)
    m.f[1] <= f <= m.f[end] || return ComplexF64(NaN,NaN)
    i = min(searchsortedlast(m.f,f),length(m.f)-1)
    a = log(f/m.f[i])/log(m.f[i+1]/m.f[i])
    db = (1-a)*m.db[i]+a*m.db[i+1]
    phase = (1-a)*m.phase[i]+a*m.phase[i+1]
    PREF*10^(db/20)*cis(phase)
end

struct Response
    design::Design
    frequency::Vector{Float64}
    total::Vector{ComplexF64}
    driver::Matrix{ComplexF64}
    port::Vector{ComplexF64}
    excursion::Matrix{Float64} # one-way peak mm; NaN for measured drivers
    port_speed::Vector{Float64} # peak m/s
    notes::Vector{String}
end

function simulate(design::Design; points=600,frequency_hz=nothing)
    d = deepcopy(validate(design)); c = d.cabinet
    100 <= points <= 4000 || throw(ArgumentError("Use 100–4000 frequency points."))
    if frequency_hz === nothing
        f = exp10.(range(log10(10),log10(20000);length=points))
        f[1]=10.0; f[end]=20000.0 # exact endpoints also match FRD range boundaries
    else
        f = Float64.(frequency_hz)
        2 <= length(f) <= 50000 && all(isfinite,f) && all(diff(f).>0) &&
            10 <= f[1] < f[end] <= 20000 || throw(ArgumentError("Export frequencies must increase within 10–20000 Hz (2–50000 points)."))
    end
    points = length(f)
    n = length(d.drivers)
    contributions = zeros(ComplexF64,points,n)
    port = zeros(ComplexF64,points)
    excursion = zeros(points,n)
    port_speed = zeros(points)
    measurements = [isempty(x.frd) ? nothing : read_frd(x.frd) for x in d.drivers]
    notes = ["Linear small-signal model; example driver parameters are illustrative.",
        "Ideal independent voltage drive per driver; crossover is a transfer function, not a passive circuit.",
        "Rigid pistons and an approximate width-dependent baffle step; no cone breakup, panel vibration, room reflections or detailed diffraction.",
        "Peak excursion and port speed are linear predictions; Xmax is a comparison limit, not a nonlinear limiter."]
    if any(!isnothing,measurements)
        push!(notes,"FRD is a fixed mounted response at 2.83 V RMS / 1 m, with flight time removed. Cabinet/port/piston/baffle modelling is bypassed for those drivers; filter and position remain active. No excursion is available. The sum is omitted outside the shared measured frequency range.")
        push!(notes,"Measured drivers are excluded from the modelled shared-chamber coupling. Use measured mode for crossover studies and T/S mode for enclosure studies.")
    end
    main = [i for i in 1:n if measurements[i] === nothing && d.drivers[i].chamber == 0]
    # Disabled main drivers remain mechanical loads with their terminals shorted.
    any(!x.enabled && x.chamber==0 && isempty(x.frd) for x in d.drivers) &&
        push!(notes,"Muted modelled drivers remain in their chamber with zero terminal voltage (shorted), so they can move from shared pressure.")
    Vbox = net_volume(d)/1000; Cbox = Vbox/(RHO*SOUND^2)
    fb = tuning(d); ωref = 2π*(c.kind=="Vented" ? fb : 50.0)
    leakage_r = c.loss_q/(ωref*Cbox)
    area_port = c.ports*π*(c.port_diameter/2000)^2
    mass_port = RHO*(c.port_length/1000+1.46*c.port_diameter/2000)/area_port
    radius = d.distance
    listener = (c.width/2+radius*cosd(d.vertical)*sind(d.horizontal),
        c.height/2+radius*sind(d.vertical),radius*cosd(d.vertical)*cosd(d.horizontal))
    function geometry(x,y,depth=0.0)
        dx,dy,dz = listener[1]-x,listener[2]-y,listener[3]+depth/1000
        r = sqrt(dx^2+dy^2+dz^2)
        r,sqrt(dx^2+dy^2)/r
    end
    geom = [geometry(x.x,x.y,x.depth) for x in d.drivers]
    port_distances = [geometry(c.port_x+(k-(c.ports+1)/2)*1.5*c.port_diameter/1000,c.port_y)[1] for k in 1:c.ports]
    for (a,freq) in enumerate(f)
        s = 2π*freq*im; k = 2π*freq/SOUND
        ze,zm,force,areas = zeros(ComplexF64,n),zeros(ComplexF64,n),zeros(ComplexF64,n),zeros(n)
        for (i,x) in enumerate(d.drivers)
            areas[i] = x.sd/1e4
            cms = (x.vas/1000)/(RHO*SOUND^2*areas[i]^2)
            mms = 1/((2π*x.fs)^2*cms)
            rms = 2π*x.fs*mms/x.qms
            bl = sqrt(2π*x.fs*mms*x.re/x.qes)
            ze[i] = x.re+s*x.le/1000
            zm[i] = rms+s*mms+1/(s*cms)+bl^2/ze[i]
            force[i] = x.enabled ? bl*d.voltage*crossover(x,freq)/ze[i] : 0
        end
        zp = c.kind=="Vented" ? (2π*fb*mass_port/c.port_q+s*mass_port) : ComplexF64(Inf)
        zb = 1/(s*Cbox+1/leakage_r+(c.kind=="Vented" ? 1/zp : 0))
        numerator = sum((areas[i]*force[i]/zm[i] for i in main);init=0im)
        feedback = sum((areas[i]^2/zm[i] for i in main);init=0im)
        pressure = zb*numerator/(1+zb*feedback)
        baffle = c.baffle_step ? (0.5+s/(2π*115/c.width))/(1+s/(2π*115/c.width)) : 1
        for (i,x) in enumerate(d.drivers)
            r,sine = geom[i]
            propagation = cis(-k*r)/r
            if measurements[i] !== nothing
                contributions[a,i] = x.enabled ? interpolate(measurements[i],freq)*
                    (d.voltage/2.83)*crossover(x,freq)*propagation : 0
                excursion[a,i] = NaN
                continue
            end
            load = x.chamber > 0 ? areas[i]^2/(s*(x.chamber/1000)/(RHO*SOUND^2)) : 0
            v = x.chamber > 0 ? force[i]/(zm[i]+load) : (force[i]-areas[i]*pressure)/zm[i]
            excursion[a,i] = abs(v/s)*sqrt(2)*1000
            directivity = piston(k*sqrt(areas[i]/π)*sine)
            contributions[a,i] = RHO*s*areas[i]*v/(2π)*propagation*directivity*baffle
        end
        if c.kind=="Vented" && !isempty(main)
            u = -pressure/zp
            port_speed[a] = abs(u)/area_port*sqrt(2)
            # Equal flow through each identical front port, summed coherently.
            port[a] = RHO*s*(u/c.ports)/(2π)*baffle*sum(cis(-k*r)/r for r in port_distances)
        end
    end
    total = vec(sum(contributions;dims=2)) + port
    Response(d,f,total,contributions,port,excursion,port_speed,notes)
end

to_dict(x) = Dict(string(k)=>getfield(x,k) for k in fieldnames(typeof(x)))
function save_design(path,d::Design)
    data = Dict("cabinet"=>to_dict(d.cabinet),"drivers"=>to_dict.(d.drivers),
        "listening"=>Dict(string(k)=>getfield(d,k) for k in (:voltage,:distance,:horizontal,:vertical)))
    open(path,"w") do io
        TOML.print(io,data;sorted=true)
    end
    path
end
function load_design(path)
    data = TOML.parsefile(path)
    kw(data) = (;(Symbol(k)=>v for (k,v) in data)...)
    c = Cabinet(;kw(data["cabinet"])...)
    drivers = [Driver(;kw(x)...) for x in data["drivers"]]
    # Relative measurement paths are relative to the saved project, not cwd.
    drivers = [isempty(x.frd) || isabspath(x.frd) ? x : Driver(;
        merge(kw(to_dict(x)),(;frd=normpath(joinpath(dirname(abspath(path)),x.frd))))...) for x in drivers]
    validate(Design(;cabinet=c,drivers=drivers,kw(data["listening"])...))
end

db(p) = 20log10(max(abs(p)/PREF,1e-8))
esc(x) = replace(string(x),'&'=>"&amp;",'<'=>"&lt;",'>'=>"&gt;",'"'=>"&quot;")

function plot_svg(r::Response,kind)
    values = kind==:spl ? [db.(r.total),[db.(r.driver[:,i]) for i in axes(r.driver,2)]...,db.(r.port)] :
        [r.excursion[:,i] for i in axes(r.excursion,2)]
    names = kind==:spl ? ["Total",getfield.(r.design.drivers,:name)...,"Port"] : getfield.(r.design.drivers,:name)
    colors = ["#152b43","#157ab3","#ca5726","#7b4eaa","#29916a","#c84477","#94710f","#488e99","#7080b0","#777777"]
    finite = filter(isfinite,vcat(values...))
    if kind==:spl
        ymax = isempty(finite) ? 100.0 : ceil(maximum(finite)/10)*10+5
        ymin = ymax-80
    else
        ymin = 0.0; ymax = max(1.0,isempty(finite) ? 1.0 : maximum(finite)*1.1)
    end
    io = IOBuffer()
    println(io,"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 900 370'><rect width='100%' height='100%' fill='white'/><g font-family='sans-serif' font-size='12' fill='#152b43'>")
    for f in (10,20,50,100,200,500,1000,2000,5000,10000,20000)
        x = 65+800*log(f/10)/log(2000)
        println(io,"<path d='M $x 40 V 310' stroke='#e0e7ed'/><text x='$x' y='330' text-anchor='middle'>$f</text>")
    end
    for a in 0:4
        value = ymin+(ymax-ymin)*a/4; y = 310-270*a/4
        println(io,@sprintf("<path d='M 65 %f H 865' stroke='#e0e7ed'/><text x='57' y='%f' text-anchor='end'>%.1f</text>",y,y+4,value))
    end
    for (i,v) in enumerate(values)
        buffer = String[]
        function flush_curve()
            isempty(buffer) && return
            println(io,"<polyline points='$(join(buffer," "))' fill='none' stroke='$(colors[i])' stroke-width='$(i==1 && kind==:spl ? 2.5 : 1.5)'/>")
            empty!(buffer)
        end
        for (f,y) in zip(r.frequency,v)
            if !isfinite(y)
                flush_curve(); continue
            end
            push!(buffer,@sprintf("%.2f,%.2f",65+800*log(f/10)/log(2000),310-270*(clamp(y,ymin,ymax)-ymin)/(ymax-ymin)))
        end
        flush_curve()
        println(io,"<text x='$(70+((i-1)%4)*205)' y='$(15+((i-1)÷4)*13)' fill='$(colors[i])'>$(esc(names[i]))</text>")
    end
    println(io,"<text x='450' y='355' text-anchor='middle'>Frequency [Hz]</text><text x='5' y='30'>$(kind==:spl ? "dB SPL" : "peak mm")</text></g></svg>")
    String(take!(io))
end

function export_report(r::Response,root=joinpath(@__DIR__,"reports"))
    dir = mktempdir(mkpath(root);prefix=Dates.format(now(),"yyyymmdd_HHMMSS_"),cleanup=false)
    d = deepcopy(r.design)
    # Bundle measurement inputs so a report's design can be reopened independently.
    for (i,x) in enumerate(d.drivers)
        if !isempty(x.frd)
            filename = "driver_$(i).frd"
            cp(x.frd,joinpath(dir,filename))
            d.drivers[i] = Driver(;merge((;(Symbol(k)=>v for (k,v) in to_dict(x))...),(;frd=filename))...)
        end
    end
    save_design(joinpath(dir,"design.toml"),d)
    open(joinpath(dir,"response.csv"),"w") do io
        println(io,join(["frequency_Hz","total_SPL_dB","total_phase_deg","port_SPL_dB","port_speed_peak_m_s",
            ["driver_$(i)_SPL_dB" for i in eachindex(d.drivers)]...,
            ["driver_$(i)_excursion_peak_mm" for i in eachindex(d.drivers)]...],','))
        for a in eachindex(r.frequency)
            vals = [r.frequency[a],db(r.total[a]),rad2deg(angle(r.total[a])),db(r.port[a]),r.port_speed[a],
                [db(r.driver[a,i]) for i in eachindex(d.drivers)]...,
                r.excursion[a,:]...]
            println(io,join(vals,','))
        end
    end
    spl = plot_svg(r,:spl); excursion = plot_svg(r,:excursion)
    write(joinpath(dir,"frequency_response.svg"),spl)
    write(joinpath(dir,"excursion.svg"),excursion)
    c = d.cabinet
    driver_tables = join(("<h3>$(esc(x.name))</h3><table>"*join(("<tr><td>$(esc(k))</td><td>$(esc(getfield(x,k)))</td></tr>" for k in fieldnames(Driver)),"")*"</table>" for x in d.drivers),"")
    cabinet_table = "<table>"*join(("<tr><td>$(esc(k))</td><td>$(esc(getfield(c,k)))</td></tr>" for k in fieldnames(Cabinet)),"")*"</table>"
    write(joinpath(dir,"report.html"),"""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Speaker Studio report</title>
    <style>body{font:15px/1.5 system-ui;color:#152b43;background:#eef2f6}main{max-width:1000px;margin:24px auto;padding:30px;background:white}svg{width:100%;height:auto}table{border-collapse:collapse;font-size:13px;width:100%}td{padding:3px 10px;border-bottom:1px solid #ddd}h2,h3{break-after:avoid}.note{background:#edf4fa;padding:14px}@media print{body{background:white}main{padding:0;margin:0}svg{break-inside:avoid}}</style><main>
    <h1>Speaker Studio</h1><p>$(esc(c.kind)) enclosure · $(round(net_volume(d);digits=2)) L net main volume · tuning $(round(tuning(d);digits=1)) Hz (0 = sealed)</p>
    <p>$(d.voltage) V RMS per driver · $(d.distance) m listening radius · horizontal $(d.horizontal)°, vertical $(d.vertical)°</p>
    <h2>Frequency response</h2>$spl<h2>Cone excursion</h2>$excursion
    <p>Port speed maximum: $(round(maximum(r.port_speed);digits=2)) m/s peak. Xmax is the entered one-way peak excursion limit. RMS input voltage is converted to peak excursion/port speed.</p>
    <div class="note"><strong>Assumptions and limits</strong><ul>$(join(("<li>$(esc(n))</li>" for n in r.notes),""))</ul></div>
    <h2>Cabinet</h2>$cabinet_table<h2>Drivers and crossovers</h2>$driver_tables
    <p>Units: cabinet dimensions/driver positions m; panel thickness, frame diameter, acoustic depth, port sizes and Xmax mm; Vas/chambers/displacement L; Sd cm²; Re Ω; Le mH; delays ms; frequencies Hz; slopes dB/octave. This report contains the applied design, not unsaved form edits.</p>
    <p>Open in a browser and print to PDF. Data and source settings are supplied in response.csv and design.toml.</p></main></html>""")
    dir
end

# Keep the bridge dependency-free: only strings, booleans, finite numbers and
# flat numeric arrays are needed. JSON escaping is explicit (Julia repr is not JSON).
function json_string(value)
    io=IOBuffer(); print(io,'"')
    for c in string(value)
        if c=='"'
            print(io,"\\\"")
        elseif c=='\\'
            print(io,"\\\\")
        elseif Int(c)<0x20
            @printf(io,"\\u%04x",Int(c))
        else
            print(io,c)
        end
    end
    print(io,'"'); String(take!(io))
end

"""Export a portable complex on-axis 1 m response, its graph and source design.

The common one-metre propagation phase is removed; the room supplies its own
distance/flight time. Cabinet/driver relative phases and crossover delays remain.
"""
function export_room_bundle(design::Design,root=joinpath(@__DIR__,"room_exports"))
    d=validate(design)
    reference=Design(cabinet=d.cabinet,drivers=deepcopy(d.drivers),voltage=d.voltage,
        distance=1.0,horizontal=0.0,vertical=0.0)
    low,high=10.0,20000.0
    for x in d.drivers
        if x.enabled && !isempty(x.frd)
            data=read_frd(x.frd)
            low=max(low,data.f[1]); high=min(high,data.f[end])
        end
    end
    low<high || throw(ArgumentError("Enabled measured drivers must share a frequency range within 10–20000 Hz."))
    # Dense Cartesian response samples preserve interference notches and delays;
    # plots still use compact display data independently of this transfer file.
    # Resolve bass resonances more finely than the high-frequency band. A 1 Hz
    # bass grid can miss curvature close to a low-tuned port at the band edge.
    fine_low=ceil(low*20)/20; fine_high=min(200.0,floor(high*20)/20)
    fine=fine_low<=fine_high ? collect(fine_low:0.05:fine_high) : Float64[]
    coarse_low=max(201.0,ceil(low))
    coarse=coarse_low<=floor(high) ? collect(coarse_low:1.0:floor(high)) : Float64[]
    grid=sort!(unique([low;fine;coarse;high]))
    response=simulate(reference;frequency_hz=grid)
    pressure=response.total .* cis.(2π .* grid ./ SOUND)
    all(z->isfinite(real(z)) && isfinite(imag(z)),pressure) ||
        throw(ArgumentError("Cannot export a nonfinite response. Check the measured driver ranges."))
    graph_grid=exp.(range(log(low),log(high);length=600))
    graph_grid[1]=low; graph_grid[end]=high
    graph=simulate(reference;frequency_hz=graph_grid)
    dir=export_report(graph,root)
    path=joinpath(dir,"speaker_room_profile.json")
    open(path,"w") do io
        println(io,"{")
        println(io,"  \"format\": \"speaker-studio-room-profile\",")
        println(io,"  \"version\": 1,")
        println(io,"  \"name\": ",json_string(join(getfield.(d.drivers,:name)," + ")),",")
        println(io,"  \"reference_distance_m\": 1.0,")
        println(io,"  \"reference_voltage_rms\": ",d.voltage,",")
        println(io,"  \"sound_speed_m_s\": ",SOUND,",")
        println(io,"  \"propagation_delay_removed\": true,")
        println(io,"  \"equivalent_omnidirectional\": true,")
        println(io,"  \"maximum_frequency_step_hz\": ",maximum(diff(grid)),",")
        println(io,"  \"notes\": ",json_string("On-axis equivalent point source at 1 m. Cabinet and crossover response retained; common 1 m propagation delay removed. Room supplies distance and reflections. Angular radiation, cabinet scattering and near-field driver separation are not transferred."),",")
        for (index,(key,values)) in enumerate((("frequency_hz",grid),("pressure_real_pa",real.(pressure)),("pressure_imag_pa",imag.(pressure))))
            print(io,"  ",json_string(key),": [")
            for (i,v) in enumerate(values)
                i>1 && print(io,',')
                print(io,v)
            end
            println(io,index==3 ? "]" : "],")
        end
        println(io,"}")
    end
    write(joinpath(dir,"LOAD_IN_ROOM.txt"),"""In the new Python room GUI (room_gui_designed_speakers.py):
    1. Select a room speaker.
    2. Click Load speaker design and choose speaker_room_profile.json from this folder.
    3. Repeat for other room speakers, then create the room report.

    frequency_response.svg / report.html show the exported on-axis 1 m speaker response.
    reference_voltage_rms is the per-driver RMS voltage used for this export.
    The room applies its speaker gain in addition to this level.
    This fixed on-axis response is treated as omnidirectional in the room.
    """)
    dir
end

end
