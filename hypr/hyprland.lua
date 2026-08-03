-- ============================================================================
-- HYPRLAND CONFIG (Lua) — CachyOS / AMD RX 9060 XT
-- Translated from hyprland.conf. Hyprland loads hyprland.lua INSTEAD of
-- hyprland.conf when this file exists, so the old .conf is kept as an
-- instant-revert fallback: `rm hyprland.lua` + relog → back on .conf.
--
-- Verified on Hyprland 0.55.4: hl.config/bind/window_rule/env/on/curve/animation
-- and `hyprctl keyword`/`hyprctl dispatch` (old syntax) all work. The scripts
-- that drive live theming/window actions are UNCHANGED — they keep using
-- hyprctl keyword/dispatch, which function under the Lua config manager.
-- ============================================================================

local mainMod     = "SUPER"

-- Scroll direction, in ONE place. Hyprland's `mouse_up` / `mouse_down` bind
-- names follow the PROCESSED scroll axis, so `input:natural_scroll` inverts
-- which name a physical wheel gesture triggers. Verified empirically by
-- injecting a known REL_WHEEL through uinput:
--     natural_scroll = false -> wheel forward = mouse_up
--     natural_scroll = true  -> wheel forward = mouse_down
-- Binding the raw names therefore hard-codes one setting (and one Hyprland
-- version's idea of it — 0.56 flipped what 0.55 did here, which silently
-- reversed the scroll binds). Instead derive the names from the setting below
-- and bind by PHYSICAL gesture, so scroll-up/scroll-down keep meaning the same
-- thing on any mouse and for anyone who prefers natural scrolling: flip this
-- one flag and both the input option and the binds follow it.
local naturalScroll = false
local scrollUp      = naturalScroll and "mouse_down" or "mouse_up"
local scrollDown    = naturalScroll and "mouse_up"   or "mouse_down"
local H           = os.getenv("HOME")
local terminal    = "kitty"   -- default; overridden by terminal.conf just below
local fileManager = H .. "/.config/hypr/dolphin-tc.sh"
local menu        = "wofi --show drun --conf ~/.config/hypr/wofi/config --style ~/.config/hypr/wofi/style.css"

-- Settings → System default-terminal override: terminal.conf holds `$terminal = X`.
-- Read here so the keybinds below pick it up. (Under hyprlang this was a sourced
-- `$terminal`; a Lua local can't be reassigned by a sourced fragment, so we read
-- the file directly. pcall-guarded: a missing/bad file just keeps the default.)
do
    local ok, fh = pcall(io.open, H .. "/.config/hypr/terminal.conf", "r")
    if ok and fh then
        for line in fh:lines() do
            local v = line:match("^%s*%$terminal%s*=%s*(.-)%s*$")
            if v and v ~= "" then terminal = v end
        end
        fh:close()
    end
end

-- ── Startup fragment loader ─────────────────────────────────────────────────
-- The generators (window-geometry.py, wallpaper-colors.py, Settings → Glass, and
-- the gitignored local.conf) still emit hyprlang `.conf` fragments. Under the Lua
-- config we read them HERE at PARSE time and replay each directive as a native
-- hl.* call, so the window rules / border / glass / env exist BEFORE any window
-- opens or app launches (this is what fixes restored windows opening untiled),
-- and they are re-applied on every `hyprctl reload` (which re-runs this file).
-- Each file is pcall-wrapped so a malformed fragment degrades gracefully instead
-- of breaking the whole session. Replaces the old +6s apply-fragments.sh.
local startup_execs = {}

local function coerce(s)
    if s:match("^0[xX]%x+$") then return tonumber(s) end
    if s:match("^[+-]?%d+%.?%d*$") or s:match("^[+-]?%.%d+$") then return tonumber(s) end
    return s
end

-- Convert a hyprlang windowrule body ("<action>, match:K V[, match:K V]") into the
-- STRUCTURED hl.window_rule form. CRITICAL: the raw-string form
-- hl.window_rule({"size 800 600, match:class ^(X)$"}) is silently ACCEPTED (returns
-- ok) but size/move/tile/monitor NEVER apply — only the structured table form works
-- (verified empirically). So geometry/tiling restore depends on this conversion.
local function apply_windowrule(body)
    local parts = {}
    for p in (body .. ","):gmatch("([^,]*),") do
        parts[#parts + 1] = p:gsub("^%s+", ""):gsub("%s+$", "")
    end
    if not parts[1] or parts[1] == "" then return end
    local rule = { match = {} }
    for i = 2, #parts do
        local mk, mv = parts[i]:match("^match:(%S+)%s+(.+)$")
        if mk then rule.match[mk] = mv end
    end
    local verb, rest = parts[1]:match("^(%S+)%s*(.*)$")
    if verb == "float" then rule.float = (rest == "on")
    elseif verb == "tile" then rule.tile = (rest == "on")
    elseif verb == "fullscreen" then rule.fullscreen = (rest == "on")
    elseif verb == "maximize" then rule.maximize = (rest == "on")
    elseif verb == "size" then rule.size = rest
    elseif verb == "move" then rule.move = rest
    elseif verb == "monitor" then rule.monitor = rest
    else hl.window_rule({ body }); return end  -- unknown verb: best-effort raw form
    hl.window_rule(rule)
end

local function load_fragment(path)
    local fh = io.open(path, "r")
    if not fh then return end
    local in_general, in_device = false, false
    for raw in fh:lines() do
        local line = raw:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            if line == "general {" or line == "general{" then
                in_general = true
            elseif line == "device {" or line == "device{" then
                in_device = true
            elseif line == "}" then
                in_general, in_device = false, false
            elseif in_device then
                -- skip (the epic-mouse-v1 template device; no real hardware)
            elseif in_general then
                local k, v = line:match("^(.-)%s*=%s*(.*)$")
                if k and k:find("%.") then
                    local a, b = k:match("^([^.]+)%.(.+)$")
                    hl.config({ general = { [a] = { [b] = v } } })
                elseif k then
                    hl.config({ general = { [k] = v } })
                end
            else
                local k, v = line:match("^(.-)%s*=%s*(.*)$")
                k = k or ""
                if k == "windowrule" then
                    apply_windowrule(v)
                elseif k == "monitor" then
                    local p = {}
                    for seg in (v .. ","):gmatch("([^,]*),") do
                        p[#p + 1] = seg:gsub("^%s+", ""):gsub("%s+$", "")
                    end
                    local t = { output = p[1] }
                    if p[2] and p[2] ~= "" then t.mode = p[2] end
                    if p[3] and p[3] ~= "" then t.position = p[3] end
                    if p[4] and p[4] ~= "" then t.scale = p[4] end
                    hl.monitor(t)
                elseif k == "env" then
                    local n, val = v:match("^([^,]+),(.*)$")
                    if n then hl.env(n, val) end
                elseif k == "exec-once" or k == "exec" then
                    startup_execs[#startup_execs + 1] = v
                elseif k:match("^plugin:") then
                    local chain = {}
                    for seg in k:gmatch("[^:]+") do chain[#chain + 1] = seg end
                    local root = {}
                    local cur = root
                    for i = 1, #chain - 1 do
                        cur[chain[i]] = {}
                        cur = cur[chain[i]]
                    end
                    cur[chain[#chain]] = coerce(v)
                    hl.config(root)
                end
                -- bind*/unbind (keybinds.conf): no clean Lua translator; the file
                -- is normally empty. Skipped (rebinds applied by the Settings app).
            end
        end
    end
    fh:close()
end

local function load_fragment_safe(name)
    pcall(load_fragment, H .. "/.config/hypr/" .. name)
end

-- ── Settings blocks ─────────────────────────────────────────────────────────
hl.config({
    general = {
        gaps_in = 4,
        gaps_out = 6,
        border_size = 2,
        col = {
            active_border = "rgba(ffffffcc)",
            inactive_border = "rgba(00000000)",  -- invisible; only focused shows a border
        },
        resize_on_border = false,
        allow_tearing = false,
        layout = "dwindle",
    },
    render = {
        -- direct scanout: hand fullscreen apps straight to the display (lower
        -- latency for games); off by default in Hyprland.
        direct_scanout = 1,
    },
    decoration = {
        rounding = 10,
        rounding_power = 2,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        shadow = {
            enabled = true,
            range = 4,
            render_power = 3,
            color = "rgba(1a1a1aee)",
            color_inactive = "rgba(00000000)",  -- no shadow on unfocused (dark rim looked like a border)
        },
        blur = {
            -- enabled=false, but size/passes set the render damage-expansion
            -- radius hyprwater needs (size * 2^passes). 40 covers the sampling
            -- reach; lower values caused stacked-glass glitter on focus changes.
            enabled = false,
            size = 40,
            passes = 1,
            vibrancy = 0.1696,
        },
    },
    dwindle = {
        preserve_split = true,
    },
    master = {
        new_status = "master",
    },
    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo = true,
        vrr = 2,
        -- apps can't yank focus (browser link → terminal popup, etc.)
        focus_on_activate = false,
    },
    cursor = {
        no_hardware_cursors = false,  -- HW cursors; the "lost cursor" bug was follow_mouse, not this
        no_warps = true,              -- don't warp pointer on focus changes
    },
    input = {
        kb_layout = "us",
        follow_mouse = 2,             -- pointer focus on hover, keyboard focus only on click
        mouse_refocus = false,
        float_switch_override_focus = 0,
        sensitivity = 0,
        force_no_accel = true,
        -- Set EXPLICITLY (it was previously left at the default): the scroll
        -- binds below are derived from this, so it must never be implicit.
        natural_scroll = naturalScroll,
        touchpad = {
            natural_scroll = naturalScroll,
        },
    },
    animations = {
        enabled = true,
    },
})

-- ── Environment variables ───────────────────────────────────────────────────
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("QT_QPA_PLATFORM", "wayland")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("QT_STYLE_OVERRIDE", "Breeze")
-- cursor theme/size owned by Hyprland (not KDE kcminputrc / nwg-look)
hl.env("XCURSOR_THEME", "Bibata-Modern-Ice")
hl.env("XCURSOR_SIZE", "24")

-- ── Monitors ────────────────────────────────────────────────────────────────
-- Machine-specific `monitor =` lines belong in local.conf (gitignored, read by
-- the fragment loader at every parse — so a `hyprctl reload` re-asserts refresh
-- rates after a DPMS/power-toggle re-detect, and the Settings Update re-copy
-- can never clobber them). This generic line is only the single-screen default.
-- EDIT for your displays (`hyprctl monitors -j` for output names/desc).
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "1.0" })

-- ── Gestures ────────────────────────────────────────────────────────────────
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- ── Animation curves + animations ───────────────────────────────────────────
hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1} } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1} } })
hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1} } })
hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1} } })
hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1} } })
hl.curve("slideOut",       { type = "bezier", points = { {0.25, 1},    {0.3, 1} } })

local A = function(leaf, on, speed, curve, style)
    local t = { leaf = leaf, enabled = on == 1, speed = speed, bezier = curve }
    if style then t.style = style end
    hl.animation(t)
end
A("global",        1, 10,   "default")
A("border",        1, 5.39, "easeOutQuint")
A("windows",       1, 4.79, "easeOutQuint")
A("windowsIn",     1, 4.1,  "easeOutQuint", "popin 87%")
A("windowsOut",    1, 1.49, "linear",       "popin 87%")
A("fadeIn",        1, 1.73, "almostLinear")
A("fadeOut",       1, 1.46, "almostLinear")
A("fade",          1, 3.03, "quick")
A("layers",        1, 3.81, "easeOutQuint")
A("layersIn",      1, 4,    "easeOutQuint", "fade")
A("layersOut",     1, 1.5,  "linear",       "fade")
A("fadeLayersIn",  1, 1.79, "almostLinear")
A("fadeLayersOut", 1, 1.39, "almostLinear")
A("workspaces",    1, 5.82, "slideOut", "slide")
A("workspacesIn",  1, 3.63, "slideOut", "slide")
A("workspacesOut", 1, 5.82, "slideOut", "slide")
A("zoomFactor",    1, 7,    "quick")

-- ── hyprwater plugin config ─────────────────────────────────────────────────
-- liquid glass without frosting: no blur/tint, tone-mapping neutralized, lens kept.
hl.config({
    plugin = {
        hyprwater = {
            blur_strength = 0.2,
            blur_iterations = 1,
            tint_color = 0x00000000,
            fresnel_strength = 0.3,
            specular_strength = 0.3,
            refraction_strength = 1,
            chromatic_aberration = 0.0,
            lens_distortion = 0.1,
            edge_thickness = 0.2,
            -- colon-namespaced keys MUST be nested tables under Lua (the
            -- ["layers:enabled"] string-key form silently fails — confirmed).
            layers = {
                enabled = 1,
                namespaces = "quickshell:pie, wofi, logout_dialog",
                namespace_mask_thresholds = "quickshell:pie=0.03, wofi=0.03, logout_dialog=0.03",
            },
            brightness = 1.0, contrast = 1.0, saturation = 1.0, vibrancy = 1.0,
            vibrancy_darkness = 1.0, adaptive_dim = 1.0, adaptive_boost = 0.0,
            dark = { brightness = 1.0, contrast = 1.0, saturation = 1.0,
                     vibrancy = 1.0, adaptive_dim = 0.08 },
            light = { brightness = 1.0, contrast = 1.0, saturation = 1.0,
                      vibrancy = 1.0, adaptive_boost = 0.8 },
        },
    },
})

-- ── Window rules (static) ───────────────────────────────────────────────────
hl.window_rule({ name = "supmax",   match = { class = ".*" }, suppress_event = "maximize" })
hl.window_rule({ name = "floatall", match = { class = ".*" }, float = true })
hl.window_rule({ name = "nofocus-empty",
                 match = { class = "^$", title = "^$", xwayland = 1, float = 1, fullscreen = 0 },
                 no_focus = true })
hl.window_rule({ name = "hyprland-run-float", match = { class = "^(hyprland-run)$" }, float = true })
hl.window_rule({ name = "hyprland-run-move",  match = { class = "^(hyprland-run)$" }, move = "20 100%-120" })
-- Telegram self-raises on new messages; focus_on_activate=false doesn't catch its
-- explicit activate. `activate` alone suppressed the raise/urgent but NOT the focus
-- steal (rare right->left jump onto Telegram, which lives on special:minimized on the
-- left monitor). `activatefocus` suppresses the focus-on-activate specifically.
hl.window_rule({ name = "tg-noactivate",
                 match = { class = "^(org\\.telegram\\.desktop)$" }, suppress_event = "activate activatefocus" })

-- chromakey glass (Hypr-DarkWindow). Shaders are registered AND the shade window
-- rules are set together, but ONLY when the plugin is loaded. At the initial
-- config parse the plugin isn't loaded yet (it loads in the hyprland.start
-- handler below), so this whole block is skipped then. After the plugin loads,
-- the start handler runs `hyprctl reload`, which re-executes this file with the
-- plugin present: load_shader populates the shader list, then the plugin's
-- config.reloaded handler COMPILES the shaders and re-applies the shade rules to
-- ALL existing windows (RecheckWindowRules). That ordering is the whole fix —
-- previously the shaders were registered (via eval, +6s) but never compiled (no
-- reload fired after), and the shade rules had been evaluated at the one startup
-- reload while the shader list was still empty, so they never bound. Registering
-- here (re-run on every reload) also means chromakey survives a plain reload —
-- e.g. tckey-reload.sh / Settings → Glass — instead of being wiped by it.
if hl.plugin and hl.plugin.darkwindow then
    local dw = hl.plugin.darkwindow
    dw.load_shader("tckey",      { path = H .. "/.config/hypr/technicolor-chromakey.glsl",
                                   args = "sim=0.012 choke=0.65", introduces_transparency = true })
    dw.load_shader("tckeydolph", { path = H .. "/.config/hypr/technicolor-chromakey-dolphin.glsl",
                                   args = "sim=0.012 choke=0.65 keyc=[0.003922 0.729412 0.737255]", introduces_transparency = true })
    dw.load_shader("tckeybrave", { path = H .. "/.config/hypr/technicolor-chromakey-brave.glsl",
                                   args = "sim=0.012 choke=0.65 keyc=[0.003922 0.729412 0.737255] band=44.0", introduces_transparency = true })
    -- The shade EFFECT must be a named key in the structured rule — `["darkwindow:shade"]`
    -- — NOT a raw "darkwindow:shade ..." string. The raw-string form is accepted
    -- silently (returns ok) but never registers the plugin window effect, so the
    -- rule never binds (verified: dispatched shade worked, raw-string rule didn't).
    hl.window_rule({ match = { class = "^([Ss]potify)$" },      ["darkwindow:shade"] = "tckey" })
    hl.window_rule({ match = { class = "^(org.kde.dolphin)$" }, ["darkwindow:shade"] = "tckeydolph" })
    hl.window_rule({ match = { class = "^(brave-browser)$", fullscreen = false }, ["darkwindow:shade"] = "tckeybrave" })
    hl.window_rule({ match = { class = "^(brave-browser)$", fullscreen = true },  ["darkwindow:shade"] = "tckeybrave" })
end

-- GPU screen recorder UI (fullscreen, no decoration)
for _, cls in ipairs({ "^(com.dec05eba.gpu_screen_recorder)$", "^(gsr-ui)$" }) do
    hl.window_rule({ match = { class = cls }, float = true })
    hl.window_rule({ match = { class = cls }, no_anim = true })
    hl.window_rule({ match = { class = cls }, no_blur = true })
    hl.window_rule({ match = { class = cls }, no_shadow = true })
    hl.window_rule({ match = { class = cls }, border_size = 0 })
    hl.window_rule({ match = { class = cls }, size = "100% 100%" })
    hl.window_rule({ match = { class = cls }, center = true })
end

-- Replay the generated fragments (see the loader near the top). These come AFTER
-- the static `floatall` rule above so per-app tile/geometry overrides win.
-- monitors.conf is intentionally skipped — monitors are defined above so every
-- reload re-asserts the high refresh rate.
load_fragment_safe("window-geometry.conf")  -- per-app tiled/floating + geometry
load_fragment_safe("colors.conf")           -- focused-window border = wallpaper accent
load_fragment_safe("hyprwater-tuning.conf") -- Settings → Glass (overrides the defaults above)
load_fragment_safe("local.conf")            -- machine-local: env, headless monitor, game rules, execs
load_fragment_safe("keybinds.conf")         -- conf-era rebinds; no-op under Lua (see bind() below)

-- ── Keybinds ────────────────────────────────────────────────────────────────
local function exec(cmd) return hl.dsp.exec_cmd(cmd) end

-- Under the Lua manager every bind reports dispatcher "__lua" to `hyprctl
-- binds`, so Settings → Hotkeys can no longer guess what a combo does from
-- dispatcher strings. The knowledge lives HERE instead: bind() carries a
-- STABLE id, a category and a label, applies any user override from
-- keybind-overrides.conf (written by Settings → Hotkeys, gitignored), and
-- everything registered through it is exported to keybinds-manifest.json,
-- which is what the Settings list reads. Raw hl.bind() is reserved for
-- plumbing that must never appear in the UI (paired release binds, capture
-- submap internals).
local kbOverrides = {}
do
    local fh = io.open(H .. "/.config/hypr/keybind-overrides.conf", "r")
    if fh then
        for line in fh:lines() do
            local id, combo = line:match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
            if id and combo and combo ~= "" then kbOverrides[id] = combo end
        end
        fh:close()
    end
end

local kbManifest = {}
local function bind(id, cat, label, combo, dispatcher, opts, meta)
    local eff = kbOverrides[id] or combo
    hl.bind(eff, dispatcher, opts)
    -- Editable = a plain keyboard chord. Mouse/scroll chords, locked media
    -- keys and repeating binds keep their hardware keys; meta.editable=false
    -- pins chords that have a paired release bind (the pair would not move
    -- together if only the press half were rebound).
    local editable = not (opts and (opts.mouse or opts.release or opts.locked or opts.repeating))
                     and not eff:find("mouse") and not combo:find("mouse")
    if meta and meta.editable == false then editable = false end
    kbManifest[#kbManifest + 1] = string.format(
        '{"id":"%s","cat":"%s","label":"%s","combo":"%s","def":"%s","editable":%s}',
        id, cat, label, eff, combo, editable and "true" or "false")
end
local function write_kb_manifest()
    local fh = io.open(H .. "/.config/hypr/keybinds-manifest.json", "w")
    if fh then
        fh:write("[\n" .. table.concat(kbManifest, ",\n") .. "\n]\n")
        fh:close()
    end
end

bind("wallpaper-next", "Wallpaper", "Next wallpaper",
     mainMod .. " + W",      exec(H .. "/.config/hypr/wallpaper-cycle.sh next"))
bind("open-terminal", "Apps", "Open terminal",
     mainMod .. " + Q",      exec(terminal))
bind("close-window", "Windows", "Close window",
     mainMod .. " + C",      exec(H .. "/.config/hypr/window-action.sh close"))
bind("close-window-esc", "Windows", "Close window",
     mainMod .. " + ESCAPE", exec(H .. "/.config/hypr/window-action.sh close"))
bind("power-menu", "System", "Logout / power menu",
     mainMod .. " + M",      exec(H .. "/.config/hypr/wlogout-launch.sh"))
bind("sleep-displays", "System", "Sleep the displays",
     mainMod .. " + SHIFT + O", hl.dsp.dpms({ mode = "off" }))  -- blank displays (no DP disconnect)
bind("file-manager", "Apps", "Open file manager",
     mainMod .. " + E",      exec(fileManager))
bind("maximize", "Windows", "Maximize (stays floating)",
     mainMod .. " + V",      exec(H .. "/.config/hypr/window-action.sh maximize"))
bind("app-launcher", "Apps", "App launcher",
     mainMod .. " + R",      exec(menu))
bind("toggle-tiling", "Windows", "Toggle tiling",
     mainMod .. " + SPACE",  exec(H .. "/.config/hypr/window-action.sh float"))

-- Screenshots (note: original used $shiftMod which was undefined → SHIFT)
bind("screenshot-region", "Screenshots", "Screenshot a region",
     "SHIFT + PRINT", exec([[grim -g "$(slurp)" -t ppm - | satty --filename - --output-filename ]] .. H .. [[/Pictures/Screenshots/$(date '+%Y%m%d-%H%M%S').png --copy-command wl-copy]]))
bind("screenshot-full", "Screenshots", "Screenshot full screen",
     mainMod .. " + PRINT", exec([[grim - | satty --filename - --fullscreen --output-filename ]] .. H .. [[/Pictures/Screenshots/$(date '+%Y%m%d-%H%M%S').png --copy-command wl-copy]]))

-- Move focus
bind("focus-left",  "Focus & layout", "Focus window left",  mainMod .. " + left",  hl.dsp.focus({ direction = "l" }))
bind("focus-right", "Focus & layout", "Focus window right", mainMod .. " + right", hl.dsp.focus({ direction = "r" }))
bind("focus-up",    "Focus & layout", "Focus window up",    mainMod .. " + up",    hl.dsp.focus({ direction = "u" }))
bind("focus-down",  "Focus & layout", "Focus window down",  mainMod .. " + down",  hl.dsp.focus({ direction = "d" }))

-- Move window
bind("move-left",  "Focus & layout", "Move window left",  mainMod .. " + SHIFT + left",  hl.dsp.window.move({ direction = "l" }))
bind("move-right", "Focus & layout", "Move window right", mainMod .. " + SHIFT + right", hl.dsp.window.move({ direction = "r" }))
bind("move-up",    "Focus & layout", "Move window up",    mainMod .. " + SHIFT + up",    hl.dsp.window.move({ direction = "u" }))
bind("move-down",  "Focus & layout", "Move window down",  mainMod .. " + SHIFT + down",  hl.dsp.window.move({ direction = "d" }))

-- alt-tab pie (quickshell global). NOT rebindable: the release half below must
-- sit on the same key, and only the press half goes through bind().
bind("window-switcher", "Focus & layout", "Window switcher",
     "ALT + Tab", hl.dsp.global("quickshell:alttab"), nil, { editable = false })
hl.bind("ALT + Tab", hl.dsp.global("quickshell:alttabrelease"), { release = true })
-- SUPER + scroll UP = raise the switcher, SUPER + scroll DOWN = send the
-- hovered window away (minimize). Bound via scrollUp/scrollDown (see the top of
-- this file) so the PHYSICAL gesture is what's fixed, not the axis name.
bind("window-switcher-scroll", "Focus & layout", "Window switcher (scroll)",
     mainMod .. " + " .. scrollUp, hl.dsp.global("quickshell:alttab"))
hl.bind("SUPER_L", hl.dsp.global("quickshell:alttabrelease"), { release = true })
-- minimize the window under the cursor
bind("minimize-under-cursor", "Windows", "Minimize window under cursor",
     mainMod .. " + " .. scrollDown, exec(H .. "/.config/hypr/minimize.sh"))

-- Workspace navigation
bind("workspace-prev", "Workspaces", "Previous workspace",
     mainMod .. " + bracketleft",        exec(H .. "/.config/hypr/workspace-move.sh left"))
bind("workspace-next", "Workspaces", "Next workspace",
     mainMod .. " + bracketright",       exec(H .. "/.config/hypr/workspace-move.sh right"))
bind("workspace-send-prev", "Workspaces", "Send window to previous",
     mainMod .. " + SHIFT + bracketleft",  exec(H .. "/.config/hypr/workspace-move.sh left --move"))
bind("workspace-send-next", "Workspaces", "Send window to next",
     mainMod .. " + SHIFT + bracketright", exec(H .. "/.config/hypr/workspace-move.sh right --move"))

-- Mouse binds
bind("drag-move",   "Focus & layout", "Drag to move window",
     mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
bind("drag-resize", "Focus & layout", "Drag to resize window",
     mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Media keys (locked + repeating)
bind("vol-up",   "Media", "Volume up",   "XF86AudioRaiseVolume", exec(H .. "/.config/hypr/volume.sh up"),   { locked = true, repeating = true })
bind("vol-down", "Media", "Volume down", "XF86AudioLowerVolume", exec(H .. "/.config/hypr/volume.sh down"), { locked = true, repeating = true })
bind("vol-mute", "Media", "Mute audio",  "XF86AudioMute",        exec(H .. "/.config/hypr/volume.sh mute"), { locked = true, repeating = true })
bind("mic-mute", "Media", "Mute microphone", "XF86AudioMicMute", exec("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), { locked = true, repeating = true })
bind("bright-down", "Media", "Brightness down", "XF86MonBrightnessDown", exec("brightnessctl -e4 -n2 set 5%-"), { locked = true, repeating = true })
bind("bright-up",   "Media", "Brightness up",   "XF86MonBrightnessUp",   exec("brightnessctl -e4 -n2 set 5%+"), { locked = true, repeating = true })
bind("media-next", "Media", "Next track",     "XF86AudioNext",  exec("playerctl next"),       { locked = true })
bind("media-pause", "Media", "Play / pause",  "XF86AudioPause", exec("playerctl play-pause"), { locked = true })
bind("media-play",  "Media", "Play / pause",  "XF86AudioPlay",  exec("playerctl play-pause"), { locked = true })
bind("media-prev",  "Media", "Previous track", "XF86AudioPrev", exec("playerctl previous"),   { locked = true })

-- AI background-task kill switch
bind("ai-kill", "System", "Kill AI background tasks",
     "CTRL + ALT + " .. mainMod .. " + A", exec("tmux kill-server"))

-- Machine-local binds (gitignored, like local.conf): local.lua runs with the
-- bind machinery handed in, so binds for personal tooling that does not ship
-- with the dotfiles still show up in Settings → Hotkeys and rebind like the
-- shipped ones. See local.lua.example.
do
    local fn = loadfile(H .. "/.config/hypr/local.lua")
    if fn then
        local ok, err = pcall(fn, { hl = hl, bind = bind, exec = exec, mainMod = mainMod, H = H })
        if not ok then
            pcall(function()
                hl.notification.create({ text = "local.lua error: " .. tostring(err), timeout = 8000 })
            end)
        end
    end
end

-- Everything registered above is now known; hand the list to Settings.
write_kb_manifest()

-- Keybind-rebinding capture submap (Settings → Hotkeys): empty submap so no
-- global binds fire while the app reads a pressed combo. Escape leaves + cancels.
hl.define_submap("__tc_capture", function()
    hl.bind("escape", hl.dsp.submap("reset"))
    hl.bind("escape", exec("qs ipc call settings rebindcancel"), { release = true })
end)

-- ── Startup (exec-once equivalents) ─────────────────────────────────────────
hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
    hl.exec_cmd("systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
    -- machine-local exec/exec-once lines collected from local.conf at parse time
    -- (e.g. `exec-once = sunshine`, `exec = xrandr --output DP-1 --primary`). These
    -- only run at login — the start handler does not fire on `hyprctl reload` — so
    -- there is no duplicate launch. (The Sunshine systemd unit is disabled, so this
    -- is the sole launcher; nothing else starts it under the Lua config.)
    for _, c in ipairs(startup_execs) do hl.exec_cmd(c) end
    hl.exec_cmd("gnome-keyring-daemon --start --components=secrets")
    hl.exec_cmd("/usr/libexec/xdg-desktop-portal-hyprland &")
    hl.exec_cmd("quickshell")
    hl.exec_cmd("mako")
    hl.exec_cmd("nwg-look -a")
    hl.exec_cmd("awww-daemon")
    hl.exec_cmd("sleep 1 && " .. H .. "/.config/hypr/wallpaper-cycle.sh random")
    hl.exec_cmd(H .. "/.config/hypr/wallpaper-timer.sh")
    hl.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.5")
    hl.exec_cmd(H .. "/.config/hypr/carousel-init.sh")
    hl.exec_cmd(H .. "/.config/hypr/workspace-watcher.sh")
    hl.exec_cmd(H .. "/.config/hypr/minimize-watcher.sh")
    hl.exec_cmd(H .. "/.config/hypr/notif-focus-watcher.sh")
    hl.exec_cmd(H .. "/.config/hypr/window-geometry.py")
    hl.exec_cmd(H .. "/.config/hypr/tg-badge-listener.py")
    hl.exec_cmd(H .. "/.config/hypr/gen-wofi-font.sh")
    hl.exec_cmd(H .. "/.config/hypr/technicolor-color-server.py")
    -- Load the vendored plugins (built against system headers by their load.sh;
    -- `hyprctl plugin load` is synchronous, so both are ready when load.sh returns)
    -- then `hyprctl reload`. The reload re-runs THIS config with the plugins now
    -- present: the chromakey block above registers its shaders + shade rules and
    -- the darkwindow plugin (on its config.reloaded handler) compiles them and
    -- applies them to existing windows; hyprwater likewise re-reads its tuning.
    -- This replaces the old `sleep 6 && apply-fragments.sh` — no arbitrary delay,
    -- and correct ordering (shaders compiled in the same reload that binds the
    -- rules), so chromakey works even for windows already open at login.
    hl.exec_cmd("sh -c '\"$HOME/.config/hypr/Hypr-DarkWindow/load.sh\"; \"$HOME/.config/hypr/hyprwater/load.sh\"; sleep 0.5; hyprctl reload'")
end)
