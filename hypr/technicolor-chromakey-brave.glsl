// technicolor-chromakey-brave.glsl — BAND-LIMITED fixed-key variant of the
// v6 keyer, for browser chrome.
//
// Browsers render untrusted content: keying the whole window punched glass
// holes into any web pixel that matched the key (the Twitch incident, why
// browser keying was removed). This variant hard-gates the keyer to the top
// `band` window pixels — the tab-strip/frame area that the generated theme
// paints in the key color — so web content below can contain ANY color and
// is never touched. Pair with a windowrule that skips fullscreen windows
// (chrome hidden -> the top band would be content).
//
// Everything else is the proven v6 recipe: binary key decision, 16-tap
// neighbor scan, geometric post-AA on the kept boundary (premultiplied).
uniform float sim;   // key tolerance
uniform float choke; // coverage threshold: 0.5 neutral, higher bites inward
uniform vec3 keyc;   // the fixed key color (normalized 0..1)
uniform float band;  // keyable region: top `band` window pixels

void windowShader(inout vec4 color) {
    // chrome-only gate: below the tab strip nothing is ever keyed
    float py = x_TexCoord.y * x_WindowSize.y;
    if (py > band + min(sim, 0.0)) return;

    vec3 key = keyc;

    float dist = length(color.rgb - key);

    // pure key -> fully transparent
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
        // POST-KEY ANTI-ALIASING: binary decision, then alpha from the
        // fraction of 1px neighbors that are key-pure.
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
