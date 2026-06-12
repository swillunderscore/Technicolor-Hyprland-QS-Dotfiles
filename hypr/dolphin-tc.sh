#!/bin/sh
# technicolor dolphin: app-scoped QSS + WA_StyledBackground preload shim
# (see tc-styledbg.cpp). Recompiles the shim if missing or outdated; if the
# build fails, dolphin still launches — only the right panel goes square.
D="$HOME/.config/hypr"
SO="$D/tc-styledbg.so"
SRC="$D/tc-styledbg.cpp"
if [ ! -e "$SO" ] || [ "$SRC" -nt "$SO" ]; then
    g++ -shared -fPIC -O2 -o "$SO" "$SRC" $(pkg-config --cflags Qt6Widgets) 2>/dev/null
fi
[ -e "$SO" ] && export LD_PRELOAD="$SO${LD_PRELOAD:+:$LD_PRELOAD}"
exec dolphin -stylesheet "$HOME/.config/qt6ct/technicolor.qss" "$@"
