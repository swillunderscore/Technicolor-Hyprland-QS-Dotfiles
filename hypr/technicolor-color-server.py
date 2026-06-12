#!/usr/bin/env python3
"""
technicolor-color-server.py — tiny localhost HTTP server exposing the live
technicolor palette JSON ($XDG_RUNTIME_DIR/technicolor-colors.json, written by
gen-discord-theme.py on every wallpaper change) to the Spicetify extension.
Spotify's web view (xpui) can't read local files, so it polls this instead.

Also accepts POST /dom — the extension's debug channel for reporting a DOM
snippet (used to discover Spotify's class names when iterating on the theme);
saved to $XDG_RUNTIME_DIR/spotify-dom.html.

Bound to 127.0.0.1 only. Started by hyprland exec-once.
"""
import http.server
import os
import socketserver

PORT = 9573
RT = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
PATH = os.path.join(RT, "technicolor-colors.json")
DOM = os.path.join(RT, "spotify-dom.html")


class Handler(http.server.BaseHTTPRequestHandler):
    def _headers(self, code=200, ctype="application/json", length=0):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(length))
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/wall"):
            # serve the CURRENT wallpaper file -> Spotify uses it (blurred) as its
            # background = "transparent to the wallpaper" illusion
            try:
                wp = open("/tmp/wallpaper-current-path").read().strip()
                data = open(wp, "rb").read()
                ext = os.path.splitext(wp)[1].lower().lstrip(".")
                ctype = {"webp": "image/webp", "gif": "image/gif", "png": "image/png",
                         "jpg": "image/jpeg", "jpeg": "image/jpeg"}.get(ext, "application/octet-stream")
            except Exception:
                data, ctype = b"", "application/octet-stream"
            self._headers(ctype=ctype, length=len(data))
            self.wfile.write(data)
            return
        try:
            data = open(PATH, "rb").read()
        except Exception:
            data = b"{}"
        self._headers(length=len(data))
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(min(n, 2_000_000))
        try:
            with open(DOM, "wb") as f:
                f.write(body)
        except Exception:
            pass
        self._headers(length=2)
        self.wfile.write(b"ok")

    def do_OPTIONS(self):
        self._headers()

    def log_message(self, *a):  # quiet
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    Server(("127.0.0.1", PORT), Handler).serve_forever()
