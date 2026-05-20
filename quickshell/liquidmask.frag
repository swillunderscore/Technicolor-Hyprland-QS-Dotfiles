#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;
    float totalH;
    float seed;
};

float hash(float n) {
    return fract(sin(n) * 43758.5453);
}

float noise(float x) {
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(hash(i), hash(i + 1.0), u);
}

void main() {
    vec2 uv = qt_TexCoord0;
    float px_y = uv.y * totalH;
    float p = progress;

    float fillY = totalH * (1.2 - p * 1.2);
    float x = uv.x;

    // Organic waviness
    float wave = noise(x * 6.0 + seed * 1.5) * 15.0;
    float wave2 = noise(x * 12.0 - seed * 2.0) * 8.0;

    // Paint drips that run AHEAD of the fill line
    float drip1 = exp(-pow((x - 0.15) * 8.0, 2.0)) * 30.0;
    float drip2 = exp(-pow((x - 0.5) * 10.0, 2.0)) * 22.0;
    float drip3 = exp(-pow((x - 0.82) * 9.0, 2.0)) * 26.0;

    float dripPhase = sin(p * 3.14159);
    float waveStrength = sin(p * 3.14159) * 0.9 + 0.1;
    float endFade = smoothstep(0.85, 1.0, p);
    waveStrength *= (1.0 - endFade);

    float totalWave = (wave + wave2) * waveStrength + (drip1 + drip2 + drip3) * dripPhase * (1.0 - endFade);

    // SUBTRACT — drips extend the fill UPWARD (ahead of the main line)
    float edgeY = fillY - totalWave;

    float alpha = smoothstep(edgeY + 3.0, edgeY - 2.0, px_y);
    alpha = 1.0 - alpha;

    fragColor = vec4(1.0, 1.0, 1.0, alpha) * qt_Opacity;
}
