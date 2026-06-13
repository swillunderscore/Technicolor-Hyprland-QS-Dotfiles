#!/bin/sh
# technicolor dolphin: app-scoped QSS + WA_StyledBackground preload shim
# (see tc-styledbg.cpp). Recompiles the shim if missing or outdated; if the
# build fails, dolphin still launches — only the right panel goes square.
D="$HOME/.config/hypr"
SO="$D/tc-styledbg.so"
SRC="$D/tc-styledbg.cpp"
# Optional KF6 KConfigCore: lets the shim force a live KColorScheme reparse so
# the file view / URL box / header recolor on wallpaper change (no pkg-config
# for KF6, so probe the headers). Absent -> shim still builds, those surfaces
# just stay launch-only.
KF6=""
for inc in /usr/include/KF6/KConfigCore /usr/include/kf6/KConfigCore; do
    if [ -f "$inc/KSharedConfig" ]; then
        base="$(dirname "$inc")"
        # KConfigCore pulls kconfig_version.h from the sibling KConfig dir
        KF6="-DHAVE_KCONFIG -I$base -I$inc -I$base/KConfig -lKF6ConfigCore"
        break
    fi
done
if [ ! -e "$SO" ] || [ "$SRC" -nt "$SO" ]; then
    g++ -shared -fPIC -O2 -o "$SO" "$SRC" $(pkg-config --cflags Qt6Widgets) $KF6 2>/dev/null \
        || g++ -shared -fPIC -O2 -o "$SO" "$SRC" $(pkg-config --cflags Qt6Widgets) 2>/dev/null
fi
# tc-style.so: proxy style that enlarges the tab close button (so the hover disc
# can be big — Breeze caps it via a metric QSS can't override). NOT preloaded —
# the shim dlopen()s it inside Dolphin only, so the QtCore kioworker never sees
# its QtWidgets symbols. Needs to LINK QtWidgets (unlike the preloaded shim).
STYLE_SO="$D/tc-style.so"
STYLE_SRC="$D/tc-style.cpp"
if [ -e "$STYLE_SRC" ] && { [ ! -e "$STYLE_SO" ] || [ "$STYLE_SRC" -nt "$STYLE_SO" ]; }; then
    g++ -shared -fPIC -O2 -o "$STYLE_SO" "$STYLE_SRC" $(pkg-config --cflags --libs Qt6Widgets) 2>/dev/null
fi
[ -e "$SO" ] && export LD_PRELOAD="$SO${LD_PRELOAD:+:$LD_PRELOAD}"
exec dolphin -stylesheet "$HOME/.config/qt6ct/technicolor.qss" "$@"
