#!/bin/bash
# Rebuilds quickshell against the installed Qt and brings the bar back.
#
# quickshell uses Qt's private API, so every Qt update (even a patch release
# like 6.12.0 -> 6.12.1) needs a quickshell rebuilt for it. Distros don't always
# ship that rebuild, so this does it locally.
#
# Started by quickshell-autofix.service when:
#   - quickshell-launch.sh finds the binary broken at login,
#   - quickshell-health.path sees a package update finish (pacman.log closed),
#   - the quickshell-health timer catches a break mid-session.
#
# Repo package (Arch extra, CachyOS, ...): rebuilds the distro's own recipe for
# the INSTALLED version and keeps that version number, so the distro's next
# build of quickshell replaces it normally.
# AUR quickshell-git: rebuilds pinned to the installed commit.
# No standing root: installs go through pkexec (one GUI password box).
#
# Test: QS_AUTOFIX_TEST=1 treats the binary as broken, builds, checks the built
# binary, and stops before installing. Nothing on the system changes.
# QS_AUTOFIX_LOCK overrides the pacman lock path (for testing the wait).
set -u
H="$HOME"
CACHE="$H/.cache/quickshell-autofix"
OUT="$CACHE/out"
LOCK="${QS_AUTOFIX_LOCK:-/var/lib/pacman/db.lck}"
TEST="${QS_AUTOFIX_TEST:-0}"
mkdir -p "$CACHE" "$OUT"
LOG="$CACHE/autofix.log"
[ "$TEST" = 1 ] || exec >>"$LOG" 2>&1
echo "=== $(date) autofix start$([ "$TEST" = 1 ] && echo " (TEST)") ==="

# hyprctl needs the session's instance; a service started at login can miss it.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && [ -d "${XDG_RUNTIME_DIR:-}/hypr" ]; then
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)
    export HYPRLAND_INSTANCE_SIGNATURE
fi

# notify TEXT [sticky] — each call replaces the previous bubble. sticky = stays
# up until replaced (used for "don't reboot yet").
NID=0
notify() {
    echo "notify: $1"
    [ "$TEST" = 1 ] && return 0
    local timeout=10000 urgency=1 out
    [ "${2:-}" = sticky ] && { timeout=0; urgency=2; }
    out=$(gdbus call --session --dest org.freedesktop.Notifications \
        --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.Notify quickshell-autofix "$NID" \
        dialog-information "Quickshell" "$1" '[]' "{'urgency': <byte $urgency>}" \
        "$timeout" 2>/dev/null) || return 0
    NID=$(sed -nE 's/^\(uint32 ([0-9]+),\)$/\1/p' <<<"$out")
    NID=${NID:-0}
}

# A failure notification stays up (it needs action), and is remembered so the
# 5-minute timer doesn't rebuild + nag every 5 minutes while the bar still runs.
fail() {
    notify "$1" sticky
    [ "$TEST" = 1 ] || date +%s > "$CACHE/last-fail"
    exit 1
}

healthy() {
    [ "$TEST" = 1 ] && return 1
    /usr/bin/quickshell --private-check-compat >/dev/null 2>&1
}

# Wait out a running pacman transaction (up to 15 min).
wait_unlock() {
    local i
    for i in $(seq 1 180); do [ -e "$LOCK" ] || return 0; sleep 5; done
    return 1
}

# Does a built package's binary pass the compat check against the installed Qt?
pkg_ok() {
    local t r
    t=$(mktemp -d)
    bsdtar -xf "$1" -C "$t" usr/bin/quickshell 2>/dev/null &&
        "$t/usr/bin/quickshell" --private-check-compat >/dev/null 2>&1
    r=$?
    rm -rf "$t"
    return $r
}

# Install anything the recipe needs that's missing (one password box).
install_deps() {
    local missing
    missing=$(cd "$1" && makepkg --printsrcinfo 2>/dev/null |
        sed -nE 's/^\t(make)?depends = //p' | xargs -r pacman -T | sed 's/[<>=].*//')
    [ -z "$missing" ] && return 0
    echo "missing build deps: $missing"
    [ "$TEST" = 1 ] && return 1
    # shellcheck disable=SC2086
    pkexec pacman -S --needed --asdeps --noconfirm $missing
}

# Repo package: the distro's own recipe at the installed version.
build_distro() {
    local ver=$1 pkgver pkgrel tag dir pkg
    pkgver=${ver%-*}; pkgver=${pkgver#*:}
    pkgrel=${ver##*-}
    tag="${ver%-*}-${pkgrel%%.*}"; tag=${tag/:/-}   # CachyOS 1.1 -> Arch tag -1
    dir="$CACHE/distro-quickshell"
    if [ ! -d "$dir/.git" ]; then
        rm -rf "$dir"
        git clone -q https://gitlab.archlinux.org/archlinux/packaging/packages/quickshell.git "$dir" ||
            { FAIL="could not download the build recipe (no network?)"; return 1; }
    fi
    git -C "$dir" fetch -q --tags origin || true
    git -C "$dir" checkout -q -f "refs/tags/$tag" 2>/dev/null ||
        { FAIL="no build recipe for quickshell $ver (tag $tag)"; return 1; }
    git -C "$dir" clean -q -fdx
    grep -q "^pkgver=$pkgver\$" "$dir/PKGBUILD" ||
        { FAIL="recipe tag $tag is not version $pkgver"; return 1; }
    sed -i -E "s/^pkgrel=.*/pkgrel=$pkgrel/" "$dir/PKGBUILD"
    install_deps "$dir" || { FAIL="build dependencies are missing"; return 1; }
    rm -f "$OUT"/quickshell-[0-9]*.pkg.tar.*
    (cd "$dir" && PKGDEST="$OUT" makepkg -Cf --noconfirm) ||
        { FAIL="the build failed"; return 1; }
    pkg=$(ls -t "$OUT"/quickshell-[0-9]*.pkg.tar.* 2>/dev/null | grep -v -e '-debug-' -e '\.sig$' | head -1)
    [ -n "$pkg" ] || { FAIL="the build produced no package"; return 1; }
    PKG=$pkg
}

# AUR quickshell-git: pinned to the installed commit (upstream master may have
# QML API changes; don't gamble the config on it).
build_aur_git() {
    local dir="$CACHE/quickshell-git" commit pkg
    if [ ! -d "$dir/.git" ]; then
        rm -rf "$dir"
        git clone -q https://aur.archlinux.org/quickshell-git.git "$dir" ||
            { FAIL="could not download the AUR package (no network?)"; return 1; }
    fi
    git -C "$dir" fetch -q origin || true
    git -C "$dir" reset -q --hard origin/master
    commit=$(pacman -Q quickshell-git 2>/dev/null | awk '{print $2}' |
        sed -nE 's/.*\.g([0-9a-f]{7,}).*/\1/p')
    if [ -n "$commit" ]; then
        if grep -q '#commit=' "$dir/PKGBUILD"; then
            sed -i "s|#commit=[0-9a-f]*|#commit=$commit|" "$dir/PKGBUILD"
        else
            sed -i "s|git+\$url.git|git+\$url.git#commit=$commit|" "$dir/PKGBUILD"
        fi
        echo "pinned to $commit"
    fi
    install_deps "$dir" || { FAIL="build dependencies are missing"; return 1; }
    rm -f "$OUT"/quickshell-git-*.pkg.tar.*
    (cd "$dir" && PKGDEST="$OUT" makepkg -f --noconfirm) ||
        { FAIL="the build failed"; return 1; }
    pkg=$(ls -t "$OUT"/quickshell-git-*.pkg.tar.* 2>/dev/null | grep -v -e '-debug-' -e '\.sig$' | head -1)
    [ -n "$pkg" ] || { FAIL="the build produced no package"; return 1; }
    PKG=$pkg
}

# Start the bar through Hyprland (clean session env), only if none is running:
# a live pre-update bar keeps its already-loaded Qt until the next login.
relaunch() {
    local i
    pgrep -x quickshell >/dev/null && return 0
    if [ -x "$H/.config/hypr/restart-quickshell.sh" ]; then
        "$H/.config/hypr/restart-quickshell.sh"
    else
        hyprctl eval "hl.exec_cmd(\"$H/.config/hypr/quickshell-launch.sh\")" >/dev/null 2>&1
    fi
    for i in $(seq 1 50); do pgrep -x quickshell >/dev/null && return 0; sleep 0.2; done
    return 1
}

# 0) The same update may have brought the distro's own rebuild: let pacman
#    finish, then check again.
wait_unlock || fail "The bar's Qt check is failing, but a package update has been running for 15+ minutes. Finish it, then log out and back in."
if healthy; then
    echo "binary healthy, nothing to do"
    exit 0
fi

owner=$(pacman -Qqo /usr/bin/quickshell 2>/dev/null)
ver=$(pacman -Q "$owner" 2>/dev/null | awk '{print $2}')
echo "installed: $owner $ver"
# Not pacman-managed (Fedora COPR, a source build, ...): can't rebuild it here.
[ -n "$owner" ] || fail "Qt was updated but quickshell wasn't rebuilt for it. Reinstall or rebuild quickshell with your package manager, then log out and back in."

bar_running=0
pgrep -x quickshell >/dev/null && bar_running=1
# Bar still up and the last try failed < 30 min ago: don't nag again yet.
# Bar down: always try, that's the point.
if [ $bar_running = 1 ] && [ "$TEST" != 1 ] && [ -f "$CACHE/last-fail" ] &&
   [ $(( $(date +%s) - $(cat "$CACHE/last-fail" 2>/dev/null || echo 0) )) -lt 1800 ]; then
    echo "last try failed < 30 min ago and the bar is still running: not retrying yet"
    exit 0
fi
if [ $bar_running = 1 ]; then
    notify "Qt was updated, so the bar needs rebuilding. Rebuilding now (about 2 minutes), then a password box asks to install it. Don't reboot until this says done." sticky
else
    notify "A Qt update broke the bar. Rebuilding it now (about 2 minutes), then a password box asks to install it and the bar comes back." sticky
fi

# 1) The password box needs a polkit agent. If the dead bar was what started
#    it, nothing else will.
if [ "$TEST" != 1 ] && ! pgrep -f polkit-gnome-authentication-agent >/dev/null 2>&1; then
    setsid /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 >/dev/null 2>&1 &
fi

# 2) Build.
FAIL="" PKG=""
case "$owner" in
    quickshell)     build_distro "$ver" ;;
    quickshell-git) build_aur_git ;;
    *)  FAIL="quickshell comes from '$owner', which this can't rebuild" ;;
esac
[ -n "$PKG" ] || fail "Couldn't rebuild the bar: ${FAIL:-unknown error}. Log: $LOG"
echo "built $PKG"
pkg_ok "$PKG" || fail "Rebuilt the bar, but the new build still fails its Qt check. Log: $LOG"
echo "built package passes the compat check"
if [ "$TEST" = 1 ]; then
    echo "TEST: stopping before install"
    exit 0
fi

# 3) Install (password box).
wait_unlock
pkexec pacman --noconfirm -U "$PKG" ||
    fail "The bar is rebuilt but not installed (password box closed?). Run: sudo pacman -U $PKG"
healthy || fail "Installed the rebuilt bar, but it still fails its Qt check. Log: $LOG"
rm -f "$CACHE/last-fail"

# 4) Done.
if [ $bar_running = 1 ]; then
    notify "Bar rebuilt for the new Qt. Safe to reboot."
elif relaunch; then
    notify "Bar rebuilt for the new Qt and back on screen."
else
    fail "Bar rebuilt, but it didn't start. Log out and back in."
fi
echo "=== $(date) autofix done ==="
