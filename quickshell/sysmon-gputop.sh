#!/bin/sh
# Per-process GPU engine time + VRAM via DRM fdinfo (amdgpu, i915, xe — any
# driver implementing the drm-* fdinfo keys). Emits:
#   pgpu PID COMM ENG_NS VRAM_BYTES
# ENG_NS is cumulative GPU-busy nanoseconds summed over the gfx, compute and
# video engines — compute matters: ROCm/Vulkan-compute loads (ollama, ML)
# report NO gfx time at all, only drm-engine-compute. Bar.qml diffs ENG_NS
# across ticks; VRAM is instantaneous. Scanning every fd of every process is
# too heavy for the 1s sysmon tick, so Bar.qml only runs this while the
# GPU/VRAM popup is open. Clients are deduped per PID by drm-client-id (one
# client can appear on several fds).
#
# fdinfo is OWNER-readable only, so a plain user scan is blind to other
# users' processes (root/system services — e.g. an ollama systemd service).
# If the root helper is installed (a root-owned copy of this script at
# /usr/local/bin/technicolor-gputop + a sudoers NOPASSWD rule for
# "technicolor-gputop --local"), use it: same scan, run as root, sees
# everyone. Without it, scan what we can — Bar.qml shows the unattributable
# remainder as "system".
if [ "${1:-}" != "--local" ]; then
    if out=$(sudo -n /usr/local/bin/technicolor-gputop --local 2>/dev/null) \
        && [ -n "$out" ]; then
        printf '%s\n' "$out"
        exit 0
    fi
fi

gawk '
BEGINFILE { cid = ""; g = 0; cm = 0; en = 0; de = 0; vr = 0; if (ERRNO) nextfile }
/^drm-client-id:/      { cid = $2 }
/^drm-engine-gfx:/     { g  = $2 + 0 }
/^drm-engine-compute:/ { cm = $2 + 0 }
/^drm-engine-enc:/     { en = $2 + 0 }
/^drm-engine-dec:/     { de = $2 + 0 }
/^drm-memory-vram:/    { vr = ($2 + 0) * 1024 }
ENDFILE {
  if (cid != "") {
    pid = FILENAME
    gsub(/^.*\/proc\//, "", pid); gsub(/\/fdinfo\/.*$/, "", pid)
    key = pid ":" cid
    if (!(key in seen)) { seen[key] = 1; eA[pid] += g + cm + en + de; vA[pid] += vr }
  }
}
END {
  for (pid in eA) {
    cf = "/proc/" pid "/comm"
    if ((getline comm < cf) <= 0) comm = "-"
    close(cf)
    gsub(/ /, "_", comm); if (comm == "") comm = "-"
    print "pgpu", pid, comm, eA[pid], vA[pid]
  }
}' /proc/[0-9]*/fdinfo/* 2>/dev/null
