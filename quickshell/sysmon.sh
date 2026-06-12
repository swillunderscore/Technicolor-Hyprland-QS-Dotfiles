#!/bin/sh
# Single-shot system stats dump for the Quickshell bar.
# Prints "key value..." lines, consumed once per tick by Bar.qml's fastStatProc.
# Cheap: only reads /proc and /sys, spawns no subprocesses beyond awk.

# CPU aggregate jiffies: user nice system idle iowait irq softirq
read -r _ u n s i io irq sirq _ < /proc/stat
echo "cpu $u $n $s $i $io $irq $sirq"

# Detect the active GPU's DRM device — the card exposing gpu_busy_percent
# (card number is not stable across machines, so never hardcode card0/card1).
gpu_dev=""
for d in /sys/class/drm/card*/device; do
    [ -e "$d/gpu_busy_percent" ] && { gpu_dev="$d"; break; }
done

if [ -n "$gpu_dev" ]; then
    # amdgpu (and anything else exposing the same sysfs)
    echo "gpu $(cat "$gpu_dev/gpu_busy_percent" 2>/dev/null || echo 0)"
    echo "vram $(cat "$gpu_dev/mem_info_vram_used" 2>/dev/null || echo 0) $(cat "$gpu_dev/mem_info_vram_total" 2>/dev/null || echo 1)"
elif command -v nvidia-smi >/dev/null 2>&1; then
    # Nvidia proprietary/open module: no busy/vram/temp sysfs — one
    # nvidia-smi call covers usage, VRAM and temperature (Bar.qml prefers a
    # "gputemp" line over its hwmon scan). timeout guards a sleeping driver.
    timeout 1 nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null |
    awk -F', *' 'NR==1 { print "gpu " $1+0
                         print "vram " $2*1048576 " " (($3+0) > 0 ? $3*1048576 : 1)
                         print "gputemp " $4+0 }'
else
    # unknown GPU: graceful zeros (widget shows 0%, nothing breaks)
    echo "gpu 0"
    echo "vram 0 1"
fi

# Memory, in kB: MemTotal MemAvailable
awk '/^MemTotal:/{mt=$2} /^MemAvailable:/{ma=$2} END{print "mem " mt " " ma}' /proc/meminfo

# Swap (covers zram + disk swap): Used / Size summed across all swap devices
awk 'NR>1 {sz+=$3; us+=$4} END{print "swap " us+0 " " sz+0}' /proc/swaps

# Network: cumulative rx/tx bytes summed over real interfaces (skip lo, virtual)
awk -F'[: ]+' '/^[ ]*(en|eth|wl|wlp|enp|eno|ens)/{rx+=$3; tx+=$11} END{print "net " rx+0 " " tx+0}' /proc/net/dev

# Disk I/O: cumulative sectors (512B) read/written over whole-disk devices
awk '$3 ~ /^(sd[a-z]|nvme[0-9]+n[0-9]+|mmcblk[0-9]+|vd[a-z])$/ {r+=$6; w+=$10} END{print "disk " r+0 " " w+0}' /proc/diskstats

# Swap backing kind: zram-backed swap is labelled differently from disk swap
[ -e /sys/block/zram0 ] && echo "swapkind ZRAM" || echo "swapkind SWAP"

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
