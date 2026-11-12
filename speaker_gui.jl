#!/usr/bin/env julia
import Pkg
if isnothing(Base.find_package("GLMakie"))
    Pkg.activate(@__DIR__)
end
isnothing(Base.find_package("GLMakie")) && error(
    "GLMakie is missing. Run in this folder: julia --project=. -e 'using Pkg; Pkg.instantiate()'")

module SpeakerStudio
using GLMakie, Printf
include("speaker_model.jl")
using .SpeakerModel

const ROOT = @__DIR__
const COLORS = [:dodgerblue3,:darkorange2,:seagreen,:purple,:crimson,:goldenrod,:teal,:slateblue]
const PAGES = ["Driver data","Placement & measurement","Cabinet","Crossover","Listening"]
const SPECS = Dict(
    "Driver data"=>[
        (:name,"Name",String),(:enabled,"Voltage drive",[("On",true),("Muted / shorted",false)]),
        (:fs,"Fs [Hz]",Float64),(:qes,"Qes",Float64),(:qms,"Qms",Float64),
        (:vas,"Vas [L]",Float64),(:sd,"Sd [cm²]",Float64),(:re,"Re [Ω]",Float64),(:le,"Le [mH]",Float64),
        (:xmax,"Xmax, one-way peak [mm]",Float64)],
    "Placement & measurement"=>[
        (:diameter,"Frame diameter [mm]",Float64),
        (:x,"Baffle x [m]",Float64),(:y,"Baffle y [m]",Float64),(:depth,"Acoustic depth [mm]",Float64),
        (:chamber,"Own sealed chamber [L]",Float64),(:frd,"Mounted FRD path (optional)",String)],
    "Cabinet"=>[
        (:width,"Outside width [m]",Float64),(:height,"Outside height [m]",Float64),
        (:depth,"Outside depth [m]",Float64),(:thickness,"Panel thickness [mm]",Float64),
        (:displacement,"Drivers + braces [L]",Float64),(:kind,"Main enclosure",[("Sealed","Sealed"),("Bass-reflex","Vented")]),
        (:port_diameter,"Port diameter [mm]",Float64),(:port_length,"Port physical length [mm]",Float64),
        (:ports,"Port count",Int),(:port_x,"Port group center x [m]",Float64),(:port_y,"Port center y [m]",Float64),
        (:loss_q,"Enclosure loss Q",Float64),(:port_q,"Port loss Q",Float64),
        (:baffle_step,"Approximate baffle step",[("On",true),("Off",false)])],
    "Crossover"=>[
        (:highpass,"High-pass [Hz], 0 = off",Float64),(:lowpass,"Low-pass [Hz], 0 = off",Float64),
        (:hp_slope,"High-pass [dB/oct]",[(string(k),k) for k in (6,12,18,24,48)]),
        (:lp_slope,"Low-pass [dB/oct]",[(string(k),k) for k in (6,12,18,24,48)]),
        (:family,"Filter family",[("Linkwitz-Riley","Linkwitz-Riley"),("Butterworth","Butterworth")]),
        (:polarity,"Polarity",[("Normal",1),("Reversed",-1)]),(:delay,"Additional delay [ms]",Float64)],
    "Listening"=>[
        (:voltage,"Per-driver input [V RMS]",Float64),(:distance,"Listener radius [m]",Float64),
        (:horizontal,"Horizontal angle [°]",Float64),(:vertical,"Vertical angle [°]",Float64)])

kw(x) = (;(k=>getfield(x,k) for k in fieldnames(typeof(x)))...)
replace_driver(x;args...) = Driver(;merge(kw(x),(;args...))...)
spl(p) = 20log10(max(abs(p)/SpeakerModel.PREF,1e-8))

function control_visible!(block,value)
    block.blockscene.visible[] = value
    if block isa Textbox
        # Textbox uses a child scene for its editor and hit testing.
        block.focused[] = false
        for child in block.blockscene.children
            child.visible[] = value
        end
    elseif block isa Menu && !value
        block.is_open[] = false
    end
end

function create_app(;design=demo())
    set_theme!(Theme(fontsize=12,textcolor=:black,backgroundcolor=:white,
        Axis=(backgroundcolor=:white,titlecolor=:black,xlabelcolor=:black,ylabelcolor=:black,
            xticklabelcolor=:black,yticklabelcolor=:black,xgridcolor=(:gray,0.15),ygridcolor=(:gray,0.15)),
        Label=(color=:black,),Textbox=(boxcolor=:white,boxcolor_focused=RGBf(0.95,0.97,1),
            textcolor=:black,textcolor_placeholder=:gray,cursorcolor=:black,bordercolor=:gray),
        Button=(labelcolor=:black,buttoncolor=RGBf(0.9,0.94,0.98),
            buttoncolor_hover=RGBf(0.8,0.88,0.96),buttoncolor_active=RGBf(0.7,0.82,0.95)),
        Menu=(textcolor=:black,cell_color_inactive=:white,cell_color_active=RGBf(0.8,0.88,0.96),
            cell_color_hover=RGBf(0.9,0.94,0.98))))
    applied = Ref(deepcopy(design))
    result = Ref(simulate(design))
    selected = Ref(1); page = Ref(PAGES[1])
    loading = Ref(true); dirty = Ref(false); pending = Ref(false); edited_at = Ref(0.0)
    status = Observable("Illustrative two-way example. Enter your real driver data before using the predictions.")
    summary = Observable("")
    fig = Figure(size=(1380,800),figure_padding=(16,16,12,12))
    Label(fig[1,1:2],"Speaker Studio";fontsize=25,font=:bold,halign=:left)
    Label(fig[2,1:2],"Multiple drivers · enclosure loading · crossover slopes · coherent acoustic sum";
        halign=:left,color=RGBf(0.25,0.33,0.4))
    sidebar = GridLayout(fig[3,1];default_rowgap=7,default_colgap=6,tellheight=false,valign=:top)
    body = GridLayout(fig[3,2];default_rowgap=8,default_colgap=25)
    colsize!(fig.layout,1,Fixed(345))
    driver_menu = Menu(sidebar[1,1:2];options=[("$(i). $(x.name)",i) for (i,x) in enumerate(design.drivers)],default=1)
    buttons = GridLayout(sidebar[2,1:2];default_colgap=5)
    add_woofer = Button(buttons[1,1];label="+ Woofer")
    add_tweeter = Button(buttons[1,2];label="+ Tweeter")
    remove = Button(buttons[1,3];label="Remove")
    page_menu = Menu(sidebar[3,1:2];options=PAGES,default=PAGES[1])
    form = GridLayout(sidebar[4,1:2];default_rowgap=3,default_colgap=5,tellheight=false,valign=:top)
    labels,boxes,menus = Any[],Any[],Any[]
    for i in 1:14
        push!(labels,Label(form[i,1],"";halign=:left,fontsize=11))
        push!(boxes,Textbox(form[i,2];stored_string="",fontsize=11,width=139,height=22,reset_on_defocus=false))
        push!(menus,Menu(form[i,2];options=[("—",0)],default=1,width=139,height=22,fontsize=11))
        rowsize!(form,i,Fixed(22))
    end
    rowsize!(sidebar,4,Fixed(347))
    apply = Button(sidebar[5,1:2];label="Apply / recalculate",height=29)
    help_text = Observable("")
    Label(sidebar[6,1:2],help_text;width=340,height=50,word_wrap=true,fontsize=11,
        halign=:left,justification=:left)

    toolbar = GridLayout(body[1,1:2];default_colgap=8,default_rowgap=4)
    response_mode = Menu(toolbar[1,1];options=["SPL","Phase"],default="SPL",width=95)
    live = Menu(toolbar[1,2];options=[("Live update",true),("Manual update",false)],default=1,width=140)
    report = Button(toolbar[1,3];label="Create report",width=140)
    save_button = Button(toolbar[1,4];label="Save design",width=105)
    load_button = Button(toolbar[1,5];label="Load design",width=105)
    room_export = Button(toolbar[1,6];label="Export to room",width=135)
    project_path = Textbox(toolbar[2,1:6];stored_string=joinpath(ROOT,"my_speaker.toml"),
        height=24,fontsize=10)
    Label(body[2,1:2],summary;halign=:left,tellwidth=false,fontsize=12)
    axis = Axis(body[3,1:2];xlabel="Frequency [Hz]",ylabel="Sound pressure [dB SPL]",
        title="Individual drivers + port → coherent total",xscale=log10,titlesize=15)
    axis.xticks = ([10,20,50,100,200,500,1000,2000,5000,10000,20000],
        ["10","20","50","100","200","500","1k","2k","5k","10k","20k"])
    total_points,port_points = Observable(Point2f[]),Observable(Point2f[])
    lines!(axis,total_points;color=:black,linewidth=2.8)
    lines!(axis,port_points;color=:gray40,linewidth=1.6,linestyle=:dash)
    driver_points = [Observable(Point2f[]) for _ in 1:8]
    for i in 1:8
        lines!(axis,driver_points[i];color=COLORS[i],linewidth=1.5)
    end
    legend = GridLayout(body[4,1:2];default_rowgap=2,default_colgap=10)
    Label(legend[1,1],"Black: total";color=:black,halign=:left,fontsize=11)
    Label(legend[1,2],"Gray dashed: port";color=:gray40,halign=:left,fontsize=11)
    legend_labels = [Label(legend[2+(i-1)÷4,1+(i-1)%4],"";color=COLORS[i],halign=:left,
        fontsize=10,tellwidth=false) for i in 1:8]
    for i in 1:4
        colsize!(legend,i,Relative(0.25))
    end
    front = Axis(body[5,1];xlabel="x [m]",ylabel="y [m]",title="Front view · click to move selected driver",
        aspect=DataAspect(),titlesize=12,xlabelsize=11,ylabelsize=11)
    cabinet_points,inner_points = Observable(Point2f[]),Observable(Point2f[])
    lines!(front,cabinet_points;color=:black,linewidth=2)
    lines!(front,inner_points;color=:gray60,linestyle=:dash)
    frames = [Observable(Point2f[]) for _ in 1:8]
    for i in 1:8
        lines!(front,frames[i];color=COLORS[i],linewidth=2)
    end
    port_frames = [Observable(Point2f[]) for _ in 1:4]
    for p in port_frames
        lines!(front,p;color=:gray40,linewidth=2)
    end
    centers = Observable(fill(Point2f(NaN,NaN),8))
    text!(front,centers;text=string.(1:8),align=(:center,:center),fontsize=12,color=:black)
    stress = Axis(body[5,2];xlabel="Frequency [Hz]",ylabel="One-way peak [mm]",xscale=log10,
        title="Cone excursion · dashed = entered Xmax",titlesize=12,xlabelsize=11,ylabelsize=11)
    stress.xticks = ([10,100,1000,10000],["10","100","1k","10k"])
    stress_points = [Observable(Point2f[]) for _ in 1:8]
    xmax_points = [Observable(Point2f[]) for _ in 1:8]
    for i in 1:8
        lines!(stress,stress_points[i];color=COLORS[i],linewidth=1.5)
        lines!(stress,xmax_points[i];color=COLORS[i],linewidth=1,linestyle=:dash)
    end
    Label(fig[4,1:2],status;width=1335,height=43,word_wrap=true,halign=:left,
        justification=:left,fontsize=12,color=RGBf(0.15,0.25,0.4))
    Label(fig[5,1:2],"Small-signal estimates. T/S predicts enclosure behaviour; measured FRD mode fixes the mounted driver response. No level attenuation or passive component network.";
        halign=:left,fontsize=10,color=:gray35)
    rowsize!(fig.layout,1,Fixed(30)); rowsize!(fig.layout,2,Fixed(20))
    rowsize!(fig.layout,4,Fixed(43)); rowsize!(fig.layout,5,Fixed(15)); rowgap!(fig.layout,8)
    rowsize!(body,1,Fixed(58)); rowsize!(body,2,Fixed(22))
    rowsize!(body,4,Fixed(44)); rowsize!(body,5,Fixed(190))
    colsize!(body,1,Relative(0.43))

    function mark_edited()
        loading[] && return
        dirty[] = true; pending[] = true; edited_at[] = time()
        status[] = "Edits pending. Valid changes update after a short pause, or press Apply."
    end
    for i in 1:14
        on(_->mark_edited(),boxes[i].displayed_string)
        on(_->mark_edited(),menus[i].selection)
    end

    function fill_form()
        loading[] = true
        try
            specs = SPECS[page[]]
            d = applied[]
            object = page[] == "Cabinet" ? d.cabinet : page[] == "Listening" ? d : d.drivers[selected[]]
            for i in 1:14
                used = i <= length(specs)
                labels[i].visible[] = used
                control_visible!(boxes[i],false); control_visible!(menus[i],false)
                rowsize!(form,i,Fixed(used ? 22 : 0))
                used || continue
                key,label,kind = specs[i]
                labels[i].text[] = label
                value = getfield(object,key)
                if kind isa AbstractVector
                    menus[i].options[] = kind
                    menus[i].i_selected[] = something(findfirst(o->o[2]==value,kind),1)
                    control_visible!(menus[i],true)
                else
                    boxes[i].stored_string[] = string(value)
                    boxes[i].displayed_string[] = string(value)
                    control_visible!(boxes[i],true)
                end
            end
            help_text[] = page[] == "Placement & measurement" ?
                "Own chamber 0 = shared main box; positive = separate sealed litres. FRD path empty = T/S model. FRD needs Hz, dB SPL, phase°." :
                page[] == "Driver data" ? "Enter real datasheet parameters. Use Placement & measurement for position, own chamber and optional FRD input. Example drivers are illustrative." :
                page[] == "Cabinet" ? "Outside dimensions determine volume. Own chambers, driver/bracing displacement and port volume are subtracted. All ports face forward." :
                page[] == "Crossover" ? "0 Hz bypasses a filter. Linkwitz-Riley: 12/24/48 dB/oct; Butterworth: also 6/18. LR12 may need reversed polarity. No level attenuation." :
                "Distance/angles are measured from the baffle center. Each modelled driver has its own ideal amplifier at the entered RMS voltage."
        finally
            loading[] = false
        end
    end

    function update_driver_menu()
        loading[] = true
        try
            driver_menu.options[] = [("$i. $(x.name)",i) for (i,x) in enumerate(applied[].drivers)]
            driver_menu.i_selected[] = selected[]
        finally
            loading[] = false
        end
    end

    function refresh()
        r = result[]; d = applied[]; c = d.cabinet
        phase = response_mode.selection[] == "Phase"
        value(p) = phase ? rad2deg(angle(p)) : spl(p)
        total_points[] = Point2f.(r.frequency,value.(r.total))
        port_points[] = c.kind=="Vented" ? Point2f.(r.frequency,value.(r.port)) : Point2f[]
        all_values = value.(r.total)
        for i in 1:8
            used = i <= length(d.drivers)
            driver_points[i][] = used ? Point2f.(r.frequency,value.(r.driver[:,i])) : Point2f[]
            legend_labels[i].text[] = used ? "$i. $(d.drivers[i].name)" : ""
            if used
                append!(all_values,value.(r.driver[:,i]))
            end
            stress_points[i][] = used && isempty(d.drivers[i].frd) ? Point2f.(r.frequency,r.excursion[:,i]) : Point2f[]
            xmax_points[i][] = used && isempty(d.drivers[i].frd) ?
                Point2f[(10,d.drivers[i].xmax),(20000,d.drivers[i].xmax)] : Point2f[]
        end
        finite = filter(isfinite,all_values)
        top = isempty(finite) ? 100.0 : ceil(maximum(finite)/10)*10+5
        limits!(axis,10,20000,phase ? -185.0 : top-70,phase ? 185.0 : top)
        axis.ylabel[] = phase ? "Phase [degrees]" : "Sound pressure [dB SPL]"
        ex = filter(isfinite,vec(r.excursion))
        extop = max(maximum(x.xmax for x in d.drivers),isempty(ex) ? 1.0 : maximum(ex))*1.1
        limits!(stress,10,20000,0,extop)
        cabinet_points[] = Point2f[(0,0),(c.width,0),(c.width,c.height),(0,c.height),(0,0)]
        t = c.thickness/1000
        inner_points[] = Point2f[(t,t),(c.width-t,t),(c.width-t,c.height-t),(t,c.height-t),(t,t)]
        circle(x,y,rad) = Point2f[Point2f(x+rad*cos(a),y+rad*sin(a)) for a in range(0,2π;length=90)]
        for i in 1:8
            frames[i][] = i<=length(d.drivers) ? circle(d.drivers[i].x,d.drivers[i].y,d.drivers[i].diameter/2000) : Point2f[]
        end
        centers[] = [i<=length(d.drivers) ? Point2f(d.drivers[i].x,d.drivers[i].y) : Point2f(NaN,NaN) for i in 1:8]
        for i in 1:4
            px = c.port_x+(i-(c.ports+1)/2)*1.5*c.port_diameter/1000
            port_frames[i][] = c.kind=="Vented" && i<=c.ports ? circle(px,c.port_y,c.port_diameter/2000) : Point2f[]
        end
        limits!(front,-0.08*c.height,c.width+0.08*c.height,-0.04*c.height,c.height*1.04)
        measured = count(x->!isempty(x.frd),d.drivers)
        summary[] = @sprintf("%s · %.1f L net · Fb %.1f Hz · %.2f V RMS · %.1f m · Port peak %.1f m/s · %d FRD",
            c.kind,net_volume(d),tuning(d),d.voltage,d.distance,maximum(r.port_speed),measured)
        nothing
    end

    function parse_form()
        changes = Dict{Symbol,Any}()
        for (i,(key,label,kind)) in enumerate(SPECS[page[]])
            if kind isa AbstractVector
                changes[key] = menus[i].selection[]
            else
                text = strip(boxes[i].displayed_string[])
                v = kind==String ? text : tryparse(kind,text)
                v===nothing && throw(ArgumentError("Enter a valid number for $label."))
                key==:frd && !isempty(v) && (v=abspath(expanduser(v)))
                changes[key] = v
            end
        end
        d = applied[]
        if page[] == "Cabinet"
            cabinet = Cabinet(;merge(kw(d.cabinet),(;changes...))...)
            Design(;merge(kw(d),(;cabinet))...)
        elseif page[] == "Listening"
            Design(;merge(kw(d),(;changes...))...)
        else
            drivers = copy(d.drivers)
            drivers[selected[]] = Driver(;merge(kw(drivers[selected[]]),(;changes...))...)
            Design(;merge(kw(d),(;drivers))...)
        end
    end

    function apply_form()
        pending[] = false
        try
            next = parse_form()
            next_result = simulate(next)
            applied[] = next; result[] = next_result
            dirty[] = false
            update_driver_menu(); refresh()
            loading[] = true
            for i in eachindex(SPECS[page[]])
                boxes[i].blockscene.visible[] && (boxes[i].stored_string[] = boxes[i].displayed_string[])
            end
            loading[] = false
            status[] = "Updated. Compare driver curves and their complex sum. Create report to export this design."
            true
        catch err
            loading[] = false
            status[] = "Input error: " * sprint(showerror,err) * " Last valid design is still displayed."
            false
        end
    end

    function install(next;index=selected[])
        next_result = simulate(next)
        applied[] = next; result[] = next_result; selected[] = index
        dirty[] = false; pending[] = false
        update_driver_menu(); fill_form(); refresh()
        nothing
    end

    function add_driver(kind)
        dirty[] && !apply_form() && return
        try
            d=applied[]; c=d.cabinet
            length(d.drivers)<8 || error("Maximum 8 drivers.")
            base = kind==:woofer ? Driver(name="Example woofer $(length(d.drivers)+1)") :
                replace_driver(demo().drivers[2];name="Example tweeter $(length(d.drivers)+1)")
            radius = base.diameter/2000
            found = nothing
            for y in range(radius,c.height-radius;length=45),x in range(radius,c.width-radius;length=9)
                candidate = replace_driver(base;x=x,y=y)
                next = Design(;merge(kw(d),(;drivers=[d.drivers;candidate]))...)
                try
                    validate(next)
                    found = next; break
                catch
                end
            end
            found===nothing && error("No free baffle space. Enlarge the cabinet or move the existing drivers/port first.")
            install(found;index=length(found.drivers))
            status[] = "Example driver added. Enter its datasheet values and crossover."
        catch err
            status[] = sprint(showerror,err)
        end
    end

    function place_at(x,y)
        dirty[] && !apply_form() && return
        try
            d=applied[]; drivers=copy(d.drivers)
            drivers[selected[]] = replace_driver(drivers[selected[]];x=Float64(x),y=Float64(y))
            install(Design(;merge(kw(d),(;drivers))...))
            status[] = "Driver moved. Position affects path length, directivity and interference."
        catch err
            status[] = "Placement: " * sprint(showerror,err)
        end
    end

    on(driver_menu.selection) do next
        loading[] && return
        next===nothing && return
        if dirty[] && !apply_form()
            loading[]=true; driver_menu.i_selected[]=selected[]; loading[]=false
            return
        end
        selected[]=next; fill_form()
    end
    on(page_menu.selection) do next
        loading[] && return
        if dirty[] && !apply_form()
            loading[]=true; page_menu.i_selected[]=findfirst(==(page[]),PAGES); loading[]=false
            return
        end
        page[]=next; fill_form()
    end
    on(_->apply_form(),apply.clicks)
    on(_->refresh(),response_mode.selection)
    on(_->add_driver(:woofer),add_woofer.clicks)
    on(_->add_driver(:tweeter),add_tweeter.clicks)
    on(remove.clicks) do _
        try
            dirty[] && !apply_form() && return
            d=applied[]
            length(d.drivers)>1 || error("Keep at least one driver.")
            drivers = copy(d.drivers); deleteat!(drivers,selected[])
            install(Design(;merge(kw(d),(;drivers))...);index=min(selected[],length(drivers)))
            status[] = "Driver removed."
        catch err
            status[] = sprint(showerror,err)
        end
    end
    on(save_button.clicks) do _
        dirty[] && !apply_form() && return
        try
            path=abspath(expanduser(strip(project_path.displayed_string[])))
            save_design(path,applied[])
            status[] = "Design saved to $path"
        catch err
            status[] = "Save failed: " * sprint(showerror,err)
        end
    end
    on(load_button.clicks) do _
        try
            path=abspath(expanduser(strip(project_path.displayed_string[])))
            install(load_design(path);index=1)
            status[] = "Design loaded from $path"
        catch err
            status[] = "Load failed: " * sprint(showerror,err)
        end
    end
    last_report = Ref("")
    last_room_export = Ref("")
    on(room_export.clicks) do _
        dirty[] && !apply_form() && return
        try
            last_room_export[] = export_room_bundle(applied[])
            status[] = "Room export ready: " * joinpath(last_room_export[],"speaker_room_profile.json")
            println("Room speaker profile: ",joinpath(last_room_export[],"speaker_room_profile.json"))
        catch err
            status[] = "Room export failed: " * sprint(showerror,err)
        end
    end
    on(report.clicks) do _
        dirty[] && !apply_form() && return
        try
            last_report[] = export_report(result[])
            status[] = "Report saved: " * joinpath(last_report[],"report.html")
            println("Report: ",joinpath(last_report[],"report.html"))
        catch err
            status[] = "Report failed: " * sprint(showerror,err)
        end
    end
    on(events(fig).mousebutton;priority=2) do event
        if event.button==Mouse.left && event.action==Mouse.press && is_mouseinside(front.scene)
            x,y=mouseposition(front)
            place_at(x,y)
            return Consume(true)
        end
        Consume(false)
    end
    fill_form(); refresh()
    (;fig,applied,result,status,selected,page,boxes,menus,driver_menu,page_menu,
        dirty,pending,edited_at,live,apply_form,apply,place_at,add_driver,remove,report,
        last_report,project_path,save_button,load_button,response_mode,refresh,room_export,last_room_export)
end

function main()
    app = create_app()
    screen = display(GLMakie.Screen(;title="Speaker Studio"),app.fig)
    updater = @async begin
        while isopen(screen)
            if app.pending[] && app.live.selection[] && time()-app.edited_at[]>0.4
                app.apply_form()
            end
            sleep(0.05)
        end
    end
    if "--smoke-test" in ARGS
        sleep(2)
        app.boxes[1].displayed_string[] = "Test woofer"
        sleep(0.8)
        @assert app.applied[].drivers[1].name == "Test woofer"
        app.boxes[3].displayed_string[] = "invalid"
        app.apply.clicks[] += 1
        @assert occursin("Input error",app.status[])
        app.boxes[3].displayed_string[] = "35"
        app.apply.clicks[] += 1
        app.page_menu.i_selected[] = 4
        app.boxes[2].displayed_string[] = "1800"
        app.apply.clicks[] += 1
        @assert app.applied[].drivers[1].lowpass == 1800
        app.page_menu.i_selected[] = 3
        app.boxes[1].displayed_string[] = "0.36"
        app.apply.clicks[] += 1
        @assert app.applied[].cabinet.width == 0.36
        app.place_at(0.18,0.33)
        @assert app.applied[].drivers[1].x == 0.18
        app.add_driver(:tweeter)
        @assert length(app.applied[].drivers) == 3
        app.remove.clicks[] += 1
        @assert length(app.applied[].drivers) == 2
        app.report.clicks[] += 1
        @assert isfile(joinpath(app.last_report[],"report.html"))
        app.room_export.clicks[] += 1
        @assert isfile(joinpath(app.last_room_export[],"speaker_room_profile.json"))
        app.response_mode.i_selected[] = 2
        app.response_mode.i_selected[] = 1
        app.page_menu.i_selected[] = 1
        save(joinpath(ROOT,"preview.png"),app.fig;px_per_unit=1)
        println("Speaker GUI smoke test passed.")
        close(screen); wait(updater)
        return
    end
    wait(screen); wait(updater)
end
end

if abspath(PROGRAM_FILE)==@__FILE__
    SpeakerStudio.main()
end
