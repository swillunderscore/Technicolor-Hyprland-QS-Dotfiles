#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D source;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float tintR;
    float tintG;
    float tintB;
};

void main() {
    vec4 tex = texture(source, qt_TexCoord0);
    float lum = dot(tex.rgb, vec3(0.299, 0.587, 0.114));

    vec3 tint = vec3(tintR, tintG, tintB);

    // ── Desaturate toward target ──
    float tintLum = dot(tint, vec3(0.299, 0.587, 0.114));
    float sat = 0.5;  // 0 = fully gray, 1 = original saturation
    vec3 desat = mix(vec3(tintLum), tint, sat);

    // ── Normalize so every color hits the same brightness ──
    float maxC = max(desat.r, max(desat.g, desat.b));
    float targetDark = 0.15;  // brightness of darkest icon parts
    float targetBright = 0.95; // brightness of lightest icon parts
    float target = mix(targetDark, targetBright, lum);
    float s = maxC > 0.01 ? target / maxC : 1.0;
    vec3 result = desat * s * tex.a;

    fragColor = vec4(result, tex.a) * qt_Opacity;
}
