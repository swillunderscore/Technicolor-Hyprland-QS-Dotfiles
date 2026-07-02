#version 440
// Wallpaper-transition reveal mask (WallpaperFade.qml). `source` is the NEW
// wallpaper's current animation frame at NATIVE resolution (nearest-filtered);
// `fadeMap` holds each pixel's reveal rank (0 = fades first, 1 = last),
// already in screen aspect. Per-pixel alpha reproduces wallpaper-transition.py
// exactly: rank spread over [0, 1-fadeFrac], each pixel cross-fading for
// fadeFrac of the total, driven by a smoothstep-eased frontier.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D fadeMap;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;    // 0..1 linear reveal time (eased here, not in QML)
    float fadeFrac;    // FADE_DURATION / TOTAL_DURATION
    float imgAspect;   // NEW's native w/h
    float scrAspect;   // this screen's w/h
};

void main() {
    // Cover-crop: sample the centered sub-rect of NEW that awww's
    // `--resize crop` (and Image.PreserveAspectCrop) would show.
    vec2 s = (imgAspect > scrAspect)
        ? vec2(scrAspect / imgAspect, 1.0)
        : vec2(1.0, imgAspect / scrAspect);
    vec2 uv = (qt_TexCoord0 - 0.5) * s + 0.5;

    // Post-reveal linger (fully opaque, waiting for the awww handoff): skip
    // the fadeMap sample — uniform branch, whole draw takes the cheap path.
    if (progress >= 1.0) {
        fragColor = texture(source, uv) * qt_Opacity;
        return;
    }

    float p = clamp(progress, 0.0, 1.0);
    p = p * p * (3.0 - 2.0 * p);                       // frontier ease
    float start = texture(fadeMap, qt_TexCoord0).r * (1.0 - fadeFrac);
    float a = clamp((p - start) / fadeFrac, 0.0, 1.0); // per-pixel cross-fade

    fragColor = texture(source, uv) * (a * qt_Opacity); // premultiplied
}
