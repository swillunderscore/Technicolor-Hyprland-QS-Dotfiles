#!/bin/bash
# Rebuilds quickshell-git against the installed Qt and relaunches the bar.
#
# Started by quickshell-autofix.service when:
#   - quickshell-launch.sh finds the binary broken at login, or
#   - the quickshell-health timer catches a break mid-session (Qt updates).
#
# No standing root: the package install goes through pkexec, which pops a
# normal GUI password box. Everything else is user-space.
set -u
H="$HOME"
CACHE="$H/.cache/quickshell-autofix"
mkdir -p "$CACHE"
LOG="$CACHE/autofix.log"
exec >>"$LOG" 2>&1
echo "=== $(date) autofix start ==="

notify() { gdbus call --session --dest org.freedesktop.Notifications \
    --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify quickshell-autofix 0 \
    dialog-information "Quickshell" "$1" '[]' '{}' 2000 >/dev/null 2>&1 || true; }

# 0) Healthy? Nothing to do.
if /usr/bin/quickshell --private-check-compat >/dev/null 2>&1; then
    echo "binary healthy, nothing to do"
    exit 0
fi
echo "binary broken, rebuilding"
notify "A Qt update broke the bar — rebuilding it now. It restarts itself when done."

# Repo package? The rebuild path below is for AUR quickshell-git installs.
# On the CachyOS repo package, building -git master over it would fight the
# maintainers — the repo rebuild lands with the next update. Notify and wait.
owner=$(pacman -Qo /usr/bin/quickshell 2>/dev/null | sed 's/.*is owned by //')
if [ "$owner" = "quickshell " ] || [ "${owner%% *}" = "quickshell" ]; then
    echo "repo package ($owner): waiting for the CachyOS rebuild"
    notify "CachyOS hasn't rebuilt quickshell for the new Qt yet. Click Update again shortly — the bar comes back on its own."
    exit 0
fi

# 1) Make sure a polkit GUI agent exists, or the install password box can't
#    appear (if the dead bar was the thing starting it, we'd deadlock).
if ! pgrep -x polkit-gnome-authent >/dev/null 2>&1; then
    setsid /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 \
        >/dev/null 2>&1 &
fi

# 2) Source: persistent AUR package dir.
cd "$CACHE" || exit 1
if [ ! -d quickshell-git ]; then
    git clone -q https://aur.archlinux.org/quickshell-git.git || { notify "Rebuild failed: could not clone AUR package. See $LOG"; exit 1; }
fi
cd quickshell-git || exit 1
git fetch -q origin || true
git reset -q --hard origin/master

# 3) Pin to the installed version's commit — known-good for this bar config.
#    (Upstream master may have QML API churn; don't gamble the config on it.)
commit=$(pacman -Q quickshell-git 2>/dev/null | awk '{print $2}' \
         | sed -nE 's/.*\.g([0-9a-f]{7,}).*/\1/p')
if [ -n "$commit" ] && git -C quickshell cat-file -e "$commit^{commit}" 2>/dev/null; then
    if grep -q '#commit=' PKGBUILD; then
        sed -i "s|#commit=[0-9a-f]*|#commit=$commit|" PKGBUILD
    else
        sed -i "s|git+\$url.git|git+\$url.git#commit=$commit|" PKGBUILD
    fi
    echo "pinned to $commit"
else
    echo "pin $commit unavailable upstream; building master"
fi

# 4) Build.
makepkg -sf --noconfirm || { notify "Rebuild failed (see $LOG). Manual fix: paru -S quickshell-git --rebuild"; exit 1; }
pkg=$(ls -t quickshell-git-*.pkg.tar.* 2>/dev/null | head -1)
[ -n "$pkg" ] || { notify "Rebuild produced no package (see $LOG)."; exit 1; }

# 5) Wait out any pacman transaction still holding the db lock (the update
#    that broke the bar may still be finishing), then install. pkexec pops
#    the GUI password box here.
for i in $(seq 1 60); do [ ! -e /var/lib/pacman/db.lck ] && break; sleep 10; done
pkexec pacman --noconfirm -U "$CACHE/quickshell-git/$pkg" || {
    notify "Bar rebuilt but install needs your password. Run: sudo pacman -U $CACHE/quickshell-git/$pkg"
    exit 1
}

# 6) Verify and bring the bar back (only if nothing is running — a live
#    pre-break instance keeps its mapped symbols until next login).
if /usr/bin/quickshell --private-check-compat >/dev/null 2>&1; then
    if ! pgrep -x quickshell >/dev/null; then
        hyprctl dispatch "hl.dsp.exec_cmd(\"$H/.config/hypr/quickshell-launch.sh\")" >/dev/null 2>&1 || true
    fi
    notify "Bar rebuilt against the new Qt and restarted."
    echo "=== $(date) autofix done ==="
else
    notify "Installed, but the binary still fails its compat check. See $LOG."
    exit 1
fi
