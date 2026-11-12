# Third-party dependencies

Speaker Studio Julia is licensed under the [MIT License](LICENSE). That license
applies to this project's original code and documentation; dependencies retain
their own licenses and copyright notices.

The application installs its external dependencies separately through
[`Project.toml`](Project.toml) using Julia's package manager. Their source code
and binaries are not included in this repository.

| Direct external dependency | Declared compatible versions | Main upstream license |
| --- | --- | --- |
| GLMakie, part of Makie | `0.13.x` | [MIT](https://github.com/MakieOrg/Makie.jl/blob/master/LICENSE.md) |

The application also uses Julia standard libraries. Julia and its bundled
components retain their own licenses; see the
[Julia license](https://github.com/JuliaLang/julia/blob/master/LICENSE.md).

This is a summary of direct dependencies, not a complete inventory of their
transitive dependencies or bundled components. For any release that redistributes
third-party code, binaries, fonts, or other assets, retain the required upstream
notices and review the licenses shipped with the exact versions being distributed.
