#!/usr/bin/env python3
# Persistent helper: spawns `sudo nethogs -t -d 1` and converts each refresh
# into two lines on stdout for the shell to consume.
#
# Output: "nettop <up_pid> <up_comm> <up_bps> <down_pid> <down_comm> <down_bps>"
#         pid="-" and comm="-" when nothing was active (bar's small chart);
#         "netprocs <comm>:<down_bps>:<up_bps> ..." — every process with
#         traffic this refresh, aggregated by comm, busiest first (the
#         popup's per-process graph lines).
#
# nethogs runs with -v 2 (cumulative TOTAL BYTES per PID — the default -v 0 is
# a kB/s RATE, and diffing rates yields acceleration ≈ 0 for steady transfers,
# which flatlined the per-app graph lines); we diff between refreshes to
# recover the per-second byte rate for that interval.

import os, select, signal, subprocess, sys

NETHOGS = "/usr/bin/nethogs"


def _shutdown(*_):
    try:
        proc.terminate()
    except Exception:
        pass
    sys.exit(0)


signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT, _shutdown)

proc = subprocess.Popen(
    ["sudo", "-n", NETHOGS, "-t", "-d", "1", "-v", "2"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    bufsize=1,
)

# Last known cumulative counters, kept PERSISTENTLY (not just for the previous
# snapshot): nethogs drops a process from its listing while it has no traffic,
# so a process that idles and then resumes would look brand-new and diff against
# zero — reporting its entire lifetime total as one instant spike. Remembering
# it across the gap keeps the diff honest. Entries are pruned once they've been
# absent a while so this can't grow forever.
prev: dict[str, tuple[float, float, int]] = {}   # pid -> (sent, recv, tick)
curr: dict[str, tuple[float, float, str]] = {}
seen_refresh = False
primed = False          # set once the first snapshot has established baselines
tick = 0                # rotate counter, used to age out stale pids
STALE_TICKS = 300       # ~5 min at one snapshot/second


def emit():
    top_u_pid = top_d_pid = "-"
    top_u_name = top_d_name = "-"
    top_u = top_d = 0.0
    by_comm: dict[str, list[float]] = {}
    for pid, (sent, recv, name) in curr.items():
        # Baseline for a pid we haven't seen before:
        #   * on the very FIRST snapshot, every pid is "new" and its counter is
        #     however much it had already transferred before we attached, so
        #     baseline = its current value (otherwise the graph opens with one
        #     enormous bogus spike).
        #   * afterwards a new pid is a genuinely NEW flow whose -v 2 counter
        #     starts near zero, so baseline = 0 and its very first interval is
        #     reported. Defaulting to "current" here instead (the old behaviour)
        #     made every new flow diff to 0, which the `ds > 0 or dr > 0` filter
        #     then dropped — costing a full extra refresh of latency and losing
        #     short transfers entirely.
        known = prev.get(pid)
        if known is not None:
            ps, pr = known[0], known[1]
        elif primed:
            ps, pr = 0.0, 0.0       # genuinely new flow: count it from zero
        else:
            ps, pr = sent, recv     # first snapshot: adopt as baseline, no spike
        ds = max(0.0, sent - ps)
        dr = max(0.0, recv - pr)
        if ds > top_u:
            top_u, top_u_pid, top_u_name = ds, pid, name
        if dr > top_d:
            top_d, top_d_pid, top_d_name = dr, pid, name
        if ds > 0 or dr > 0:
            agg = by_comm.setdefault(name, [0.0, 0.0])
            agg[0] += dr
            agg[1] += ds
    # -v 2 values are already bytes — no kB conversion.
    print(
        f"nettop {top_u_pid} {top_u_name} {int(top_u)} "
        f"{top_d_pid} {top_d_name} {int(top_d)}",
        flush=True,
    )
    # Per-process rates for the popup's per-app graph lines. Busiest first,
    # capped so a torrent with hundreds of peers can't bloat the line.
    procs = sorted(by_comm.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:12]
    print(
        "netprocs " + " ".join(
            f"{name}:{int(d)}:{int(u)}" for name, (d, u) in procs
        ),
        flush=True,
    )


def rotate():
    """Emit the snapshot just finished and make it the baseline for the next."""
    global prev, curr, primed, tick
    emit()
    primed = True
    tick += 1
    for pid, (s, r, _) in curr.items():
        prev[pid] = (s, r, tick)
    if tick % 60 == 0:              # occasional prune of long-gone processes
        for pid in [k for k, v in prev.items() if tick - v[2] > STALE_TICKS]:
            del prev[pid]
    curr = {}


# nethogs prints "Refreshing:" then that snapshot's lines, all at once, once per
# -d interval (1 s; fractional -d is NOT supported — it busy-spins). Emitting
# only when the NEXT "Refreshing:" arrived meant a finished snapshot sat unsent
# for a whole interval: measured 2.6 s before a new flow reached the graph while
# the /proc/net/dev total reacted immediately. Instead flush as soon as the
# block goes quiet (no further output for IDLE_FLUSH_S), which cuts the wait to
# roughly nethogs' own interval. "Refreshing:" then only has to reset the
# already-flushed state (and still rotates if a flush somehow hasn't happened).
IDLE_FLUSH_S = 0.12
flushed = False

while True:
    ready, _, _ = select.select([proc.stdout], [], [], IDLE_FLUSH_S)
    if not ready:
        # Output went quiet: the snapshot is complete, send it now.
        if seen_refresh and curr and not flushed:
            rotate()
            flushed = True
        continue

    raw = proc.stdout.readline()
    if not raw:                      # nethogs exited
        break
    line = raw.rstrip("\n")
    if line.startswith("Refreshing:"):
        if seen_refresh and curr and not flushed:
            rotate()                 # fallback: block never went idle
        flushed = False
        seen_refresh = True
        continue
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    head, sent_s, recv_s = parts[0], parts[1], parts[2]
    try:
        sent = float(sent_s)
        recv = float(recv_s)
    except ValueError:
        continue
    bits = head.split("/")
    if len(bits) < 3:
        continue
    pid = bits[-2]
    cmd = "/".join(bits[:-2])
    # Proton/Wine games report Windows paths ("S:\common\Game Name\game.exe")
    # whose spaces would truncate at the first word — take the backslash
    # basename first so they come out as "game.exe".
    if "\\" in cmd:
        cmd = cmd.rsplit("\\", 1)[-1]
    bin_path = cmd.split(" ", 1)[0]
    # Chromium/Electron utility subprocesses set argv[0] = "/proc/self/exe"
    # so the kid can re-exec itself; that turns into the useless basename
    # "exe". Resolve the real binary via readlink, falling back to comm so
    # we get something like "electron" or "steamwebhelper" instead.
    if bin_path == "/proc/self/exe" or bin_path.endswith("/exe"):
        try:
            bin_path = os.readlink(f"/proc/{pid}/exe")
        except OSError:
            try:
                with open(f"/proc/{pid}/comm") as f:
                    bin_path = f.read().strip() or bin_path
            except OSError:
                pass
    name = bin_path.rsplit("/", 1)[-1] or "-"
    name = name.replace(" ", "_").replace("\t", "_") or "-"
    if not pid or pid == "0":
        # nethogs couldn't tie this flow to a process (kernel traffic).
        # Rescue recognizable kernel services so they aren't invisible —
        # e.g. NFS (port 2049) serving diskless clients — and drop the
        # rest, which is mostly zero-byte "unknown TCP" noise.
        if ":2049" in head:
            ps, pr, _ = curr.get("nfsd", (0.0, 0.0, "nfsd"))
            curr["nfsd"] = (ps + sent, pr + recv, "nfsd")
        continue
    curr[pid] = (sent, recv, name)
