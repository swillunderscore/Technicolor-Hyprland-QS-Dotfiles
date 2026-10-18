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
#
# -C makes nethogs capture UDP too. Without it nethogs sees TCP ONLY, so QUIC
# (HTTP/3 — most of Brave/YouTube/Google traffic), game traffic, Sunshine and
# WireGuard/Tailscale never reached the graph: measured 0.07 of 10.55 MB
# attributed during a Brave download, vs 9.46 MB with -C.

import os, select, signal, subprocess, sys, time

NETHOGS = "/usr/bin/nethogs"

# Memory cap. nethogs' memory only ever grows while it runs (3.9 GB after 5.7
# days, seen 2026-10-14). Every CHECK_EVERY_S we read its resident memory and,
# past the limit, restart it in place. The bar loses about one refresh; nothing
# else notices. Each restart is logged to LOG so it never happens silently.
RSS_LIMIT_KB = int(os.environ.get("NETHOGS_RSS_LIMIT_MB", "1024")) * 1024
CHECK_EVERY_S = float(os.environ.get("NETHOGS_CHECK_S", "30"))
LOG = os.environ.get("NETHOGS_STREAM_LOG", os.path.expanduser("~/.cache/nethogs-stream.log"))


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def spawn():
    return subprocess.Popen(
        ["sudo", "-n", NETHOGS, "-t", "-d", "1", "-v", "2", "-C"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )


def nethogs_rss_kb(root_pid):
    """Resident memory (kB) of the nethogs process(es) under our sudo.
    /proc/<pid>/status is world-readable, so this works on the root process."""
    children: dict[int, list[int]] = {}
    comms: dict[int, str] = {}
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        # comm can contain spaces/parens: it sits between the first "(" and the LAST ")".
        comm = stat[stat.find("(") + 1:stat.rfind(")")]
        ppid = int(stat[stat.rfind(")") + 2:].split()[1])
        children.setdefault(ppid, []).append(int(d))
        comms[int(d)] = comm
    total, todo = 0, list(children.get(root_pid, []))
    while todo:
        pid = todo.pop()
        todo.extend(children.get(pid, []))
        if comms.get(pid) == "nethogs":
            try:
                with open(f"/proc/{pid}/status") as f:
                    for line in f:
                        if line.startswith("VmRSS:"):
                            total += int(line.split()[1])
            except OSError:
                pass
    return total


def stop(p):
    """End one nethogs run. sudo relays SIGTERM; if that doesn't land, closing
    the pipe makes nethogs die of SIGPIPE on its next write (<= 1 s)."""
    try:
        p.terminate()
        p.wait(timeout=3)
        return
    except Exception:
        pass
    try:
        p.stdout.close()
        p.wait(timeout=5)
    except Exception:
        log(f"WARNING: old nethogs (sudo pid {p.pid}) did not exit - check for a leftover nethogs process")


def _shutdown(*_):
    try:
        proc.terminate()
    except Exception:
        pass
    sys.exit(0)


signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT, _shutdown)

proc = spawn()
last_check = time.monotonic()

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
    now = time.monotonic()
    if now - last_check >= CHECK_EVERY_S:
        last_check = now
        rss = nethogs_rss_kb(proc.pid)
        if rss > RSS_LIMIT_KB:
            log(f"restart: nethogs at {rss // 1024} MB > {RSS_LIMIT_KB // 1024} MB cap")
            stop(proc)
            proc = spawn()
            # The fresh nethogs starts its cumulative -v 2 counters at zero, so the
            # old baselines would diff every pid to 0 until it out-grew its old
            # total. Start over exactly like a first launch.
            prev, curr = {}, {}
            seen_refresh = primed = flushed = False
            continue

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
