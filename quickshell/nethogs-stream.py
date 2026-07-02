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
# nethogs outputs *cumulative* KB/refresh per PID; we diff between refreshes
# to recover the per-second byte rate for that interval.

import os, signal, subprocess, sys

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
    ["sudo", "-n", NETHOGS, "-t", "-d", "1"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    bufsize=1,
)

prev: dict[str, tuple[float, float]] = {}
curr: dict[str, tuple[float, float, str]] = {}
seen_refresh = False


def emit():
    top_u_pid = top_d_pid = "-"
    top_u_name = top_d_name = "-"
    top_u = top_d = 0.0
    by_comm: dict[str, list[float]] = {}
    for pid, (sent, recv, name) in curr.items():
        ps, pr = prev.get(pid, (sent, recv))
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
    print(
        f"nettop {top_u_pid} {top_u_name} {int(top_u * 1024)} "
        f"{top_d_pid} {top_d_name} {int(top_d * 1024)}",
        flush=True,
    )
    # Per-process rates for the popup's per-app graph lines. Busiest first,
    # capped so a torrent with hundreds of peers can't bloat the line.
    procs = sorted(by_comm.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:12]
    print(
        "netprocs " + " ".join(
            f"{name}:{int(d * 1024)}:{int(u * 1024)}" for name, (d, u) in procs
        ),
        flush=True,
    )


for raw in proc.stdout:
    line = raw.rstrip("\n")
    if line.startswith("Refreshing:"):
        if seen_refresh:
            emit()
        prev = {pid: (s, r) for pid, (s, r, _) in curr.items()}
        curr = {}
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
