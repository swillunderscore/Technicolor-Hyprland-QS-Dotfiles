#!/bin/sh
# Single-shot system stats dump for the Quickshell bar.
# Prints "key value..." lines, consumed once per tick by Bar.qml's fastStatProc.
# Cheap: only reads /proc and /sys, spawns no subprocesses beyond awk.

# CPU aggregate jiffies: user nice system idle iowait irq softirq
read -r _ u n s i io irq sirq _ < /proc/stat
echo "cpu $u $n $s $i $io $irq $sirq"

# Per-core jiffies: "core IDX BUSY TOTAL" (cumulative; Bar.qml diffs per tick)
awk '/^cpu[0-9]+ /{c=substr($1,4); b=$2+$3+$4+$7+$8+$9; print "core", c, b, b+$5+$6}' /proc/stat

# Every DRM card exposing gpu_busy_percent (card numbers are not stable
# across machines — never hardcode card0/card1). The first card also emits
# the legacy aggregate "gpu"/"vram" lines (bar ring + single-GPU popups);
# every card emits indexed "gpux IDX BUSY" / "vramx IDX USED TOTAL" lines so
# the popups can graph each GPU separately on multi-GPU machines.
gi=0
for d in /sys/class/drm/card*/device; do
    [ -e "$d/gpu_busy_percent" ] || continue
    busy=$(cat "$d/gpu_busy_percent" 2>/dev/null || echo 0)
    vu=$(cat "$d/mem_info_vram_used" 2>/dev/null || echo 0)
    vt=$(cat "$d/mem_info_vram_total" 2>/dev/null || echo 1)
    if [ "$gi" = 0 ]; then
        echo "gpu $busy"
        echo "vram $vu $vt"
    fi
    echo "gpux $gi $busy"
    echo "vramx $gi $vu $vt"
    gi=$((gi+1))
done

if [ "$gi" = 0 ]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
        # Nvidia proprietary/open module: no busy/vram/temp sysfs — one
        # nvidia-smi call covers usage, VRAM and temperature for every GPU
        # (Bar.qml prefers a "gputemp" line over its hwmon scan). timeout
        # guards a sleeping driver.
        timeout 1 nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
            --format=csv,noheader,nounits 2>/dev/null |
        awk -F', *' '{ if (NR == 1) { print "gpu " $1+0
                                      print "vram " $2*1048576 " " (($3+0) > 0 ? $3*1048576 : 1)
                                      print "gputemp " $4+0 }
                       print "gpux " NR-1 " " $1+0
                       print "vramx " NR-1 " " $2*1048576 " " (($3+0) > 0 ? $3*1048576 : 1) }'
    else
        # unknown GPU: graceful zeros (widget shows 0%, nothing breaks)
        echo "gpu 0"
        echo "vram 0 1"
    fi
fi

# Memory, in kB: MemTotal MemAvailable
# + "memx SHMEM GPU" (kB): tmpfs/shm pages in RAM, and the GPU driver's
# system-RAM pages (GPUActive/GPUReclaim; 0 on kernels without them). Neither
# belongs to any process, so the popup shows them as their own rows.
awk '/^MemTotal:/{mt=$2} /^MemAvailable:/{ma=$2} /^Shmem:/{sh=$2}
     /^GPUActive:/{ga=$2} /^GPUReclaim:/{gr=$2}
     END{print "mem " mt " " ma; print "memx " sh+0 " " ga+gr}' /proc/meminfo

# zram's compressed store lives in RAM but in no process: "zrammem BYTES"
# (mm_stat field 3 = mem_used_total, summed over zram devices).
cat /sys/block/zram*/mm_stat 2>/dev/null | awk '{z+=$3} END{print "zrammem " z+0}'

# Swap (covers zram + disk swap): Used / Size summed across all swap devices
awk 'NR>1 {sz+=$3; us+=$4} END{print "swap " us+0 " " sz+0}' /proc/swaps

# Network: cumulative rx/tx bytes summed over real interfaces (skip lo, virtual)
awk -F'[: ]+' '/^[ ]*(en|eth|wl|wlp|enp|eno|ens)/{rx+=$3; tx+=$11} END{print "net " rx+0 " " tx+0}' /proc/net/dev

# Disk I/O: cumulative sectors (512B) read/written over whole-disk devices
awk '$3 ~ /^(sd[a-z]|nvme[0-9]+n[0-9]+|mmcblk[0-9]+|vd[a-z])$/ {r+=$6; w+=$10} END{print "disk " r+0 " " w+0}' /proc/diskstats

# One line per swap device, so the SWAP popup can say where swapped data
# actually sits: "swapdev KIND USEDKB SIZEKB RAMBYTES PRIO". KIND = zram (lives in
# RAM, compressed — RAMBYTES is the real RAM it takes, mm_stat field 3),
# file (swapfile on disk) or partition (on disk). Disk kinds take no RAM.
# PRIO = swap priority: Linux fills the highest first (the popup's order).
awk 'NR > 1 {
  kind = ($2 == "file") ? "file" : "partition"; ram = 0
  if ($1 ~ /^\/dev\/zram[0-9]+$/) {
    kind = "zram"; dev = substr($1, 6)
    f = "/sys/block/" dev "/mm_stat"
    if ((getline line < f) > 0) { split(line, m, " "); ram = m[3] + 0 }
    close(f)
  }
  print "swapdev", kind, $4 + 0, $3 + 0, ram, $5 + 0
}' /proc/swaps

# Per-process CPU + memory: "pcs PID COMM JIFFIES RSSBYTES" — single pass over
# /proc/*/stat (comm may contain spaces/parens: parse around the closing ')').
# Filtered to processes with any CPU time or >4MB resident to keep line count sane.
gawk -v ps="$(getconf PAGESIZE)" '
{
  if (match($0, /\(.*\)/) == 0) next
  pid = FILENAME; gsub(/^.*\/proc\/|\/stat$/, "", pid)
  comm = substr($0, RSTART + 1, RLENGTH - 2)
  gsub(/ /, "_", comm); if (comm == "") comm = "-"
  split(substr($0, RSTART + RLENGTH + 1), f, " ")
  j = f[12] + f[13]            # utime + stime (fields 14+15 of stat)
  if (j > 0 || f[22] + 0 > 1024)
    print "pcs", pid, comm, j, f[22] * ps   # f[22] = rss pages (field 24)
}' /proc/[0-9]*/stat 2>/dev/null

# Per-process swap + RAM, one pass over /proc/*/status:
#   "psw PID COMM KB"        swapped out (zram or disk swap alike; nonzero only)
#   "pmem PID COMM KB SHMKB" RAM the process holds that counts toward "used"
#                            (MemTotal - MemAvailable): RssAnon + RssShmem +
#                            locked file pages. Plain RssFile is page cache the
#                            kernel counts as available, so it's left out —
#                            otherwise the rows add up to MORE than "used".
#                            Only >= 1 MB, to keep the line count sane.
#   "pmemtot KB SHMKB"       the same, summed over EVERY process, so the
#                            popup's "other apps" row covers the small ones.
# Kernel threads have no Vm*/Rss* lines and never reach VmSwap.
gawk '
FNR == 1  { comm = "-"; anon = 0; file = 0; shm = 0; lck = 0 }
/^Name:/  { comm = $0; sub(/^Name:[ \t]*/, "", comm); gsub(/ /, "_", comm); if (comm == "") comm = "-" }
/^VmLck:/    { lck = $2 + 0 }
/^RssAnon:/  { anon = $2 + 0 }
/^RssFile:/  { file = $2 + 0 }
/^RssShmem:/ { shm = $2 + 0 }
/^VmSwap:/ {
  pid = FILENAME; gsub(/^.*\/proc\/|\/status$/, "", pid)
  if ($2 + 0 > 0) print "psw", pid, comm, $2
  held = anon + shm + (lck < file ? lck : file)
  tot += held; tshm += shm
  if (held >= 1024) print "pmem", pid, comm, held, shm
  nextfile
}
END { print "pmemtot", tot + 0, tshm + 0 }' /proc/[0-9]*/status 2>/dev/null

# Per-process disk I/O: one "pio PID COMM RBYTES WBYTES" line per process
# with nonzero cumulative counters. Bar.qml diffs against the previous tick
# in JS so multiple bar instances don't race on a shared state file.
gawk '
BEGINFILE {
  pid = FILENAME
  gsub(/^.*\/proc\/|\/io$/, "", pid)
  rd = 0; wr = 0
  if (ERRNO) nextfile
}
/^read_bytes:/  { rd = $2 + 0 }
/^write_bytes:/ { wr = $2 + 0 }
ENDFILE {
  if (rd > 0 || wr > 0) {
    cf = "/proc/" pid "/comm"
    if ((getline comm < cf) <= 0) comm = "-"
    close(cf)
    gsub(/ /, "_", comm)
    if (comm == "") comm = "-"
    print "pio", pid, comm, rd, wr
  }
}
' /proc/[0-9]*/io 2>/dev/null
