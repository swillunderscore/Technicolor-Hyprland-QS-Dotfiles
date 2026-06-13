#!/usr/bin/env python3
"""
brave-theme-reload.py — hot-apply the regenerated Brave "Technicolor" theme.

Chromium bakes extension themes into a profile-side cache; the ONLY thing
that rebuilds it from disk is the brave://extensions reload action
(chrome.developerPrivate.reload). That API only exists inside the WebUI, so
this drives it over the DevTools protocol: open chrome://extensions in a
background tab, call reload on the theme, close the tab. The whole round
trip is ~quarter second — you see a tab blip and the chrome recolors.

Requires Brave running with --remote-debugging-port=9222 (add the line to
~/.config/brave-flags.conf). Exits silently when Brave is closed or the
port is off — wallpaper changes must never error the pipeline.

No external deps: minimal WebSocket client over the stdlib.
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
EXPR = """
(async () => {
  const infos = await chrome.developerPrivate.getExtensionsInfo();
  const t = infos.find(e => e.type === 'THEME' && e.name === 'Technicolor');
  if (!t) return 'theme-not-found';
  await new Promise(res => chrome.developerPrivate.reload(t.id, {failQuietly: true}, res));
  return 'reloaded';
})()
"""


def http(method, path, timeout=2):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path), method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


class WS:
    """Tiny client-side WebSocket: handshake + single-frame text messages."""

    def __init__(self, url, timeout=3):
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
        if b2 & 0x80:  # masked (servers don't, but be safe)
            mask = self._read(4)
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(self._read(n)))
        else:
            data = self._read(n)
        if (b1 & 0x0F) == 0x8:  # close
            raise RuntimeError("websocket closed")
        return data

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def main():
    # is brave's devtools endpoint up?
    try:
        http("GET", "/json/version", timeout=1)
    except Exception:
        return 0  # brave not running / port not enabled — silently skip

    target = None
    try:
        target = json.loads(http("PUT", "/json/new?chrome://extensions/"))
        ws = WS(target["webSocketDebuggerUrl"])
        result = ""
        # the WebUI needs a beat before developerPrivate is callable
        for attempt in range(4):
            ws.send(json.dumps({
                "id": 1 + attempt,
                "method": "Runtime.evaluate",
                "params": {"expression": EXPR, "awaitPromise": True, "returnByValue": True},
            }))
            deadline = time.time() + 3
            value = None
            while time.time() < deadline:
                msg = json.loads(ws.recv())
                if msg.get("id") == 1 + attempt:
                    value = msg.get("result", {}).get("result", {}).get("value")
                    break
            if value in ("reloaded", "theme-not-found"):
                result = value
                break
            time.sleep(0.3)
        ws.close()
        print(result or "no-result")
    except Exception as e:
        print("reload failed: %s" % e, file=sys.stderr)
        return 1
    finally:
        if target:
            try:
                http("GET", "/json/close/" + target["id"])
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
