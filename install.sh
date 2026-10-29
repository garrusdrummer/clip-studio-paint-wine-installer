#!/usr/bin/env bash
# install.sh - Clip Studio Paint 5 on CachyOS / Arch Linux in a standalone Wine prefix.
#
# What it sets up (see README.md for the reasoning):
#   * a private Wine *staging* runner taken from the distro's signed wine-staging package
#     (CSP needs the WinRT classes RadialController* / StorageFile that only staging registers)
#   * a DirectComposition shim (dcomp.dll) built from source - Wine's dcomp is a stub, which
#     leaves CSP's dialogs and WebView2 panels blank
#   * Microsoft Edge WebView2 runtime, core fonts, Clip Studio Paint itself
#   * a launcher (~/.local/bin/clip-studio-paint) and an app-menu entry
#
# Usage: ./install.sh [--csp-installer FILE] [--skip-deps] [--update-wine]
set -euo pipefail

# ---- settings ---------------------------------------------------------------
CSP_VERSION=${CSP_VERSION:-515}   # 515 = 5.1.5; used to build the download URL
CSP_URL="https://vd.clipstudio.net/clipcontent/paint/app/${CSP_VERSION}/CSP_${CSP_VERSION}w_setup.exe"

WEBVIEW2_URL="https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/79f5276c-391e-481d-9e0f-50d730ae66a9/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
WEBVIEW2_MD5="39d6235aa199e156491d348c3ea02089"

# dcomp shim: upstream source from CSPenguin-Installer + Linux patch from CSP5-for-Wine, pinned
DCOMP_SRC_URL="https://raw.githubusercontent.com/parka6060/CSPenguin-Installer/868d022adfdc3740449241f4721debbf4b1b1426/patches/dcomp"
DCOMP_PATCH_URL="https://raw.githubusercontent.com/taron-sys/CSP5-for-Wine/f08c62c5fb322cdc78fd17dd26de5300b429e590/bundle/files/src/dcomp-csp-linux.patch"
DCOMP_CPP_SHA256="e516fd33b7da2452a90b96a9bbb42920564afd1a91d4ba629cad34acfb0cc83a"
DCOMP_DEF_SHA256="319c1a01d6ca059c5127f62a4a6250ccead3af8ae1f4b335b7c2b1f7fe8b4e92"
DCOMP_PATCH_SHA256="1e7488090f73c3a9195c868d90ee08dedfd2a877e1f96b873fec02e195c574bb"

# pen pressure: Wine's wintab32 reads the tablet via XInput1, which XWayland barely delivers
# (Wine bug 53052). XInput2-based replacement: WinTab.c with the exports CSP 5 needs from
# CSP5-for-Wine, the native XI2 helper from WineTab (both MIT, based on XWinTab), pinned.
WINTAB_DLL_URL="https://raw.githubusercontent.com/taron-sys/CSP5-for-Wine/5334f1414faa46282037adf32e51fa2f56bd2bbe/diag/csp-wintab"
WINTAB_HELPER_URL="https://raw.githubusercontent.com/Sylixa/WineTab/14bc8e4d7ad0c1729f771071ec8c48c35d3a0c7c/build64"
WINTAB_SHA256=(
    "WinTab.c 1aa059cba12611c9a4c02232080e1a689a0c1a23865deb4cc1b22f7a66871ac0"
    "wintab.h f675d846155b7e4f7ead057e70cfcd64da46c2b25d2c0e235448be668ba1e0f9"
    "wintab32.def 386d9838495246206ec6d5b1c1395aeed68f08c9583f5d5b321ea9f19f564821"
    "XWinTabTypes.h 2225f949cb07ae510eb92b58957cac501902756c1b9288b933c8951998f94753"
    "LICENSE c1b91abf430e15612956476c06111fda3dd82c32e397d0fc0aa4f428d4148df2"
    "XWinTabHelper.c 4c58e929b1cf3b6a41f5d642c8750e8d3dd8119dd931732a5a1fe967d88de66a"
    "XWinTabHelper.dll.spec 93c86246964677101d9b507036e446b304cd2ddf2345e73d9cb18be9cae8c623"
)

MIN_WINE_VERSION="11.19"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

BASE=${CSP_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/csp5}
WINE_DIR="$BASE/wine"
PREFIX="$BASE/prefix"
SHIM="$BASE/dcomp.dll"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/csp5-installer"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
LAUNCHER="$BIN_DIR/clip-studio-paint"
CELSYS_DIR="$PREFIX/drive_c/Program Files/CELSYS/CLIP STUDIO 1.5"

EXTRA_PACKAGES=(
    mingw-w64-gcc curl zstd cabextract winetricks icoutils libxcb
    gnutls vulkan-icd-loader libpulse alsa-plugins sdl2
    gst-plugins-base gst-plugins-good wine-gecko wine-mono
)

# ---- helpers ----------------------------------------------------------------
say()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m==> WARNING:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

wine_env() {
    export WINEPREFIX="$PREFIX" WINEARCH=win64 WINEDEBUG=-all
    export WINE="$WINE_DIR/bin/wine" WINESERVER="$WINE_DIR/bin/wineserver"
    # keep Wine from creating its own menu entries (they would point at the wrong wine)
    export WINEDLLOVERRIDES="winemenubuilder.exe=d"
}
wine_run()  { "$WINE_DIR/bin/wine" "$@"; }
wine_wait() { "$WINE_DIR/bin/wineserver" -w; }

# download URL to FILE unless it already exists or ships in installers/ next to this script
fetch() {
    local url=$1 out=$2
    local bundled="$SCRIPT_DIR/installers/${out##*/}"
    if [[ -s $bundled ]]; then
        ln -sfn "$bundled" "$out"
        return 0
    fi
    [[ -s $out ]] && return 0
    say "Downloading ${url##*/}"
    curl -fL --retry 3 -o "$out.part" "$url"
    mv "$out.part" "$out"
}

check_sha256() { echo "$2  $1" | sha256sum -c --quiet - || die "checksum mismatch: $1"; }

# Verify a package against pacman's keyring. pacman-key may need to update the (root-owned)
# trust database first and then fails for normal users; gpgv only needs to read the keyring.
verify_signature() {
    local pkg=$1 home rc
    pacman-key --verify "$pkg.sig" "$pkg" >/dev/null 2>&1 && return 0
    home=$(mktemp -d)
    gpgv --homedir "$home" --keyring /etc/pacman.d/gnupg/pubring.kbx "$pkg.sig" "$pkg" >/dev/null 2>&1
    rc=$?
    rm -rf "$home"
    return $rc
}

# ---- steps ------------------------------------------------------------------
preflight() {
    [[ $EUID -ne 0 ]] || die "run this as your normal user, not root"
    [[ $(uname -m) == x86_64 ]] || die "x86_64 only"
    [[ -f $SCRIPT_DIR/src/csp_popups.cpp ]] || die "src/csp_popups.cpp missing - copy the whole csp5-installer folder"
    command -v pacman >/dev/null || die "pacman not found - this script targets CachyOS / Arch"
    mkdir -p "$BASE" "$CACHE" "$BIN_DIR" "$APPS_DIR" "$ICON_DIR"
}

install_deps() {
    say "Installing dependencies with pacman (sudo)"
    local deps
    # runtime deps of wine-staging (we use its files, not the package itself)
    deps=$(LC_ALL=C pacman -Si wine-staging | awk '
        /^Depends On/ { grab = 1; sub(/^[^:]*: */, ""); print; next }
        grab && /^[[:space:]]/ { print; next }
        grab { exit }' | tr -s ' \t' '\n' | sed 's/[<>=].*//' | grep -vx -e '' -e None)
    # shellcheck disable=SC2086
    sudo pacman -S --needed $deps "${EXTRA_PACKAGES[@]}"
}

check_tools() {
    local t missing=()
    for t in curl zstd tar x86_64-w64-mingw32-g++ patch winetricks cabextract pacman-key gpgv pacman-conf; do
        command -v "$t" >/dev/null || missing+=("$t")
    done
    ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (run without --skip-deps)"
}

# Fetch the current wine-staging package from the configured repos, verify its signature
# and unpack it into $WINE_DIR. The system 'wine' package is left alone.
install_wine() {
    local url file repo pkg server ok=0 version
    url=$(LC_ALL=C pacman -Sp wine-staging 2>/dev/null | head -n1) \
        || die "wine-staging not found in the sync database (try: sudo pacman -Syu)"
    file=${url##*/}
    repo=$(LC_ALL=C pacman -Si wine-staging | awk -F' *: ' '/^Repository/ { print $2; exit }')
    pkg="$CACHE/$file"

    if [[ ! -s $pkg || ! -s $pkg.sig ]]; then
        rm -f "$pkg" "$pkg.sig"
        for server in $(pacman-conf --repo "$repo" Server); do
            if curl -fL --retry 2 -o "$pkg.part" "$server/$file" \
               && curl -fL --retry 2 -o "$pkg.sig" "$server/$file.sig"; then
                mv "$pkg.part" "$pkg"; ok=1; break
            fi
            rm -f "$pkg.part" "$pkg.sig"
        done
        ((ok)) || die "could not download $file from any $repo mirror (is the system up to date? sudo pacman -Syu)"
    fi
    say "Verifying package signature"
    verify_signature "$pkg" || die "signature check failed for $file"

    say "Unpacking $file"
    local tmp="$BASE/wine.new"
    rm -rf "$tmp"; mkdir -p "$tmp/x"
    # include/ is for winegcc, which builds the tablet helper against this exact Wine
    tar --zstd -xf "$pkg" -C "$tmp/x" usr/bin usr/lib/wine usr/share/wine usr/include/wine
    mkdir -p "$tmp/lib"
    mv "$tmp/x/usr/bin" "$tmp/bin"
    mv "$tmp/x/usr/lib/wine" "$tmp/lib/wine"
    mv "$tmp/x/usr/share" "$tmp/share"
    mv "$tmp/x/usr/include" "$tmp/include"
    rm -rf "$tmp/x"
    # Gecko/Mono come from the system packages
    local comp
    for comp in gecko mono; do
        if [[ -d /usr/share/wine/$comp ]]; then ln -sfn "/usr/share/wine/$comp" "$tmp/share/wine/$comp"; fi
    done

    version=$("$tmp/bin/wine" --version) || die "the unpacked wine does not start"
    [[ $version == *Staging* ]] || die "$version is not a staging build"
    version=${version#wine-}; version=${version%% *}
    [[ $(printf '%s\n' "$MIN_WINE_VERSION" "$version" | sort -V | head -n1) == "$MIN_WINE_VERSION" ]] \
        || die "wine-staging $version is too old (need >= $MIN_WINE_VERSION)"

    rm -rf "$WINE_DIR"; mv "$tmp" "$WINE_DIR"
    say "Wine runner: $("$WINE_DIR/bin/wine" --version)"
}

build_shim() {
    local dir="$CACHE/dcomp"
    mkdir -p "$dir"
    fetch "$DCOMP_SRC_URL/dcomp_csp.cpp" "$dir/dcomp_csp.cpp"
    fetch "$DCOMP_SRC_URL/dcomp.def"     "$dir/dcomp.def"
    fetch "$DCOMP_PATCH_URL"             "$dir/dcomp-csp-linux.patch"
    check_sha256 "$dir/dcomp_csp.cpp"         "$DCOMP_CPP_SHA256"
    check_sha256 "$dir/dcomp.def"             "$DCOMP_DEF_SHA256"
    check_sha256 "$dir/dcomp-csp-linux.patch" "$DCOMP_PATCH_SHA256"

    say "Building the DirectComposition shim"
    local build="$dir/build"
    rm -rf "$build"; mkdir -p "$build"
    cp "$dir/dcomp_csp.cpp" "$dir/dcomp.def" "$build/"
    patch -s -p1 -d "$build" dcomp_csp.cpp < "$dir/dcomp-csp-linux.patch"
    # src/csp_popups.cpp (ours): keeps CSP's menu popups out of the window manager
    x86_64-w64-mingw32-g++ -shared -static -O2 -std=c++17 -w \
        -o "$build/dcomp.dll" "$build/dcomp_csp.cpp" "$SCRIPT_DIR/src/csp_popups.cpp" "$build/dcomp.def" \
        -lole32 -lgdi32 -luser32 -ldxgi -ld3d11 -luuid
    install -m644 "$build/dcomp.dll" "$SHIM"
}

# XInput2 Wintab: wintab32.dll (PE, mingw) + XWinTabHelper.dll.so (native, winegcc of our runner)
build_wintab() {
    local dir="$CACHE/wintab" entry name sum url
    mkdir -p "$dir"
    for entry in "${WINTAB_SHA256[@]}"; do
        name=${entry% *}; sum=${entry#* }
        case $name in XWinTabHelper.*) url=$WINTAB_HELPER_URL ;; *) url=$WINTAB_DLL_URL ;; esac
        fetch "$url/$name" "$dir/$name"
        check_sha256 "$dir/$name" "$sum"
    done

    say "Building the XInput2 Wintab (pen pressure)"
    local build="$dir/build"
    rm -rf "$build"; mkdir -p "$build"
    for entry in "${WINTAB_SHA256[@]}"; do cp "$dir/${entry% *}" "$build/"; done
    (cd "$build" &&
        x86_64-w64-mingw32-gcc -shared -O2 -w -o wintab32.dll WinTab.c wintab32.def -luser32 -lgdi32 &&
        "$WINE_DIR/bin/winegcc" -shared -O2 -w -o XWinTabHelper.dll.so XWinTabHelper.c XWinTabHelper.dll.spec \
            -lxcb -lxcb-xinput)
    mkdir -p "$BASE/wintab"
    install -m644 "$build/wintab32.dll" "$build/LICENSE" "$BASE/wintab/"
    install -m755 "$build/XWinTabHelper.dll.so" "$BASE/wintab/"
}

# put the Wintab files next to CLIPStudioPaint.exe and prefer them over Wine's wintab32 there
install_wintab() {
    local paint="$CELSYS_DIR/CLIP STUDIO PAINT"
    [[ -d $paint ]] || return 0
    cp -f "$BASE/wintab/wintab32.dll" "$BASE/wintab/XWinTabHelper.dll.so" "$paint/"
    cp -f "$BASE/wintab/LICENSE" "$paint/LICENSE-XWinTab.txt"
    wine_run reg add 'HKCU\Software\Wine\AppDefaults\CLIPStudioPaint.exe\DllOverrides' \
        /v wintab32 /d native /f >/dev/null
}

# Windows "Documents" (CSP's default save location) -> the Linux home directory instead of ~/Documents
link_documents_to_home() {
    local docs="$PREFIX/drive_c/users/$USER/Documents"
    [[ $(readlink "$docs" 2>/dev/null) == "$HOME" ]] && return 0
    if [[ -L $docs || ! -e $docs ]]; then
        rm -f "$docs"
    elif ! rmdir "$docs" 2>/dev/null; then
        warn "$docs is a non-empty folder, leaving it as it is"
        return 0
    fi
    ln -s "$HOME" "$docs"
}

init_prefix() {
    wine_env
    if [[ ! -f $PREFIX/system.reg ]]; then
        say "Creating Wine prefix in $PREFIX"
        wine_run wineboot -i
        wine_wait
    fi
    say "Configuring prefix"
    wine_run reg add 'HKCU\Software\Wine' /v Version /d win10 /f >/dev/null
    wine_run reg add 'HKCU\Software\Wine\DllOverrides' /v dcomp /d 'native,builtin' /f >/dev/null
    wine_run reg add 'HKCU\Software\Wine\DllOverrides' /v winemenubuilder.exe /d '' /f >/dev/null
    # interface scale: CSP follows the Windows DPI (96 = 100%). Default to the desktop's X11 DPI,
    # which KDE sets from its display scale (e.g. 120 for 125%).
    local dpi=${CSP_DPI:-$(xrdb -query 2>/dev/null | awk '/^Xft.dpi:/ { printf "%d", $2 }')}
    # no desktop to ask (e.g. over SSH): keep whatever scale the prefix already has
    if [[ $dpi =~ ^[0-9]+$ ]]; then
        wine_run reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null
    fi
    wine_wait
    install -m644 "$SHIM" "$PREFIX/drive_c/windows/system32/dcomp.dll"
    link_documents_to_home

    if ! grep -q corefonts "$PREFIX/winetricks.log" 2>/dev/null; then
        say "Installing core fonts (winetricks)"
        winetricks -q corefonts
        wine_wait
    fi
}

install_webview2() {
    wine_env
    if compgen -G "$PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/*/msedgewebview2.exe" >/dev/null; then
        say "WebView2 already installed"
    else
        local exe="$CACHE/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
        fetch "$WEBVIEW2_URL" "$exe"
        echo "$WEBVIEW2_MD5  $exe" | md5sum -c --quiet - || die "WebView2 installer checksum mismatch"
        say "Installing Microsoft Edge WebView2 (takes a few minutes, no window)"
        wine_run "$exe" /silent /install || true
        local i
        for ((i = 0; i < 120; i++)); do
            compgen -G "$PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/*/msedgewebview2.exe" >/dev/null && break
            sleep 5
        done
        # the installer leaves "MicrosoftEdgeUpdate.exe /c" running forever; stop it
        sleep 10
        wine_run taskkill /f /im MicrosoftEdgeUpdate.exe >/dev/null 2>&1 || true
        timeout 60 "$WINE_DIR/bin/wineserver" -w || "$WINE_DIR/bin/wineserver" -k || true
        compgen -G "$PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/*/msedgewebview2.exe" >/dev/null \
            || die "WebView2 installation failed"
    fi
    # Freeze WebView2 at the tested version: stop EdgeUpdate from starting with every launch
    local svc
    for svc in edgeupdate edgeupdatem; do
        wine_run reg add "HKLM\\System\\CurrentControlSet\\Services\\$svc" /v Start /t REG_DWORD /d 4 /f >/dev/null 2>&1 || true
    done
    wine_wait
}

install_csp() {
    wine_env
    if [[ -f "$CELSYS_DIR/CLIP STUDIO PAINT/CLIPStudioPaint.exe" ]]; then
        say "Clip Studio Paint already installed (delete $PREFIX to reinstall from scratch)"
    else
        local exe=${CSP_INSTALLER:-$CACHE/CSP_${CSP_VERSION}w_setup.exe}
        [[ -n ${CSP_INSTALLER:-} ]] || fetch "$CSP_URL" "$exe"
        [[ -f $exe ]] || die "installer not found: $exe"
        say "Starting the Clip Studio Paint installer - click through it with the default install folder."
        say "If it offers to launch CLIP STUDIO PAINT at the end, untick that."
        wine_run "$exe" || true
        wine_wait
        [[ -f "$CELSYS_DIR/CLIP STUDIO PAINT/CLIPStudioPaint.exe" ]] || die "CLIPStudioPaint.exe not found - was the installer completed?"
    fi
    # app-folder copies of the shim take precedence over system32
    local d
    for d in "CLIP STUDIO PAINT" "CLIP STUDIO"; do
        if [[ -d "$CELSYS_DIR/$d" ]]; then install -m644 "$SHIM" "$CELSYS_DIR/$d/dcomp.dll"; fi
    done
    install_wintab
}

install_launcher() {
    say "Creating launcher $LAUNCHER"
    cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Launch Clip Studio Paint (generated by csp5-installer). '--hub' starts CLIP STUDIO instead.
BASE="$BASE"
export WINEPREFIX="\$BASE/prefix" WINEDEBUG=\${WINEDEBUG:--all}
export WINEDLLOVERRIDES="winemenubuilder.exe=d"
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --in-process-gpu --disable-gpu-vsync --no-first-run --disable-sync --disable-extensions --disable-features=msEdgeSidebar"
WINE="\$BASE/wine/bin/wine"
APP="\$WINEPREFIX/drive_c/Program Files/CELSYS/CLIP STUDIO 1.5"

# a prefix update (new runner) may restore Wine's stub dcomp.dll - put the shim back
cmp -s "\$BASE/dcomp.dll" "\$WINEPREFIX/drive_c/windows/system32/dcomp.dll" \\
    || cp "\$BASE/dcomp.dll" "\$WINEPREFIX/drive_c/windows/system32/dcomp.dll"

# ...and may point Documents back at ~/Documents; CSP's Documents is the home directory
DOCS="\$WINEPREFIX/drive_c/users/\$USER/Documents"
if [[ -L \$DOCS && \$(readlink "\$DOCS") != "\$HOME" ]]; then ln -sfn "\$HOME" "\$DOCS"; fi

if [[ \${1:-} == --hub ]]; then
    shift; cd "\$APP/CLIP STUDIO" && exec "\$WINE" CLIPStudio.exe "\$@"
fi

# convert Linux file paths (e.g. from the file manager) to Windows paths
args=()
for a in "\$@"; do
    if [[ -e \$a ]]; then args+=("\$("\$WINE" winepath -w "\$a" 2>/dev/null)"); else args+=("\$a"); fi
done
cd "\$APP/CLIP STUDIO PAINT" && exec "\$WINE" CLIPStudioPaint.exe "\${args[@]}"
EOF
    chmod +x "$LAUNCHER"
    install -m755 "$SCRIPT_DIR/csp-scale.sh" "$BIN_DIR/csp-scale"

    local icon=applications-graphics png
    if command -v wrestool >/dev/null && command -v icotool >/dev/null; then
        local tmp; tmp=$(mktemp -d)
        if wrestool -x -t 14 "$CELSYS_DIR/CLIP STUDIO PAINT/CLIPStudioPaint.exe" > "$tmp/csp.ico" 2>/dev/null \
           && icotool -x -o "$tmp" "$tmp/csp.ico" 2>/dev/null; then
            png=$(ls -S "$tmp"/*.png 2>/dev/null | head -n1)
            if [[ -n $png ]]; then
                install -m644 "$png" "$ICON_DIR/clip-studio-paint.png"
                icon=clip-studio-paint
            fi
        fi
        rm -rf "$tmp"
    fi

    cat > "$APPS_DIR/clip-studio-paint.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CLIP STUDIO PAINT
Comment=Drawing and painting (via Wine)
Exec="$LAUNCHER" %f
Icon=$icon
Categories=Graphics;2DGraphics;RasterGraphics;
StartupWMClass=clipstudiopaint.exe
Actions=Hub;

[Desktop Action Hub]
Name=CLIP STUDIO (hub / materials)
Exec="$LAUNCHER" --hub
EOF
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
}

usage() {
    cat <<EOF
Usage: $0 [options]
  --csp-installer FILE  use a local CSP_xxxw_setup.exe instead of downloading CSP $CSP_VERSION
  --skip-deps           don't call pacman (dependencies already installed)
  --update-wine         only refresh the Wine runner from the current wine-staging package
  -h, --help            this help
Environment: CSP_HOME (install dir, default $BASE), CSP_VERSION (default $CSP_VERSION),
             CSP_DPI (interface scale, 96 = 100%; default: the desktop's Xft.dpi)
EOF
}

main() {
    local skip_deps=0 update_wine=0
    while (($#)); do
        case $1 in
            --csp-installer) CSP_INSTALLER=$(realpath "$2"); shift 2 ;;
            --skip-deps) skip_deps=1; shift ;;
            --update-wine) update_wine=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
    done

    preflight
    ((skip_deps)) || install_deps
    check_tools

    if ((update_wine)); then
        install_wine
        wine_env; wine_run wineboot -u; wine_wait
        install -m644 "$SHIM" "$PREFIX/drive_c/windows/system32/dcomp.dll"
        link_documents_to_home
        build_wintab   # the native helper is built against the Wine it runs in
        install_wintab
        wine_wait
        say "Wine runner updated."
        exit 0
    fi

    install_wine
    build_shim
    build_wintab
    init_prefix
    install_webview2
    install_csp
    install_launcher
    say "Done. Start it from the app menu or run: $LAUNCHER"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
