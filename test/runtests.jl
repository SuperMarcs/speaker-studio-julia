using Test, LinearAlgebra
include(joinpath(@__DIR__,"..","speaker_model.jl"))
using .SpeakerModel

change(x;args...) = typeof(x)(;merge((;(k=>getfield(x,k) for k in fieldnames(typeof(x)))...),(;args...))...)

@testset "Speaker model" begin
    @testset "Explicit export frequency grid" begin
        d=demo()
        frequencies=[20.0,50.0,200.0,1000.0,20000.0]
        r=simulate(d;frequency_hz=frequencies)
        @test r.frequency==frequencies
        @test size(r.driver)==(5,2)
        @test all(z->isfinite(real(z)) && isfinite(imag(z)),r.total)
        @test_throws ArgumentError simulate(d;frequency_hz=[20.,20.])
        @test_throws ArgumentError simulate(d;frequency_hz=[1.,20000.])
        @test SpeakerModel.json_string("A \"driver\"\nß") == "\"A \\\"driver\\\"\\u000aß\""
    end
    @testset "Geometry and validation" begin
        d=demo(); c=d.cabinet; t=c.thickness/1000
        expected = (c.width-2t)*(c.height-2t)*(c.depth-2t)*1000-
            c.displacement-0.2-π*(c.port_diameter/2000)^2*c.port_length
        @test net_volume(d) ≈ expected
        @test tuning(d) ≈ SpeakerModel.SOUND/(2π)*sqrt(π*(c.port_diameter/2000)^2/
            (expected/1000*(c.port_length/1000+1.46*c.port_diameter/2000)))
        @test_throws ArgumentError simulate(change(d;cabinet=change(c;width=0.1)))
        @test_throws ArgumentError simulate(change(d;drivers=[change(d.drivers[1];qes=0.0)]))
        @test_throws ArgumentError simulate(change(d;drivers=[change(d.drivers[1];fs=NaN)]))
        @test_throws ArgumentError simulate(change(d;drivers=[d.drivers[1],d.drivers[1]]))
        @test_throws ArgumentError simulate(change(d;voltage=-1.0))
        @test_throws ArgumentError simulate(change(d;cabinet=change(c;displacement=500)))
        @test_throws ArgumentError simulate(change(d;drivers=[change(d.drivers[1];hp_slope=18)]))
    end

    @testset "Crossover slopes, phase and polarity" begin
        for slope in (6,12,18,24,48)
            x=Driver(family="Butterworth",lp_slope=slope,lowpass=1000)
            @test abs(crossover(x,1000)) ≈ inv(sqrt(2)) atol=1e-12
            n=slope÷6
            @test abs(crossover(x,2e7)/crossover(x,1e7)) ≈ 2.0^(-n) rtol=1e-6
        end
        for slope in (12,24,48)
            lp=Driver(lp_slope=slope,lowpass=1000,hp_slope=slope)
            hp=change(lp;lowpass=0,highpass=1000)
            @test abs(crossover(lp,1000)) ≈ 0.5 atol=1e-12
            sign = slope==12 ? -1 : 1
            for f in (100,1000,10000)
                @test abs(crossover(lp,f)+sign*crossover(hp,f)) ≈ 1 atol=1e-12
            end
        end
        x=Driver(lowpass=0)
        @test crossover(change(x;polarity=-1),1000) ≈ -crossover(x,1000)
        @test crossover(change(x;delay=0.5),1000) ≈ -crossover(x,1000)
        @test piston(0.0)==1
        @test piston(1.0) ≈ 0.880101171489867 atol=1e-12
        @test piston(20.0) ≈ 0.006683312417585 atol=1e-7
        @test piston(-1.0) ≈ piston(1.0)
    end

    @testset "Independent sealed chamber matches analytical lumped model" begin
        x=Driver(fs=40,qes=0.5,qms=5,vas=40,sd=220,re=6,le=0,chamber=20,lowpass=0,y=0.45)
        d=Design(cabinet=Cabinet(kind="Sealed",baffle_step=false),drivers=[x])
        r=simulate(d;points=200)
        area=x.sd/1e4; cms=(x.vas/1000)/(SpeakerModel.RHO*SpeakerModel.SOUND^2*area^2)
        mms=1/((2π*x.fs)^2*cms); rms=2π*x.fs*mms/x.qms
        bl=sqrt(2π*x.fs*mms*x.re/x.qes)
        for a in (1,50,100,200)
            s=im*2π*r.frequency[a]
            v=bl*d.voltage/x.re/(rms+bl^2/x.re+s*mms+(1+x.vas/x.chamber)/(s*cms))
            @test r.excursion[a,1] ≈ abs(v/s)*sqrt(2)*1000 rtol=1e-12
        end
        twice=simulate(change(d;voltage=2d.voltage);points=200)
        @test twice.total ≈ 2r.total
        @test twice.excursion ≈ 2r.excursion
        near=simulate(change(d;distance=1.0);points=200)
        @test abs.(near.total) ≈ 2abs.(r.total)
    end

    @testset "Shared chamber and port conservation" begin
        c=Cabinet(width=0.6,height=1.0,depth=0.4,port_x=0.3,port_y=0.12,baffle_step=false)
        x=Driver(x=0.15,y=0.4,lowpass=0)
        y=change(x;x=0.45,name="Second")
        d=Design(cabinet=c,drivers=[x,y])
        r=simulate(d;points=200)
        area=x.sd/1e4; cms=x.vas/1000/(SpeakerModel.RHO*SpeakerModel.SOUND^2*area^2)
        mass=1/((2π*x.fs)^2*cms); bl=sqrt(2π*x.fs*mass*x.re/x.qes)
        cb=net_volume(d)/1000/(SpeakerModel.RHO*SpeakerModel.SOUND^2)
        omega=2π*tuning(d); rl=c.loss_q/(omega*cb)
        ap=c.ports*π*(c.port_diameter/2000)^2
        mp=SpeakerModel.RHO*(c.port_length/1000+1.46*c.port_diameter/2000)/ap
        for a in (1,40,80,150)
            s=im*2π*r.frequency[a]; ze=x.re+s*x.le/1000
            zm=2π*x.fs*mass/x.qms+s*mass+1/(s*cms)+bl^2/ze
            zp=omega*mp/c.port_q+s*mp
            zb=1/(s*cb+1/rl+1/zp)
            # Direct dense solve independently checks the shared-pressure reduction.
            A=diagm(fill(zm,2))+zb*fill(area^2,2,2)
            v=A\fill(bl*d.voltage/ze,2)
            @test r.excursion[a,:] ≈ abs.(v./s).*sqrt(2).*1000 rtol=1e-11
            ub=area*sum(v); up=-zb*ub/zp
            @test r.port_speed[a] ≈ abs(up)/ap*sqrt(2) rtol=1e-11
        end
        reversed=simulate(change(d;drivers=[x,change(y;polarity=-1)]);points=200)
        @test maximum(abs,reversed.total) < 1e-9
        @test maximum(abs,reversed.port) < 1e-9
        doubled=simulate(change(d;voltage=2d.voltage);points=200)
        @test doubled.port_speed ≈ 2r.port_speed
        @test r.total ≈ vec(sum(r.driver;dims=2))+r.port
    end

    @testset "Measured data, project round trip and report" begin
        mktempdir() do root
            path=joinpath(root,"flat.frd")
            write(path,"# Hz dB phase\n10 90 0\n100 90 0\n1000 90 0\n20000 90 0\n")
            m=read_frd(path)
            @test abs(SpeakerModel.interpolate(m,250)) ≈ SpeakerModel.PREF*10^(90/20)
            @test isnan(real(SpeakerModel.interpolate(m,5)))
            write(joinpath(root,"bad.frd"),"100 90\n")
            @test_throws ArgumentError read_frd(joinpath(root,"bad.frd"))
            write(joinpath(root,"wrapped.frd"),"100,90,170\n200,90,-170\n")
            @test diff(read_frd(joinpath(root,"wrapped.frd")).phase)[1] ≈ deg2rad(20)
            x=Driver(frd=path,lowpass=0,y=0.45,chamber=1.0)
            d=Design(cabinet=Cabinet(kind="Sealed"),drivers=[x])
            r=simulate(d;points=200)
            @test all(isnan,r.excursion)
            @test all(isapprox.(abs.(r.total),SpeakerModel.PREF*10^(90/20)/2;rtol=1e-10))
            # Measured mode bypasses enclosure/baffle/piston changes.
            modified=simulate(change(d;cabinet=change(d.cabinet;depth=0.4,baffle_step=false));points=200)
            @test modified.total ≈ r.total
            project=joinpath(root,"speaker.toml")
            save_design(project,d)
            loaded=load_design(project)
            @test loaded.drivers[1].frd == path
            @test simulate(loaded;points=200).total ≈ r.total
            dir=export_report(r,root)
            for file in ("report.html","frequency_response.svg","excursion.svg","response.csv","design.toml","driver_1.frd")
                @test isfile(joinpath(dir,file))
            end
            replay=load_design(joinpath(dir,"design.toml"))
            @test simulate(replay;points=200).total ≈ r.total
            @test length(readlines(joinpath(dir,"response.csv")))==201
            @test filesize(joinpath(dir,"report.html"))<250000
            @test occursin("No excursion",read(joinpath(dir,"report.html"),String))
        end
    end
end
