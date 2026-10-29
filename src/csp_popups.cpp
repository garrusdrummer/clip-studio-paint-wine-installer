// csp_popups.cpp: keep CLIP STUDIO PAINT's menu popups unmanaged under Wine's X11 driver.
//
// CSP pre-creates its menu / context-menu hosts as a chain of owned, layered 1x1 popups and
// resizes + draws into them when a menu opens. Wine's X11 driver turns any popup that gets
// activated (or that owns a managed popup) into a window-manager-managed X11 window, which
// means the compositor picks its position (menus open in the wrong place), lists it in the
// taskbar, and lets the user close it (after which CSP has no menus until restart).
//
// Never letting those hosts activate keeps them override-redirect: exact position, no
// taskbar entry, nothing to close. As a second line of defence close requests are ignored.
//
// CSP drives its menus through activation: a menu closes when it loses activation, and keyboard
// input goes to it as the active window. Since the menus are never really activated now, the
// activation is emulated: whenever CSP tries to activate a menu, that menu becomes the
// "virtually active" one and gets the WM_ACTIVATE/WM_NCACTIVATE messages Windows would send,
// key messages are retargeted to it, closing it hands activation back to its owner menu, and
// a click outside the menus (or switching applications) deactivates it.
//
// Compiled into dcomp.dll, which CLIPStudioPaint.exe imports, so this runs on its UI thread.

#include <windows.h>
#include <cstdarg>
#include <cstdio>
#include <cstring>

static const char POPUP_CLASS_TAG[] = "2D2FC079-EABA-46f4-9B20-A910FB25B322";
static const WCHAR ORIG_PROC_PROP[] = L"csp-popups-orig-proc";
static const WCHAR MENU_HOST_PROP[] = L"csp-popups-menu-host";

static HHOOK g_cbt, g_getmsg, g_mouse, g_callwnd;

/* debug log, enabled with CSP_POPUPS_LOG=1 */
static void plog(const char *fmt, ...)
{
    static int enabled = -1;
    if (enabled < 0) {
        char v[8] = {};
        enabled = GetEnvironmentVariableA("CSP_POPUPS_LOG", v, sizeof(v)) && v[0] == '1';
    }
    if (!enabled) return;
    FILE *f = fopen("C:\\dcomp-csp.log", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    fputs("[popups] ", f);
    vfprintf(f, fmt, ap);
    fputc('\n', f);
    va_end(ap);
    fclose(f);
}

static bool is_class(HWND h, const char *name)
{
    char cls[160] = {};
    return GetClassNameA(h, cls, sizeof(cls)) && !lstrcmpiA(cls, name);
}

static bool is_popup_host(HWND h, DWORD style)
{
    char cls[160] = {};
    if (!(style & WS_POPUP) || !GetClassNameA(h, cls, sizeof(cls))) return false;
    return strstr(cls, POPUP_CLASS_TAG) != nullptr;
}

/* Menu hosts are pre-created at 1x1 during startup and only resized when a menu opens.
   Dialog hosts of the same class (sign-in, news) are created at their real size and need
   activation for keyboard input, so they are left alone. Popups owned by a menu host get
   the same treatment: Wine makes the owner of any managed popup managed as well, so a
   single activated child would drag the whole menu chain into the window manager. */
static bool is_menu_host(HWND h)
{
    return GetPropW(h, MENU_HOST_PROP) != nullptr;
}

/* only CSP's own menu hosts ignore close requests; owned popups may be closed by CSP itself */
static bool is_guarded(HWND h)
{
    return GetPropW(h, MENU_HOST_PROP) == (HANDLE)1;
}

/* a menu CSP shows to the user: popup owned by the menu hosts, at a real size */
static bool is_real_menu(HWND h)
{
    RECT r;
    if (GetPropW(h, MENU_HOST_PROP) != (HANDLE)2 || !IsWindowVisible(h) || !GetWindowRect(h, &r)) return false;
    return r.right - r.left > 1 && r.bottom - r.top > 1;
}

static bool in_menu(HWND h)
{
    HWND root = h ? GetAncestor(h, GA_ROOT) : nullptr;
    return root && GetPropW(root, MENU_HOST_PROP);
}

/* ---- emulated activation ----------------------------------------------------------------
   g_vactive is the menu that would be the active window on Windows. Real activation stays
   with the main window; the menus get the activation messages they would have received. */
static HWND g_vactive;

/* CSP asks GetActiveWindow()/GetFocus() who is active while handling WM_ACTIVATE; on Windows
   that is the newly activated menu, so its own submenu taking over does not close the menu.
   CSP's import table entries for these calls are redirected to report the emulated state. */
static HWND (WINAPI *real_GetActiveWindow)(void);
static HWND (WINAPI *real_GetFocus)(void);
static HWND (WINAPI *real_GetForegroundWindow)(void);
static BOOL (WINAPI *real_SetForegroundWindow)(HWND);

static void virtual_activate(HWND h, const char *why);

static HWND virtual_active()
{
    return g_vactive && IsWindowVisible(g_vactive) ? g_vactive : nullptr;
}

/* Wine records a menu passed to SetForegroundWindow as the foreground window before the
   activation itself (which the CBT hook refuses), and then makes it managed on its next move. */
static BOOL WINAPI fake_SetForegroundWindow(HWND h)
{
    if (h && GetPropW(h, MENU_HOST_PROP)) {
        if (is_real_menu(h)) virtual_activate(h, "SetForegroundWindow");
        return TRUE;
    }
    return real_SetForegroundWindow(h);
}

static HWND WINAPI fake_GetActiveWindow(void)
{
    HWND v = virtual_active();
    return v ? v : real_GetActiveWindow();
}

static HWND WINAPI fake_GetFocus(void)
{
    HWND v = virtual_active();
    return v ? v : real_GetFocus();
}

static HWND WINAPI fake_GetForegroundWindow(void)
{
    HWND fg = real_GetForegroundWindow(), v = virtual_active();
    DWORD pid = 0;
    if (v && fg) GetWindowThreadProcessId(fg, &pid);
    return v && pid == GetCurrentProcessId() ? v : fg;
}

/* replace every import-table slot of the main executable that points at a target function */
static void patch_imports()
{
    struct { void *real; void *fake; } map[] = {
        { (void *)real_GetActiveWindow, (void *)fake_GetActiveWindow },
        { (void *)real_GetFocus, (void *)fake_GetFocus },
        { (void *)real_GetForegroundWindow, (void *)fake_GetForegroundWindow },
        { (void *)real_SetForegroundWindow, (void *)fake_SetForegroundWindow },
    };
    BYTE *base = (BYTE *)GetModuleHandleW(nullptr);
    auto *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    const IMAGE_DATA_DIRECTORY &dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return;
    int patched = 0;
    for (auto *imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress); imp->Name; imp++) {
        for (auto *slot = (void **)(base + imp->FirstThunk); *slot; slot++) {
            for (auto &m : map) {
                if (*slot != m.real) continue;
                DWORD old;
                if (VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old)) {
                    *slot = m.fake;
                    VirtualProtect(slot, sizeof(*slot), old, &old);
                    patched++;
                }
            }
        }
    }
    if (patched) plog("redirected %d import slot(s)", patched);
}

static void send_deactivate(HWND h, HWND new_active)
{
    SendMessageW(h, WM_NCACTIVATE, FALSE, 0);
    SendMessageW(h, WM_ACTIVATE, MAKEWPARAM(WA_INACTIVE, 0), (LPARAM)new_active);
}

static void send_activation(HWND h, HWND prev)
{
    if (prev && IsWindow(prev)) send_deactivate(prev, h);
    SendMessageW(h, WM_NCACTIVATE, TRUE, 0);
    SendMessageW(h, WM_ACTIVATE, MAKEWPARAM(WA_ACTIVE, 0), (LPARAM)prev);
}

static void virtual_activate(HWND h, const char *why)
{
    HWND prev = g_vactive;
    if (h == prev) return;
    g_vactive = h;
    plog("activate %p (was %p) via %s", h, prev, why);
    send_activation(h, prev);
}

/* From inside the CBT hook the messages must not be sent directly: CSP reacts to WM_ACTIVATE
   by activating the menu itself, and hooks are not re-entered on the same thread, so that
   activation would really happen. Record the state now, deliver the messages afterwards. */
static const UINT WM_CSP_VACTIVATE = WM_APP + 0x4351;

static void virtual_activate_deferred(HWND h, const char *why)
{
    HWND prev = g_vactive;
    if (h == prev) return;
    g_vactive = h;
    plog("activate %p (was %p) via %s, deferred", h, prev, why);
    PostMessageW(h, WM_CSP_VACTIVATE, (WPARAM)prev, 0);
}

/* activation leaves the menus entirely (click elsewhere, other application) */
static void virtual_deactivate(HWND new_active, const char *why)
{
    HWND prev = g_vactive;
    if (!prev) return;
    g_vactive = nullptr;
    plog("deactivate %p via %s", prev, why);
    if (IsWindow(prev)) send_deactivate(prev, new_active);
}

/* the active menu was hidden or destroyed: like Windows, hand activation to its owner */
static void virtual_release(HWND h)
{
    if (h != g_vactive) return;
    HWND owner = GetWindow(h, GW_OWNER);
    g_vactive = nullptr;
    if (owner && is_real_menu(owner)) virtual_activate(owner, "owner of closed menu");
    else plog("active menu %p closed", h);
}

static const WCHAR WANTS_ACTIVATE_PROP[] = L"csp-popups-wants-activate";

static LRESULT CALLBACK host_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp)
{
    WNDPROC orig = (WNDPROC)GetPropW(h, ORIG_PROC_PROP);

    switch (msg) {
    case WM_CSP_VACTIVATE:
        if (g_vactive == h) send_activation(h, (HWND)wp); /* unless activation moved on meanwhile */
        return 0;
    case WM_MOUSEACTIVATE:
        if (is_menu_host(h)) {
            LRESULT r = CallWindowProcW(orig, h, msg, wp, lp);
            if ((r == MA_ACTIVATE || r == MA_ACTIVATEANDEAT) && is_real_menu(h)) virtual_activate(h, "click");
            return (r == MA_ACTIVATEANDEAT || r == MA_NOACTIVATEANDEAT) ? MA_NOACTIVATEANDEAT : MA_NOACTIVATE;
        }
        break;
    case WM_WINDOWPOSCHANGING: {
        WINDOWPOS *pos = (WINDOWPOS *)lp;
        LRESULT r = CallWindowProcW(orig, h, msg, wp, lp);
        if (is_menu_host(h) && real_GetActiveWindow() == h) {
            /* safety net: Wine's driver makes the active window managed when it is moved */
            HWND root = GetAncestor(h, GA_ROOTOWNER);
            plog("leak: %p really active, handing activation back to %p", h, root);
            if (root && root != h) SetActiveWindow(root);
        }
        if (is_menu_host(h)) {
            if (!(pos->flags & (SWP_NOACTIVATE | SWP_HIDEWINDOW))) SetPropW(h, WANTS_ACTIVATE_PROP, (HANDLE)1);
            pos->flags |= SWP_NOACTIVATE;
        }
        return r;
    }
    case WM_WINDOWPOSCHANGED: {
        LRESULT r = CallWindowProcW(orig, h, msg, wp, lp);
        if (is_menu_host(h)) {
            bool wanted = RemovePropW(h, WANTS_ACTIVATE_PROP) != nullptr;
            if (((const WINDOWPOS *)lp)->flags & SWP_HIDEWINDOW) virtual_release(h);
            else if (wanted && is_real_menu(h)) virtual_activate(h, "show");
        }
        return r;
    }
    case WM_STYLECHANGING:
        /* keep WS_EX_NOACTIVATE, see the HCBT_CREATEWND handler */
        if (wp == (WPARAM)GWL_EXSTYLE && is_menu_host(h)) ((STYLESTRUCT *)lp)->styleNew |= WS_EX_NOACTIVATE;
        break;
    case WM_CLOSE:
        if (is_guarded(h)) { plog("ignored WM_CLOSE for hwnd=%p", h); return 0; }
        break;
    case WM_SYSCOMMAND:
        if (is_guarded(h) && (wp & 0xfff0) == SC_CLOSE) { plog("ignored SC_CLOSE for hwnd=%p", h); return 0; }
        break;
    case WM_NCDESTROY:
        virtual_release(h);
        SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)orig);
        RemovePropW(h, ORIG_PROC_PROP);
        RemovePropW(h, MENU_HOST_PROP);
        RemovePropW(h, WANTS_ACTIVATE_PROP);
        break;
    }
    return CallWindowProcW(orig, h, msg, wp, lp);
}

static LRESULT CALLBACK getmsg_proc(int code, WPARAM wp, LPARAM lp)
{
    MSG *msg = (MSG *)lp;
    if (code == HC_ACTION && (wp & PM_REMOVE)) {
        if (msg->message >= WM_KEYFIRST && msg->message <= WM_KEYLAST && !in_menu(msg->hwnd)) {
            /* keyboard input belongs to the active window, which would be the menu */
            if (g_vactive && IsWindowVisible(g_vactive)) {
                if (msg->message == WM_KEYDOWN) plog("key %02x -> %p", (unsigned)msg->wParam, g_vactive);
                msg->hwnd = g_vactive;
            }
        } else if (msg->message == WM_MOUSEWHEEL || msg->message == WM_MOUSEHWHEEL) {
            POINT pt = { (short)LOWORD(msg->lParam), (short)HIWORD(msg->lParam) };
            HWND under = WindowFromPoint(pt);
            if (in_menu(under) && !in_menu(msg->hwnd)) msg->hwnd = under;
        }
    }
    return CallNextHookEx(g_getmsg, code, wp, lp);
}

static LRESULT CALLBACK mouse_proc(int code, WPARAM wp, LPARAM lp)
{
    if (code == HC_ACTION) {
        switch (wp) {
        case WM_LBUTTONDOWN: case WM_RBUTTONDOWN: case WM_MBUTTONDOWN: case WM_XBUTTONDOWN:
        case WM_NCLBUTTONDOWN: case WM_NCRBUTTONDOWN: case WM_NCMBUTTONDOWN: case WM_NCXBUTTONDOWN: {
            HWND target = ((MOUSEHOOKSTRUCT *)lp)->hwnd;
            if (!in_menu(target)) virtual_deactivate(GetAncestor(target, GA_ROOT), "click outside");
            break;
        }
        }
    }
    return CallNextHookEx(g_mouse, code, wp, lp);
}

static LRESULT CALLBACK callwnd_proc(int code, WPARAM wp, LPARAM lp)
{
    const CWPSTRUCT *cwp = (CWPSTRUCT *)lp;
    if (code == HC_ACTION && cwp->message == WM_ACTIVATEAPP && !cwp->wParam) virtual_deactivate(nullptr, "app deactivated");
    return CallNextHookEx(g_callwnd, code, wp, lp);
}

static LRESULT CALLBACK cbt_proc(int code, WPARAM wp, LPARAM lp)
{
    if (code == HCBT_CREATEWND) {
        patch_imports(); /* cheap; catches imports the packed executable resolves late */
        HWND h = (HWND)wp;
        const CREATESTRUCTW *cs = ((CBT_CREATEWNDW *)lp)->lpcs;
        bool host = is_popup_host(h, cs->style);
        bool owned_by_menu = (cs->style & WS_POPUP) && cs->hwndParent && is_menu_host(cs->hwndParent);
        if (owned_by_menu && ((cs->style & WS_CAPTION) == WS_CAPTION || (cs->style & WS_THICKFRAME))) {
            /* Dialogs and floating palettes (title bar or resizable frame) hang off the same
               invisible host chain as the menus. They are ordinary windows: let them activate,
               and re-own them to the main window so the window manager stacks them above it
               (as transients of an unmapped host they end up behind it). Making the owner a
               managed window also keeps Wine from turning the hosts into managed windows. */
            HWND root = GetAncestor(cs->hwndParent, GA_ROOTOWNER);
            if (root && root != cs->hwndParent) SetWindowLongPtrW(h, GWLP_HWNDPARENT, (LONG_PTR)root);
            plog("dialog hwnd=%p owner %p -> %p style=%08lx %dx%d", h, cs->hwndParent, root, cs->style, cs->cx, cs->cy);
        } else if (host || owned_by_menu) {
            char cls[160] = {};
            GetClassNameA(h, cls, sizeof(cls));
            SetPropW(h, ORIG_PROC_PROP, (HANDLE)GetWindowLongPtrW(h, GWLP_WNDPROC));
            SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)host_proc);
            if (host && cs->cx <= 1 && cs->cy <= 1) SetPropW(h, MENU_HOST_PROP, (HANDLE)1);
            else if (owned_by_menu) SetPropW(h, MENU_HOST_PROP, (HANDLE)2);
            /* When the compositor focuses one of these X11 windows (e.g. on a click), Wine would
               make it the foreground window, and it becomes managed on its next move. For
               WS_EX_NOACTIVATE windows Wine hands X11 focus back to the previous window instead. */
            if (is_menu_host(h)) SetWindowLongW(h, GWL_EXSTYLE, GetWindowLongW(h, GWL_EXSTYLE) | WS_EX_NOACTIVATE);
            plog("popup hwnd=%p owner=%p style=%08lx ex=%08lx %dx%d menu=%d class=%s", h, cs->hwndParent,
                 cs->style, cs->dwExStyle, cs->cx, cs->cy, (int)(INT_PTR)GetPropW(h, MENU_HOST_PROP), cls);
        } else if (is_class(h, "tooltips_class32")) {
            /* Tooltips are created as overlapped windows (implicit caption) and only made
               WS_POPUP by the control afterwards. Wine's X11 driver decides "managed" from the
               creation-time style, so the window manager would place them (wrong position,
               window decorations). Give them their final popup style before the X window exists. */
            DWORD style = (cs->style & ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU)) | WS_POPUP;
            SetWindowLongW(h, GWL_STYLE, style);
            SetWindowLongW(h, GWL_EXSTYLE, GetWindowLongW(h, GWL_EXSTYLE) | WS_EX_NOACTIVATE);
            plog("tooltip hwnd=%p owner=%p style %08lx -> %08lx", h, cs->hwndParent, cs->style, style);
        } else if (cs->style & WS_POPUP) {
            char cls[160] = {}, ocls[160] = {};
            GetClassNameA(h, cls, sizeof(cls));
            if (cs->hwndParent) GetClassNameA(cs->hwndParent, ocls, sizeof(ocls));
            plog("other popup hwnd=%p owner=%p (%s) style=%08lx ex=%08lx %dx%d class=%s", h, cs->hwndParent, ocls,
                 cs->style, cs->dwExStyle, cs->cx, cs->cy, cls);
        }
    } else if (code == HCBT_ACTIVATE && is_menu_host((HWND)wp)) {
        if (is_real_menu((HWND)wp)) virtual_activate_deferred((HWND)wp, "SetActiveWindow");
        return 1; /* refuse real activation */
    }
    return CallNextHookEx(g_cbt, code, wp, lp);
}

/* Runs during DLL initialisation on the thread that loads dcomp.dll, i.e. CSP's main thread. */
static struct PopupHookInit {
    PopupHookInit()
    {
        char exe[MAX_PATH] = {};
        GetModuleFileNameA(nullptr, exe, sizeof(exe));
        if (!strstr(exe, "CLIPStudioPaint.exe")) return;

        HMODULE self = nullptr;
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)&cbt_proc, &self);
        HMODULE user32 = GetModuleHandleA("user32.dll");
        real_GetActiveWindow = (HWND (WINAPI *)(void))GetProcAddress(user32, "GetActiveWindow");
        real_GetFocus = (HWND (WINAPI *)(void))GetProcAddress(user32, "GetFocus");
        real_GetForegroundWindow = (HWND (WINAPI *)(void))GetProcAddress(user32, "GetForegroundWindow");
        real_SetForegroundWindow = (BOOL (WINAPI *)(HWND))GetProcAddress(user32, "SetForegroundWindow");
        patch_imports();

        DWORD tid = GetCurrentThreadId();
        g_cbt = SetWindowsHookExW(WH_CBT, cbt_proc, self, tid);
        g_getmsg = SetWindowsHookExW(WH_GETMESSAGE, getmsg_proc, self, tid);
        g_mouse = SetWindowsHookExW(WH_MOUSE, mouse_proc, self, tid);
        g_callwnd = SetWindowsHookExW(WH_CALLWNDPROC, callwnd_proc, self, tid);
        plog("hooks on thread %lu: cbt=%p getmsg=%p mouse=%p callwnd=%p", tid, g_cbt, g_getmsg, g_mouse, g_callwnd);
    }
} g_popup_hook_init;
