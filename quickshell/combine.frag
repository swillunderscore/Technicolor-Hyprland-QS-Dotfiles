#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D src;
layout(binding = 2) uniform sampler2D mask;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};

void main() {
    vec4 s = texture(src, qt_TexCoord0);
    float m = texture(mask, qt_TexCoord0).a;
    fragColor = s * m * qt_Opacity;
}
