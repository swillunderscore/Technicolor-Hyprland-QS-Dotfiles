// technicolor-chromakey-dolphin.glsl — FIXED-KEY variant of the v6 keyer.
//
// Dolphin's key is STATIC (the QSS paints QMainWindow rgb(1,186,188) — the
// generator never changes it), so the key comes in as a uniform instead of
// the corner-pixel self-calibration. This matters because the windowrule
// matches class org.kde.dolphin, which includes every DIALOG (settings,
// properties, copy progress): the self-calibrating shader sampled a dialog's
// corner (= secondary surface color) as the key and keyed the whole dialog
// transparent. With a fixed key, dialogs contain no key-colored pixels and
// stay fully opaque.
//
// Everything else is the proven v6 recipe: binary key decision, 16-tap
// neighbor scan, geometric post-AA on the kept boundary (premultiplied).
uniform float sim;   // key tolerance
uniform float choke; // coverage threshold: 0.5 neutral, higher bites inward
uniform vec3 keyc;   // the fixed key color (normalized 0..1)

void windowShader(inout vec4 color) {
    vec3 key = keyc;

    float dist = length(color.rgb - key);

    // pure key -> fully transparent
    // (min() keeps `choke` an active uniform — the plugin test-compiles with a
    // constant color, Mesa dead-codes the edge branch, and an inactive uniform
    // aborts loading)
    if (dist < sim + min(choke, 0.0)) {
        color = vec4(0.0);
        return;
    }

    // neighbor scan out to 4px: fade/feather bands on curved elements span
    // several pixels; the detection ring must reach past them
    float nearKey = 0.0;
    float bestD = dist;
    float dn;
    dn = length(texture(x_Tex, x_TexCoord + vec2( 1.25,  0.0 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-1.25,  0.0 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 0.0 ,  1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 0.0 , -1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 1.25,  1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-1.25, -1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 1.25, -1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-1.25,  1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 2.5 ,  0.0 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-2.5 ,  0.0 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 0.0 ,  2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 0.0 , -2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 2.5 ,  2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-2.5 , -2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 2.5 , -2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-2.5 ,  2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);

    if (nearKey > 0.5) {
        float a = clamp(dist / max(bestD, 0.0001), 0.0, 1.0);
        if (a < clamp(choke, 0.05, 0.95)) {
            color = vec4(0.0);   // below threshold: gone
            return;
        }
        // POST-KEY ANTI-ALIASING (same as v6): binary decision, then alpha
        // from the fraction of 1px neighbors that are key-pure.
        float kc = 0.0;
        kc += step(length(texture(x_Tex, x_TexCoord + vec2( 1.0,  0.0) / x_WindowSize).rgb - key), sim);
        kc += step(length(texture(x_Tex, x_TexCoord + vec2(-1.0,  0.0) / x_WindowSize).rgb - key), sim);
        kc += step(length(texture(x_Tex, x_TexCoord + vec2( 0.0,  1.0) / x_WindowSize).rgb - key), sim);
        kc += step(length(texture(x_Tex, x_TexCoord + vec2( 0.0, -1.0) / x_WindowSize).rgb - key), sim);
        kc += 0.5 * step(length(texture(x_Tex, x_TexCoord + vec2( 1.0,  1.0) / x_WindowSize).rgb - key), sim);
        kc += 0.5 * step(length(texture(x_Tex, x_TexCoord + vec2(-1.0, -1.0) / x_WindowSize).rgb - key), sim);
        kc += 0.5 * step(length(texture(x_Tex, x_TexCoord + vec2( 1.0, -1.0) / x_WindowSize).rgb - key), sim);
        kc += 0.5 * step(length(texture(x_Tex, x_TexCoord + vec2(-1.0,  1.0) / x_WindowSize).rgb - key), sim);
        float aa = clamp(1.0 - kc / 6.0, 0.0, 1.0);
        color = vec4(color.rgb * aa, aa);   // premultiplied
    }
}
