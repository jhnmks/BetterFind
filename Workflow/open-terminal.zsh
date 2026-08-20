#!/bin/zsh

folder="${1-}"
if [[ -z "$folder" || ! -d "$folder" ]]; then
    exit 0
fi

terminal="${terminal_app:-/System/Applications/Utilities/Terminal.app}"
if [[ "$terminal" != *.app || ! -d "$terminal" ]]; then
    terminal="/System/Applications/Utilities/Terminal.app"
fi

/usr/bin/open -a "$terminal" "$folder" >/dev/null 2>&1
exit 0
