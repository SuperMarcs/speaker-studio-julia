# Speaker Studio — Julia

A separate desktop GUI for multi-driver loudspeaker design: cabinet dimensions, sealed/bass-reflex loading, simple crossover slopes and live response plots. No existing project is changed.

## Start

Install Julia and use a desktop with working OpenGL. From the directory containing your downloaded project, install its dependencies once:

```sh
cd speaker-studio-julia
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Then double-click **Open Speaker Studio.command** in Finder, or run from the project folder:

```sh
julia --startup-file=no --project=. speaker_gui.jl
```

The launcher uses this project's Julia environment. Julia may take some time to compile the GUI on the first launch.

## Workflow

1. The initial two-way speaker uses **illustrative parameters**, not a manufacturer's drivers. Select a driver at the top left, then enter the real values from its datasheet under **Driver data**. **Placement & measurement** holds position, separate chamber and optional FRD inputs.
2. Use **+ Woofer**, **+ Tweeter** or **Remove** to change the driver count (1–8). New drivers are placed in an available part of the baffle. If none fits, enlarge the cabinet or reposition existing drivers/ports first.
3. Select **Cabinet** to change outside width/height/depth, panel thickness, displacement and enclosure type. A bass-reflex enclosure has 1–4 identical straight front ports. The status above the plots shows the calculated net main volume and tuning frequency.
4. Select **Crossover** to enter high-pass/low-pass frequencies and **roll-off slopes**. Enter frequency 0 to bypass a filter. There is no level attenuation control. Polarity and delay are available because they affect how multiple drivers sum.
5. The **Listening** page adjusts RMS voltage, distance and horizontal/vertical angle. Driver positions can be entered numerically or changed by clicking in the front view. Frames and ports must fit and cannot overlap.
6. Valid edits update the plots after a short pause. Select **Manual update** to apply several fields together, then press **Apply / recalculate**. Incomplete or invalid entries keep the last valid result on screen and show an error below it. Correct invalid values before switching pages/drivers or saving.
7. **Save design / Load design** in the top toolbar use the path underneath those buttons. These are TOML project files. Loading explicitly replaces any draft edits.
8. **Create report** exports the applied design to `reports/<timestamp>/`. Open `report.html` in a browser and print to PDF if needed. SVG plots, CSV data and a reproducible `design.toml` accompany it. Any FRD inputs are copied into the report folder.
9. **Export to room** creates a separate bundle under `room_exports/`: the on-axis 1 m graph/report and **speaker_room_profile.json**. Load this JSON into the new `room-acoustics/room_gui_designed_speakers.py` using **Load speaker design…**. The profile carries amplitude and phase; it removes the common 1 m flight time so room distance is applied once. The room treats the entire cabinet as an equivalent omnidirectional point source. See [the room integration guide](../room-acoustics/README_DESIGNED_SPEAKERS.md).

The main plot switches between SPL and phase. The black curve is the **complex pressure sum**, including path length, driver polarity, filter phase and the port. Adding the individual dB curves is not equivalent. The lower plot shows one-way **peak** cone excursion; dashed lines mark entered Xmax. Input voltage is RMS, and excursion/port speed include the RMS-to-peak conversion.

## Driver inputs and chambers

| Input | Meaning |
| --- | --- |
| Fs, Qes, Qms, Vas | Thiele–Small parameters: resonance Hz, electrical/mechanical Q and equivalent compliance volume L. Qts is calculated implicitly from Qes/Qms. |
| Sd | Effective radiating piston area, cm². |
| Re / Le | DC resistance Ω / simple series inductance mH. |
| Xmax | One-way peak excursion limit mm. Used as a comparison line; the linear solver does not clip motion. |
| Frame diameter | Outside driver frame diameter mm, used for physical placement. Directivity uses the effective piston area, not frame size. |
| x / y | Driver center in metres on the front panel, measured from its bottom-left corner. |
| Acoustic depth | Acoustic center behind the front surface, mm; positive increases propagation distance. |
| Own sealed chamber | **0 = shared main enclosure.** A positive value gives this driver its own sealed chamber in litres and reserves that volume inside the cabinet. Each positive value is a separate chamber, even when two values are identical. |
| Voltage drive | On or muted. A muted modelled driver remains a mechanical load in its chamber with its input shorted, so another driver in the main box can still make it move. |

Net main volume is internal rectangular volume minus driver/bracing displacement, all separate chamber volumes, and physical port volume. Enter chamber volume including any space allowance needed for partitions; panel thickness only describes the outside enclosure panels. The displacement field is a manual allowance for drivers and bracing. Cabinet depth is checked against a straight port's physical length; bends and internal clearance constraints are not modelled.

## Crossover

- **Butterworth:** 6, 12, 18, 24 or 48 dB/octave; −3 dB per active filter at its cutoff.
- **Linkwitz–Riley:** 12, 24 or 48 dB/octave; −6 dB per active filter at cutoff. LR12 generally needs a polarity reversal for ideal complementary branches. The complete acoustic result also depends on the drivers and their positions.
- High-pass and low-pass can be used together for a midrange band-pass.
- Each driver has an ideal independent voltage source. These filters represent an active/DSP transfer function. There is no passive resistor/inductor/capacitor network, amplifier current limit, electrical wiring simulator or level attenuation.

## Optional measured response (FRD)

For crossover studies, enter a file path in **Mounted FRD path**. Leave it empty to use the T/S model. A file needs three columns, whitespace- or comma-separated:

```text
# Frequency_Hz  SPL_dB  Phase_degrees
100   82.4   -60.0
200   85.1   -35.0
1000  87.0   -10.0
10000 84.2  -100.0
```

Use real **mounted driver** measurements at **2.83 V RMS / 1 m**, with propagation time removed and consistent phase origins between drivers. Frequencies must increase strictly. Comments begin with `#`, `*` or `;`. Magnitude and unwrapped phase interpolate against log frequency; the program does not invent responses outside the file's range. The total has gaps where any enabled measured driver lacks data. A magnitude-only file is insufficient for reliable crossover summation.

**Measured mode fixes the mounted acoustic response:** cabinet loading, port coupling, baffle step and piston directivity are bypassed for that driver. Only crossover, voltage scaling, polarity, delay and propagation geometry are applied. No cone excursion is inferred from SPL. Angular variation is unknown: changing the listening angle includes geometry/interference but does not synthesize the measured driver's off-axis pattern.

Use T/S mode to compare enclosures; use measured mode to study crossovers for the measured cabinet. Measured drivers do not participate in the simulated shared-pressure coupling. Mixing modes is allowed, but does not reconstruct missing acoustic chamber behaviour. For real full-band design, use measurements taken in the intended enclosure/baffle, including suitable angular measurements in a dedicated design tool.

## Physical model and limits

T/S mode derives a conventional linear electromechanical model:

```text
Cms = Vas / (rho × c² × Sd²)
Mms = 1 / ((2π Fs)² Cms)
Rms = 2π Fs Mms / Qms
Bl² = 2π Fs Mms Re / Qes
Ze = Re + s Le
Zm = Rms + s Mms + 1/(s Cms) + Bl²/Ze
F = Bl × filtered_voltage / Ze
```

In a shared chamber, each cone satisfies `Zm_i v_i + Sd_i p = F_i`, with `p = Zbox Σ Sd_i v_i`. Box compliance is `V/(rho c²)`. A port is a lumped acoustic mass plus resistance, with effective length `physical length + 1.46 × radius` (one flanged and one unflanged end). Port output is `−p/Zport` and is added with its own propagation phase. The enclosure loss Q is a parallel loss referenced to box tuning (or 50 Hz for a sealed box); it is a lumped approximation, not a material absorption coefficient.

Radiation uses half-space point-source propagation and a rigid circular piston directivity factor `2 J1(ka sin θ)/(ka sin θ)`. Optional approximate baffle step is a first-order shelf from −6 dB at low frequency to 0 dB at high frequency, with transition scale `115 / cabinet_width` Hz. This represents a broad trend; it is not an edge diffraction solver. Air density is 1.204 kg/m³ and sound speed 343 m/s.

The simulation does **not** compute cone breakup, detailed diffraction, internal standing waves, enclosure panel vibration, nonlinear distortion, thermal compression, turbulent port noise, passive crossover components or room acoustics. T/S data are primarily useful for low-frequency enclosure behaviour; a smooth modelled treble curve is an estimate. Peak excursion/port-speed plots expose linear demands, not actual behaviour once the driver/port becomes nonlinear. Check actual measurements before making construction decisions.

Background: [REW Thiele–Small documentation](https://www.roomeqwizard.com/help/help_en-GB/html/thielesmall.html), [Linkwitz crossover filters](https://www.linkwitzlab.com/filters.htm), and the [VituixCAD manual](https://kimmosaunisto.net/Software/VituixCAD/VituixCAD_help_30.html).

## Verification

Model and export tests use only Julia standard libraries:

```sh
julia --startup-file=no test/runtests.jl
```

Native GUI smoke test (opens a window briefly and writes `preview.png` plus a report):

```sh
julia --startup-file=no speaker_gui.jl --smoke-test
```
