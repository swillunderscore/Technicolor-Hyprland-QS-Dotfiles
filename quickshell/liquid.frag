#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;
    float cardW;
    float cardH;
    float totalH;
    float cardRad;
    float dotRad;
    float tailH;
    float bdr;
    float tintR;
    float tintG;
    float tintB;
};

// SDF rounded box
float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// SDF circle
float sdCircle(vec2 p, float r) {
    return length(p) - r;
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x * cardW, qt_TexCoord0.y * totalH);
    float p = progress;

    // ── Define the full shape (card + stem + dot) ──

    // Card: rounded rect at top
    vec2 cardCenter = vec2(cardW / 2.0, cardH / 2.0);
    vec2 cardHalf = vec2(cardW / 2.0 - 0.5, cardH / 2.0 - 0.5);
    float dCard = sdRoundBox(px - cardCenter, cardHalf, cardRad);

    // Dot: circle at bottom
    vec2 dotCenter = vec2(cardW / 2.0, totalH - dotRad - 1.0);
    float dDot = sdCircle(px - dotCenter, dotRad);

    // Stem: smooth taper from card bottom to dot top
    // Use the Y position to interpolate width from card-width to dot-width
    float stemTop = cardH;
    float stemBot = totalH - dotRad * 2.0;
    float stemY = clamp((px.y - stemTop) / max(stemBot - stemTop, 1.0), 0.0, 1.0);
    // Smooth cubic narrowing
    float t = stemY * stemY * (3.0 - 2.0 * stemY);
    float halfW = mix(cardW * 0.42, dotRad, t);
    // SDF for the stem (rounded horizontal slab at each Y)
    float dStem = length(max(vec2(abs(px.x - cardW / 2.0) - halfW, abs(px.y - (stemTop + stemBot) / 2.0) - (stemBot - stemTop) / 2.0), 0.0));

    // Smooth union of all three shapes (metaball blend)
    float k = 6.0;
    float dStemDot = -log(exp(-k * dStem) + exp(-k * dDot)) / k;
    float dShape = -log(exp(-k * dStemDot) + exp(-k * dCard)) / k;

    // Shape alpha (the full outline)
    float shapeAlpha = 1.0 - smoothstep(-1.0, 0.5, dShape);

    // Inner shape (inset by border width)
    float dInner = dShape + bdr;
    float innerAlpha = 1.0 - smoothstep(-1.0, 0.5, dInner);

    // ── Liquid fill effect ──
    // The fill level rises from the dot (bottom) upward based on progress
    // At p=0: fill is at the very bottom (dot only)
    // At p=1: fill reaches the top of the card

    // Fill line Y position (bottom = totalH, top = 0)
    float fillY = totalH - p * totalH;

    // Soft edge on the fill line for liquid look
    float fillMask = smoothstep(fillY + 8.0, fillY - 4.0, px.y);

    // Wobble on the fill line for organic liquid feel
    float wobble = sin(px.x * 0.08 + p * 6.0) * 3.0 * (1.0 - step(0.95, p));
    float fillMaskWobble = smoothstep(fillY + 8.0 + wobble, fillY - 4.0 + wobble, px.y);

    // ── Compose colors ──
    vec3 tint = vec3(tintR, tintG, tintB);
    vec3 innerColor = vec3(0.06, 0.06, 0.08);

    // Border: visible where shape exists but inner doesn't
    // Fill: the colored border rises with the liquid level
    // Above fill line: shape outline only (dim), inner is dark
    // Below fill line: shape outline is tinted, inner is dark

    // The border color appears where the liquid has filled
    float borderZone = shapeAlpha - innerAlpha;
    vec3 borderColor = mix(tint * 0.15, tint, fillMaskWobble);

    // Inner area: always dark where filled, transparent where not yet filled
    float innerFill = innerAlpha * fillMaskWobble;

    // Combine: border ring + filled interior
    vec3 col = borderColor * borderZone + innerColor * innerFill;
    float alpha = shapeAlpha * fillMaskWobble;

    // But we always want the shape outline visible even above the fill line
    // (thin border hint so you can see where the preview will be)
    float ghostAlpha = shapeAlpha * 0.08 * (1.0 - fillMaskWobble);
    col += tint * ghostAlpha;
    alpha += ghostAlpha;

    fragColor = vec4(col, alpha) * qt_Opacity;
}
