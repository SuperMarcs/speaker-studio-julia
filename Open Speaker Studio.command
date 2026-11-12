#!/bin/zsh
set -e
cd -- "${0:A:h}"
if command -v julia >/dev/null 2>&1; then
    julia_bin="$(command -v julia)"
elif [[ -x "$HOME/.juliaup/bin/julia" ]]; then
    julia_bin="$HOME/.juliaup/bin/julia"
else
    print "Julia is missing. Install Julia, then reopen this launcher."
    read -r '?Press Return to close.'
    exit 1
fi
if ! "$julia_bin" --startup-file=no --project=. speaker_gui.jl; then
    print "Speaker Studio stopped with an error. See the message above."
    read -r '?Press Return to close.'
    exit 1
fi
