#!/usr/bin/env python3
"""
spotify-liked.py — tools for your Spotify Liked Songs, run through the live
Spicetify session: no developer app, no extra login, read-only.

It rides the technicolor-sync.js "_js" eval channel: a snippet of JS is dropped
into the color-server's JSON ($XDG_RUNTIME_DIR/technicolor-colors.json), the
extension inside Spotify evals it and POSTs the result to
$XDG_RUNTIME_DIR/spotify-dom.html, which we read; the palette JSON is restored
after. Needs Spotify open with the Technicolor theme (color-server +
technicolor-sync.js).

Subcommands:
  scan     cross-reference Liked Songs against the soul-over-ai known-AI-artist
           list — matched by EXACT Spotify artist ID — and print any hits.
  export   write all Liked Songs to a CSV backup (default ~/spotify-liked-DATE.csv).

The Spotify Web API isn't authenticated from this channel, so we read the
library via Spotify's internal Spicetify.Platform.LibraryAPI instead.
"""
import csv
import json
import os
import random
import sys
import time
import urllib.request

RT = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
COLORS = os.path.join(RT, "technicolor-colors.json")
DOM = os.path.join(RT, "spotify-dom.html")
AI_LIST_URL = "https://raw.githubusercontent.com/xoundbyte/soul-over-ai/main/dist/artists.json"
CACHE = os.path.expanduser("~/.cache/technicolor/ai-artists.json")

# Walk every Liked Song via the internal LibraryAPI (paginated) into `all`.
FETCH_ALL = (
    "var all=[],offset=0,total=1e9;"
    "while(offset<total){var L=await Spicetify.Platform.LibraryAPI.getTracks({limit:100,offset:offset});"
    "total=L.totalLength||(L.items.length+offset);all=all.concat(L.items||[]);"
    "if(!L.items||L.items.length===0)break;offset+=L.items.length;if(all.length>60000)break;}"
)


def server_up():
    try:
        urllib.request.urlopen("http://127.0.0.1:9573/", timeout=2).read()
        return True
    except Exception:
        return False


def run_in_spotify(js, marker, timeout=60):
    """Inject JS into the Spicetify eval channel; return the POSTed result (str) or None."""
    if not server_up():
        raise SystemExit("Spotify color-server (127.0.0.1:9573) isn't responding.\n"
                         "Open Spotify with the Technicolor theme applied, then try again.")
    payload = "/*%d*/" % random.randint(1, 10 ** 9) + js   # nonce so the extension re-evals
    try:
        open(DOM, "w").close()
    except Exception:
        pass
    try:
        colors = json.load(open(COLORS))
    except Exception:
        colors = {}
    colors["_js"] = payload
    json.dump(colors, open(COLORS, "w"), ensure_ascii=False)
    res = None
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.7)
        try:
            c = open(DOM, encoding="utf-8", errors="replace").read()
        except Exception:
            c = ""
        if c.startswith(marker):
            res = c
            break
    # remove _js (re-read first so a palette update mid-scan isn't clobbered)
    try:
        cur = json.load(open(COLORS))
        cur.pop("_js", None)
        json.dump(cur, open(COLORS, "w"), ensure_ascii=False)
    except Exception:
        pass
    return res


def load_ai_ids():
    """Pull the latest known-AI-artist list (cache fallback). Returns {spotifyId: name}."""
    data = None
    try:
        with urllib.request.urlopen(AI_LIST_URL, timeout=20) as r:
            raw = r.read()
        data = json.loads(raw)
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        with open(CACHE, "wb") as f:
            f.write(raw)
    except Exception:
        if os.path.exists(CACHE):
            data = json.load(open(CACHE))
        else:
            raise SystemExit("Couldn't fetch the AI-artist list and there's no cached copy.")
    return {a["spotify"]: a["name"] for a in data
            if a.get("spotify") and not a.get("removed")}


def cmd_scan():
    ids = load_ai_ids()
    js = (
        "(async()=>{try{var AI=%s;" + FETCH_ALL +
        "var seen={},M=[];"
        "for(var i=0;i<all.length;i++){var t=all[i];if(!t||!t.artists)continue;"
        "for(var j=0;j<t.artists.length;j++){var a=t.artists[j];var id=(a.uri||'').split(':').pop();"
        "if(AI[id]){var k=id+'|'+t.uri;if(!seen[k]){seen[k]=1;M.push(a.name+'\\t'+t.name);}}}}"
        "var out='AISCAN_DONE\\n'+all.length+'\\t'+M.length+'\\n'+M.join('\\n');"
        "await fetch('http://127.0.0.1:9573/dom',{method:'POST',body:out});"
        "}catch(e){await fetch('http://127.0.0.1:9573/dom',{method:'POST',body:'AISCAN_ERR '+(e&&e.message?e.message:e)});}})()"
    ) % json.dumps(ids, separators=(",", ":"), ensure_ascii=False)
    res = run_in_spotify(js, "AISCAN_", 60)
    if res is None:
        raise SystemExit("No response from Spotify (is it open?). Try again.")
    if res.startswith("AISCAN_ERR"):
        raise SystemExit("Scan failed inside Spotify: " + res[len("AISCAN_ERR"):].strip())
    lines = res.split("\n")
    scanned, nmatch = lines[1].split("\t")
    print("Scanned %s liked songs against %d known-AI artists." % (scanned, len(ids)))
    print("Flagged: %s" % nmatch)
    matches = [l for l in lines[2:] if l.strip()]
    if matches:
        print("")
        for m in matches:
            artist, track = (m.split("\t", 1) + [""])[:2]
            print("  • %s — %s" % (artist, track))
        print("\nCrowd-sourced, probabilistic flags — worth a listen, not a verdict.")
    else:
        print("\nNothing matches the known-AI list (it only knows ~%d acts)." % len(ids))


def cmd_export(path=None):
    js = (
        "(async()=>{try{" + FETCH_ALL +
        "var out=all.map(function(t){return {added:t.addedAt,name:t.name,uri:t.uri,"
        "album:(t.album&&t.album.name)||'',"
        "artists:(t.artists||[]).map(function(a){return a.name;}),"
        "artistUris:(t.artists||[]).map(function(a){return a.uri;})};});"
        "await fetch('http://127.0.0.1:9573/dom',{method:'POST',body:'AISCAN_EXPORT\\n'+JSON.stringify(out)});"
        "}catch(e){await fetch('http://127.0.0.1:9573/dom',{method:'POST',body:'AISCAN_EXPORT_ERR '+(e&&e.message?e.message:e)});}})()"
    )
    res = run_in_spotify(js, "AISCAN_EXPORT", 120)
    if res is None:
        raise SystemExit("No response from Spotify (is it open?). Try again.")
    if res.startswith("AISCAN_EXPORT_ERR"):
        raise SystemExit("Export failed inside Spotify: " + res[len("AISCAN_EXPORT_ERR"):].strip())
    tracks = json.loads(res.split("\n", 1)[1])
    if not path:
        path = os.path.expanduser(time.strftime("~/spotify-liked-%Y-%m-%d.csv"))
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["added_at", "title", "artists", "album", "spotify_uri", "artist_uris"])
        for t in tracks:
            w.writerow([t.get("added", ""), t.get("name", ""),
                        "; ".join(t.get("artists", [])), t.get("album", ""),
                        t.get("uri", ""), "; ".join(t.get("artistUris", []))])
    print("Backed up %d liked songs →\n%s" % (len(tracks), path))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "scan"
    if cmd == "scan":
        cmd_scan()
    elif cmd == "export":
        cmd_export(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        raise SystemExit("usage: spotify-liked.py [scan | export [path]]")
