#!/usr/bin/env bash
# csp-scale - show or change the interface scale of Clip Studio Paint (Wine DPI of its prefix).
# Usage: csp-scale            show the current scale
#        csp-scale 150        set 150 % (any value from 100 to 300)
set -euo pipefail

BASE=${CSP_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/csp5}
export WINEPREFIX="$BASE/prefix" WINEDEBUG=-all
WINE="$BASE/wine/bin/wine"
KEY='HKCU\Control Panel\Desktop'

[[ -x $WINE && -d $WINEPREFIX ]] || { echo "Clip Studio Paint is not installed in $BASE" >&2; exit 1; }

current_dpi() {
    "$WINE" reg query "$KEY" /v LogPixels 2>/dev/null | awk '/LogPixels/ { printf "%d", strtonum($NF) }'
}

if (($# == 0)); then
    dpi=$(current_dpi || true); dpi=${dpi:-96}
    echo "Current scale: $((dpi * 100 / 96)) % (DPI $dpi)"
    echo "Change it with: ${0##*/} <percent>   e.g. ${0##*/} 150"
    exit 0
fi

percent=${1%\%}
if [[ ! $percent =~ ^[0-9]+$ ]] || ((percent < 100 || percent > 300)); then
    echo "Usage: ${0##*/} [percent]   (100 to 300)" >&2
    exit 1
fi

dpi=$((percent * 96 / 100))
"$WINE" reg add "$KEY" /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null
echo "Scale set to $percent % (DPI $dpi)."
if pgrep -f 'CLIPStudioPaint\.exe' >/dev/null; then
    echo "Clip Studio Paint is running: restart it to apply."
fi
