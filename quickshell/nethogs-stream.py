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

import collections, os, select, signal, subprocess, sys, threading, time

# The patched build (hypr/system/nethogs-patched, installed root-owned by its
# install.sh) is used when present. Stock 0.9.0 in this -v 2 mode credits new
# connections to whichever program used the same local port before (often
# "unknown"), never forgets a connection (memory only grows), names a
# connection only at its first packet, and prints totals with 6 digits.
NETHOGS_PATCHED = os.environ.get("NETHOGS_PATCHED", "/usr/local/libexec/nethogs-patched")
NETHOGS_STOCK = "/usr/bin/nethogs"
_fallback_logged = False

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
    global _fallback_logged
    binary = NETHOGS_PATCHED
    if not os.path.exists(binary):
        binary = NETHOGS_STOCK
        if not _fallback_logged:
            log(f"nethogs-patched not installed ({NETHOGS_PATCHED}): using stock "
                f"nethogs; per-app names go stale over time ('unknown' grows)")
            _fallback_logged = True
    # Raw, unbuffered pipe: the main loop splits lines itself (see the read
    # loop at the bottom) — a buffered reader hides lines from select().
    # Arguments must stay exactly these: the patched build's sudo rule allows
    # nothing else.
    return subprocess.Popen(
        ["sudo", "-n", binary, "-t", "-d", "1", "-v", "2", "-C"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
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
        if comms.get(pid) in ("nethogs", "nethogs-patched"):
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
    try:
        if udp_proc is not None:
            udp_proc.terminate()
    except Exception:
        pass
    sys.exit(0)


signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT, _shutdown)

# ── Naming "unknown" UDP ──
# nethogs can only tie a packet to a program through a CONNECTED socket, so
# everything sent or received on an unconnected UDP socket (Sunshine's stream,
# Tailscale, game servers, mDNS) arrives as one "unknown" lump. udp-port-meter
# (root helper, hypr/system/udp-port-meter, its own sudo rule) counts UDP bytes
# per local port and names the program that owns each port. Its totals are
# used to split the lump; whatever it can't explain stays "unknown". Without
# it installed the row simply stays "unknown" — and the log says so, once.
UDP_METER = os.environ.get(
    "UDP_METER_CMD", "sudo -n /usr/local/libexec/udp-port-meter").split()
UDP_METER_RETRY_S = 60.0
udp_lock = threading.Lock()
# Meter readings (arrival time, {name: (down, up) cumulative}), ~10 a second.
# nethogs' snapshot is compared against the meter's count AT THE MOMENT the
# snapshot was printed (interpolated between readings). Comparing against
# "whatever the meter said when we got round to it" put the two windows up to
# 0.2 s apart: ±10% of Sunshine's stream showed up as "unknown" every few s.
udp_samples: collections.deque = collections.deque(maxlen=64)
udp_gen = 0                  # bumps when a new meter run starts (totals reset)
udp_proc = None
udp_seen: dict[str, tuple[int, int]] = {}     # meter totals at the last emit
udp_seen_gen = -1
udp_pending: dict[str, list[float]] = {}      # counted by the meter, not yet
                                              # matched to nethogs' lump
udp_alive = False            # meter running and reporting
udp_settled = threading.Event()   # set once the meter is up OR known down
UDP_HEAD_START_S = 3.0       # meter runs this long before nethogs starts
UDP_CARRY_TICKS = 3          # meter bytes wait this many ticks for nethogs
udp_recent: dict[str, collections.deque] = {}   # name -> its last few deltas
udp_held = [0.0, 0.0]        # nethogs' unknown UDP (down, up) from the LAST
                             # tick that the meter hasn't explained yet
UDP_LUMP = "unknown_udp_lump"   # by_comm key of nethogs' "unknown UDP" until
                                # udp_split() hands it out (never printed)


def udp_meter_loop():
    global udp_gen, udp_proc, udp_alive
    state = None             # last LOGGED state: None / "up" / "down"
    helper = UDP_METER[-1]
    while True:
        why = None
        if helper.startswith("/") and not os.path.exists(helper):
            why = f"{helper} not installed"
        else:
            try:
                with open(LOG, "a") as errf:      # helper's own warnings
                    p = subprocess.Popen(UDP_METER, stdout=subprocess.PIPE,
                                         stderr=errf, text=True, bufsize=1)
            except OSError as e:
                why = f"could not start: {e}"
                p = None
            if p is not None:
                udp_proc = p
                started = False
                for line in p.stdout:
                    if not line.startswith("udp"):
                        continue
                    tot = {}
                    for f in line.split()[1:]:
                        try:
                            nm, d, u = f.rsplit(":", 2)
                            tot[nm] = (int(d), int(u))
                        except ValueError:
                            continue
                    with udp_lock:
                        if not started:
                            udp_gen += 1
                            udp_samples.clear()      # last run's totals
                        udp_samples.append((time.monotonic(), tot))
                    if not started:
                        started = True
                        udp_alive = True
                        udp_settled.set()
                        if state != "up":
                            log("udp-port-meter running: unknown UDP is split by program")
                            state = "up"
                why = f"exited with code {p.wait()}"
                udp_alive = False
        udp_settled.set()
        if state != "down":
            log(f"udp-port-meter not running ({why}): UDP on unconnected sockets "
                f"stays 'unknown'; retrying every {int(UDP_METER_RETRY_S)} s")
            state = "down"
        time.sleep(UDP_METER_RETRY_S)


def udp_totals_at(samples, t):
    """The meter's cumulative totals at time t, interpolated between the two
    readings around it (or the nearest one when t is outside them)."""
    if not samples:
        return {}
    before = after = None
    for ts, tot in samples:
        if ts <= t:
            before = (ts, tot)
        else:
            after = (ts, tot)
            break
    if before is None:
        return dict(after[1])
    if after is None or after[0] <= before[0]:
        return dict(before[1])
    f = (t - before[0]) / (after[0] - before[0])
    out = {}
    for name, (d1, u1) in after[1].items():
        d0, u0 = before[1].get(name, (0, 0))
        out[name] = (d0 + (d1 - d0) * f, u0 + (u1 - u0) * f)
    return out


def udp_split(by_comm, t_ref):
    """Move the meter's share of nethogs' unknown-UDP lump (by_comm[UDP_LUMP])
    onto the programs it named; the rest joins the "unknown" row. Never moves
    more than the lump holds, so the rows still add up to what nethogs saw.
    The two run on different clocks, so each side gets ONE extra
    tick to be matched: bytes the meter counted before nethogs did are carried
    one tick, and so is lump nethogs saw before the meter did (it shows as
    "unknown" only if the next tick can't explain it either — measured: per
    tick 0.1-1.3 KB of Sunshine's download read as "unknown" otherwise, while
    over 20 s the meter explained all of it). Nothing piles up past a tick."""
    global udp_seen, udp_seen_gen, udp_held
    with udp_lock:
        samples, gen = list(udp_samples), udp_gen
    latest = udp_totals_at(samples, t_ref)
    now = by_comm.pop(UDP_LUMP, [0.0, 0.0])
    if not udp_alive:
        # No meter: nothing can explain the lump. Show it, hold nothing.
        show = [udp_held[0] + now[0], udp_held[1] + now[1]]
        udp_held = [0.0, 0.0]
        if show[0] or show[1]:
            agg = by_comm.setdefault("unknown", [0.0, 0.0])
            agg[0] += show[0]
            agg[1] += show[1]
        return
    if gen != udp_seen_gen:
        # New meter run: count from ZERO, i.e. everything it saw since it
        # started. nethogs runs 1.5-2 s behind the meter, so the meter's
        # count has to be a little ahead or a stream's last 2 s (reported
        # late by nethogs) find nothing to match and show as "unknown" —
        # seen live after a mid-stream restart: 61.5 KB at the disconnect.
        # The surplus only waits in udp_pending (never shown) and expires.
        udp_seen, udp_seen_gen = {}, gen
        udp_pending.clear()
        udp_recent.clear()
    deltas = {}
    for name, (d, u) in latest.items():
        sd, su = udp_seen.get(name, (0, 0))
        deltas[name] = (max(0, d - sd), max(0, u - su))
    udp_seen = dict(latest)
    for name, (d, u) in deltas.items():
        if d or u:
            pend = udp_pending.setdefault(name, [0.0, 0.0])
            pend[0] += d
            pend[1] += u
    shown = [0.0, 0.0]
    for k in (0, 1):                     # 0 = down, 1 = up
        old, new = udp_held[k], now[k]   # older lump is matched first
        want = sum(pend[k] for pend in udp_pending.values())
        give = min(old + new, want)
        if give > 0:
            for name, pend in udp_pending.items():
                share = pend[k] * give / want
                if share > 0:
                    by_comm.setdefault(name, [0.0, 0.0])[k] += share
                    pend[k] -= share
        used_old = min(old, give)
        shown[k] = old - used_old        # had its extra tick: it IS unknown
        udp_held[k] = new - (give - used_old)
    if shown[0] >= 1 or shown[1] >= 1:
        agg = by_comm.setdefault("unknown", [0.0, 0.0])   # may hold TCP already
        agg[0] += shown[0]
        agg[1] += shown[1]
    # Unmatched meter bytes wait for nethogs up to UDP_CARRY_TICKS ticks, even
    # once the traffic stops: nethogs reports a stream's last moments a tick or
    # two late (seen: 245 KB of Sunshine's final 0.6 s as "unknown" when the
    # carry was capped by the CURRENT tick's count, which was 0 by then).
    for name in set(udp_pending) | set(udp_recent):
        hist = udp_recent.setdefault(name, collections.deque(maxlen=UDP_CARRY_TICKS))
        hist.append(deltas.get(name, (0, 0)))
        pend = udp_pending.get(name)
        if pend is not None:
            pend[0] = min(pend[0], sum(h[0] for h in hist))
            pend[1] = min(pend[1], sum(h[1] for h in hist))
            if pend[0] < 1 and pend[1] < 1:
                del udp_pending[name]
        if not any(h[0] or h[1] for h in hist):
            del udp_recent[name]


threading.Thread(target=udp_meter_loop, daemon=True).start()
# nethogs reports traffic up to ~2.5 s late, so its first readings would
# include traffic from before the meter existed — bytes the meter can never
# match, which then surfaced as "unknown" when a stream that was already
# running ended. Let the meter count first.
if udp_settled.wait(5.0) and udp_alive:
    time.sleep(UDP_HEAD_START_S)

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
block_t = time.monotonic()  # when nethogs printed the snapshot being collected
primed = False          # set once the first snapshot has established baselines
tick = 0                # rotate counter, used to age out stale pids
STALE_TICKS = 300       # ~5 min at one snapshot/second


def emit():
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
        elif primed and not pid.startswith("unknown"):
            ps, pr = 0.0, 0.0       # genuinely new flow: count it from zero
        # (nethogs' "unknown UDP/TCP" lines are NOT new flows: their counters
        # run from nethogs' start, so a first sighting adopts the baseline —
        # counting from zero dumped seconds of traffic into one tick.)
        else:
            ps, pr = sent, recv     # first snapshot: adopt as baseline, no spike
        ds = max(0.0, sent - ps)
        dr = max(0.0, recv - pr)
        if ds > 0 or dr > 0:
            agg = by_comm.setdefault(name, [0.0, 0.0])
            agg[0] += dr
            agg[1] += ds
    udp_split(by_comm, block_t)
    # Top sender/receiver for the bar's small chart, per PROGRAM (same rows as
    # the popup legend). The pid field is unused by the bar: always "-" (the
    # "unknown" lump has no pid, and nethogs' name for it contains a space,
    # which used to shift every field of this line).
    top_u_name = top_d_name = "-"
    top_u = top_d = 0.0
    for name, (d, u) in by_comm.items():
        if u > top_u:
            top_u, top_u_name = u, name
        if d > top_d:
            top_d, top_d_name = d, name
    # -v 2 values are already bytes — no kB conversion.
    print(
        f"nettop - {top_u_name} {int(top_u)} - {top_d_name} {int(top_d)}",
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
        # Only real pids. The pid-0 pseudo-entries ("unknown UDP", nfsd's
        # per-connection lines) keep counting for nethogs' whole life, so
        # pruning one after an idle spell would replay its lifetime total
        # as a single spike when traffic resumes.
        for pid in [k for k, v in prev.items()
                    if k.isdigit() and tick - v[2] > STALE_TICKS]:
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

# Lines are split out of the raw pipe here, not with readline(). A buffered
# reader pulls several lines in at once, and the ones it holds are invisible
# to select(), which then called the pipe idle in the middle of a block: the
# idle flush sent half a block and the rest landed in the NEXT tick. Seen
# 2026-11-17: 39 of 225 ticks showed "unknown", nearly all of it nethogs'
# lifetime unknown total replayed as one second of traffic.
lines_ready: collections.deque = collections.deque()
partial = b""                    # a line nethogs hasn't finished writing

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
            lines_ready.clear()
            partial = b""
            continue

    if not lines_ready:
        ready, _, _ = select.select([proc.stdout], [], [], IDLE_FLUSH_S)
        if not ready:
            # Output went quiet with every line handled: the snapshot is
            # complete, send it now.
            if seen_refresh and curr and not flushed and not partial:
                rotate()
                flushed = True
            continue
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:                # nethogs exited
            break
        *done, partial = (partial + chunk).split(b"\n")
        lines_ready.extend(done)
        continue

    line = lines_ready.popleft().decode("utf-8", "replace")
    if line.startswith("Refreshing:"):
        if seen_refresh and curr and not flushed:
            rotate()                 # fallback: block never went idle
        flushed = False
        seen_refresh = True
        block_t = time.monotonic()   # nethogs prints the block all at once
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
        # nethogs couldn't tie this flow to a process. Kernel services
        # (NFS on 2049) get their own name. Everything else is NOT dropped:
        # nethogs can only match CONNECTED sockets, so every unconnected UDP
        # socket — Sunshine's video stream, Tailscale/WireGuard, game
        # servers — lands here as "unknown UDP". Dropping it hid a 290 KB/s
        # Sunshine upload completely (2026-11-14). Only that UDP lump goes
        # to the meter split (UDP_LUMP); unknown TCP (sockets the kernel
        # holds after the app closed them) and per-connection lines are
        # shown as "unknown" directly — in the lump, the split credited TCP
        # bytes to whatever UDP program the meter had counted.
        # Keyed by nethogs' own line, and a repeat REPLACES (the counter is
        # cumulative): summing repeats replayed the lifetime total whenever
        # a line from the previous block was still in hand. Grouping by name
        # (all nfsd connections into one row) happens in emit().
        if ":2049" in head:
            name = "nfsd"
        elif head.startswith("unknown UDP/"):
            name = UDP_LUMP
        else:
            name = "unknown"
        curr[head] = (sent, recv, name)
        continue
    curr[pid] = (sent, recv, name)
