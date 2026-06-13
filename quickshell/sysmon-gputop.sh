#!/bin/sh
# Per-process GPU engine time + VRAM via DRM fdinfo (amdgpu, i915, xe — any
# driver implementing the drm-* fdinfo keys). Emits:
#   pgpu PID COMM ENG_NS VRAM_BYTES
# ENG_NS is cumulative GPU-busy nanoseconds (Bar.qml diffs across ticks);
# VRAM is instantaneous. Scanning every fd of every process is too heavy for
# the 1s sysmon tick, so Bar.qml only runs this while the GPU/VRAM popup is
# open. Clients are deduped per PID by drm-client-id (one client can appear
# on several fds).
gawk '
BEGINFILE { cid = ""; eng = 0; vram = 0; if (ERRNO) nextfile }
/^drm-client-id:/  { cid = $2 }
/^drm-engine-gfx:/ { eng = $2 + 0 }
/^drm-memory-vram:/ { vram = ($2 + 0) * 1024 }
ENDFILE {
  if (cid != "") {
    pid = FILENAME
    gsub(/^.*\/proc\//, "", pid); gsub(/\/fdinfo\/.*$/, "", pid)
    key = pid ":" cid
    if (!(key in seen)) { seen[key] = 1; e[pid] += eng; v[pid] += vram }
  }
}
END {
  for (pid in e) {
    cf = "/proc/" pid "/comm"
    if ((getline comm < cf) <= 0) comm = "-"
    close(cf)
    gsub(/ /, "_", comm); if (comm == "") comm = "-"
    print "pgpu", pid, comm, e[pid], v[pid]
  }
}' /proc/[0-9]*/fdinfo/* 2>/dev/null
