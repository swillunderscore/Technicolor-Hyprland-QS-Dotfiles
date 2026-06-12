// technicolor-sync.js — feed the live wallpaper palette into Spotify.
// Polls the tiny localhost server (technicolor-color-server.py) and sets the
// --tc-* CSS vars; the Technicolor theme's user.css does everything else
// (including the @property cross-fade, same as Discord).
//
// The wallpaper background is fetched as a BLOB and exposed via a blob: URL —
// Spotify's CSP blocks http:// images in CSS but allows fetch() + blob: (it
// uses blob: for album art itself).
//
// Debug channels (keys starting with "_" in the JSON, set manually while
// iterating on the theme):
//   _css   -> injected live into a <style> tag (preview CSS without re-apply)
//   _probe -> querySelector; its outerHTML is POSTed back to the server
(function technicolorSync() {
    const BASE = "http://127.0.0.1:9573/";
    let last = "";
    let lastProbe = "";
    let lastJs = "";

    async function tick() {
        try {
            const r = await fetch(BASE, { cache: "no-store" });
            if (!r.ok) return;
            const txt = await r.text();
            if (txt === last) return;
            last = txt;
            const colors = JSON.parse(txt);
            const root = document.documentElement;
            for (const [k, v] of Object.entries(colors)) {
                if (k.startsWith("_")) continue;
                root.style.setProperty("--tc-" + k, v);
            }
            // live CSS preview channel
            let st = document.getElementById("technicolor-live");
            if (!st) {
                st = document.createElement("style");
                st.id = "technicolor-live";
                document.head.appendChild(st);
            }
            st.textContent = colors._css || "";
            // DOM probe channel
            if (colors._probe && colors._probe !== lastProbe) {
                lastProbe = colors._probe;
                const el = document.querySelector(colors._probe);
                fetch(BASE + "dom", {
                    method: "POST",
                    body: el ? el.outerHTML : "NOT FOUND: " + colors._probe,
                }).catch(() => {});
            }
            // JS eval channel (debug/iteration; server is localhost-only)
            if (colors._js && colors._js !== lastJs) {
                lastJs = colors._js;
                let out;
                try { out = String(eval(colors._js)); } catch (e) { out = "EVAL ERROR: " + e; }
                fetch(BASE + "dom", { method: "POST", body: out }).catch(() => {});
            }
        } catch (e) { /* server down -> keep baked fallback colors */ }
    }
    setInterval(tick, 1500);
    tick();
})();
