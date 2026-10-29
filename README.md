# Clip Studio Paint 5 on CachyOS (Wine)

`install.sh` sets up CLIP STUDIO PAINT 5.x in its own Wine prefix with an app-menu entry.
The setup it reproduces was tested with CSP 5.1.5 on CachyOS (kernel 7.2, AMD Radeon, Wayland via XWayland).

Copy this folder to the new machine, then:

```sh
cd csp5-installer
./install.sh                 # works from fish too; the script runs in bash
```

The script asks for your sudo password once (for pacman). Microsoft's WebView2 installer runs
silently. The Clip Studio installer is a normal Windows setup wizard: click through it, keep the
default folder, and **untick "launch CLIP STUDIO PAINT"** on the last page.

When it finishes, start **CLIP STUDIO PAINT** from the app menu, or run `clip-studio-paint`.
Right-click the menu entry for *CLIP STUDIO (hub / materials)*.

| Option | Meaning |
|---|---|
| `--csp-installer FILE` | use an already downloaded `CSP_xxxw_setup.exe` (skips the 490 MB download) |
| `--skip-deps` | don't run pacman |
| `--update-wine` | swap in the current `wine-staging` from the repos and update the prefix |
| `CSP_VERSION=520 ./install.sh` | download a different CSP build (number from the official download URL) |
| `CSP_HOME=…` | install somewhere other than `~/.local/share/csp5` |

### Bundled installers

Any file the script would download is taken from `installers/` next to the script if it's there.
`installers/CSP_515w_setup.exe` is included, so CSP isn't downloaded again. You can also drop in
`MicrosoftEdgeWebView2RuntimeInstallerX64.exe` (its MD5 is still checked), or a newer
`CSP_xxxw_setup.exe` together with `CSP_VERSION=xxx`. These installers are Celsys' and Microsoft's
software: keep this folder for your own machines and don't publish it.

`./uninstall.sh` removes everything (`--purge` also clears the download cache in `~/.cache/csp5-installer`).

## Why each piece is needed

| Symptom without it | Fix |
|---|---|
| Gray main window, blank white dialog, invisible windows | Wine's `dcomp.dll` (DirectComposition) is a stub, so CSP's dialogs and WebView2 panels never draw. The script builds a shim from source: [CSPenguin-Installer](https://github.com/parka6060/CSPenguin-Installer) `patches/dcomp` with the patch from [CSP5-for-Wine](https://github.com/taron-sys/CSP5-for-Wine). The sources are pinned and checked with SHA-256. |
| Crash in `triglavwinrt.dll` right after the editor appears | CSP needs the WinRT classes `Windows.UI.Input.RadialController*` and `Windows.Storage.StorageFile`. Only **wine-staging ≥ 11.19** registers them; vanilla Wine and GE-Proton 11 don't. The script unpacks the distro's signed `wine-staging` package into `~/.local/share/csp5/wine`. Your system `wine` package is not touched. |
| Menus open in the wrong place; 4 empty windows in the taskbar, and closing them kills all menus | CSP pre-creates its menu hosts as a chain of owned 1×1 popups. Wine's X11 driver makes such popups *window-manager-managed* as soon as one of them, or a popup they own, is activated. The compositor then positions them itself and lists them in the taskbar. `src/csp_popups.cpp` (ours, compiled into the shim) never lets those hosts or their menus really activate, so Wine keeps them override-redirect, and it ignores close requests sent to the hosts. CSP drives its menus through activation (Esc and arrow keys, closing on an outside click, submenus), so the file emulates it: CSP's imports of `GetActiveWindow`, `GetFocus`, `GetForegroundWindow` and `SetForegroundWindow` work with the "virtually active" menu, keys are routed to it, and it gets the `WM_ACTIVATE` messages Windows would send. |
| Hints (tooltips) appear in the wrong place, looking like small windows | Tooltip windows are created with a caption and only become popups afterwards, but Wine decides "managed" at creation. The same file gives them their popup style before the X11 window exists. |
| No pen pressure (the pen works like a mouse) | Wine's `wintab32` reads tablets through XInput1, which XWayland almost never delivers (Wine bug 53052). The script builds an XInput2-based replacement from source: `WinTab.c` from [CSP5-for-Wine](https://github.com/taron-sys/CSP5-for-Wine), which has the Wintab exports CSP 5 requires, and the native helper `XWinTabHelper.dll.so` from [WineTab](https://github.com/Sylixa/WineTab). Both are MIT and based on XWinTab. They go next to `CLIPStudioPaint.exe` with a `wintab32=native` override for that program only. In CSP, *File → Preferences → Tablet* must use **Wintab**. Tilt tuning: `XWINTAB_ALT_SCALE` (default 9). |
| Web panels and login don't render | Microsoft Edge WebView2 runtime, plus `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox --in-process-gpu …`, set in the launcher. EdgeUpdate is disabled so WebView2 stays on the tested version. |

Generic Wine builds such as Kron4ek's crash on CachyOS's kernel (in `ntdll create_view`). The
distro-built `wine-staging` works, which is why the script uses it.

## GPU

Rendering is hardware-accelerated: Wine's `wined3d` translates CSP's Direct3D 11 calls to
OpenGL/Vulkan on Mesa. Make sure your GPU's Mesa and Vulkan drivers are installed (CachyOS does
this by default).

To debug the menu/tooltip handling, start CSP with `CSP_POPUPS_LOG=1 clip-studio-paint`. It logs to
`C:\dcomp-csp.log` inside the prefix (`~/.local/share/csp5/prefix/drive_c/dcomp-csp.log`). Adding
`WINEDEBUG=+x11drv` and grepping for `requesting override-redirect` shows any window that still ends up
managed by the window manager.

## Known gaps

- Pen pressure and tilt with a graphics tablet have not been tested.
- Timelapse export is a known Wine limitation.
- If the windows go blank again after updating, run the launcher once: it restores the shim in
  `system32`. If CSP crashes at start after `--update-wine`, check that `wine --version` in
  `~/.local/share/csp5/wine/bin` still says *Staging*.

## Interface size

CSP scales its interface with the Windows DPI of the prefix (96 = 100 %, 120 = 125 %, 144 = 150 %,
192 = 200 %). `install.sh` sets it from your desktop's DPI (KDE derives it from the display scale).
To change it later, restart CSP after running, for example:

```sh
WINEPREFIX=~/.local/share/csp5/prefix ~/.local/share/csp5/wine/bin/wine \
    reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 144 /f
```

or reinstall with `CSP_DPI=144 ./install.sh --skip-deps`.

Easier: the installer adds `csp-scale` to `~/.local/bin`. `csp-scale` shows the current scale, and
`csp-scale 150` sets 150 % (100 to 300). Restart CSP afterwards.
