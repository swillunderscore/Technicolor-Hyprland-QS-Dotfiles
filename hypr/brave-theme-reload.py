#!/usr/bin/env python3
"""
brave-theme-reload.py — hot-apply the regenerated Brave "Technicolor" theme.

Chromium bakes an extension theme into a profile-side cache; regenerating the
files on disk does nothing on its own. The clean way to force a re-read +
re-apply is the browser-level CDP command `Extensions.loadUnpacked` — loading
the (already-loaded) unpacked theme again re-reads its manifest and re-applies
the colors. It runs against the browser target, so NO tab is opened (an
earlier version drove the brave://extensions WebUI in a real tab, which both
flashed a visible tab and didn't reliably re-apply).

Requires Brave running with --remote-debugging-port=9222. Exits silently when
Brave is closed or the port is off — wallpaper changes must never error the
pipeline.

No external deps: a minimal WebSocket client over the stdlib.
"""
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request
from urllib.parse import urlparse

PORT = 9222
THEME_PATH = os.path.expanduser("~/.config/brave-technicolor-theme")


def http(path, timeout=2):
    with urllib.request.urlopen("http://127.0.0.1:%d%s" % (PORT, path), timeout=timeout) as r:
        return r.read()


class WS:
    """Tiny client-side WebSocket: handshake + single-frame text messages."""

    def __init__(self, url, timeout=4):
        u = urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (u.path, u.hostname, u.port, key)
        ).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.sock.recv(4096)
        if b" 101 " not in buf.split(b"\r\n", 1)[0]:
            raise RuntimeError("websocket handshake refused")

    def send(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        n = len(payload)
        head = b"\x81"
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(head + mask + masked)

    def _read(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("websocket closed")
            buf += chunk
        return buf

    def recv(self):
        b1, b2 = self._read(2)
        n = b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._read(8))[0]
        if b2 & 0x80:
            mask = self._read(4)
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(self._read(n)))
        else:
            data = self._read(n)
        if (b1 & 0x0F) == 0x8:
            raise RuntimeError("websocket closed")
        return data

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def main():
    try:
        ver = json.loads(http("/json/version", timeout=1))
    except Exception:
        return 0  # Brave not running / port off — silently skip

    try:
        ws = WS(ver["webSocketDebuggerUrl"])
        ws.send(json.dumps({
            "id": 1,
            "method": "Extensions.loadUnpacked",
            "params": {"path": THEME_PATH},
        }))
        deadline = time.time() + 4
        while time.time() < deadline:
            msg = json.loads(ws.recv())
            if msg.get("id") == 1:
                if "error" in msg:
                    print("loadUnpacked error: %s" % msg["error"], file=sys.stderr)
                    ws.close()
                    return 1
                break
        ws.close()
    except Exception as e:
        print("reload failed: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
