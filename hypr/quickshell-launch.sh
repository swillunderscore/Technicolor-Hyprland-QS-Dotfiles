#!/bin/bash
# Bar launcher with a health gate.
#
# hyprland.lua starts this instead of quickshell directly. If a Qt update
# broke the quickshell binary (private-API ABI break), hand off to
# quickshell-autofix.service — it rebuilds, installs (one polkit password
# box), and re-invokes this script. Healthy binary: just exec the bar.
if /usr/bin/quickshell --private-check-compat >/dev/null 2>&1; then
    exec /usr/bin/quickshell
fi
systemctl --user start quickshell-autofix.service || true
