#include "ShaderManager.hpp"
#include "Globals.hpp"
#include "Shaders.hpp"

#include <GLES3/gl32.h>
#include <hyprland/src/helpers/Color.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/OpenGL.hpp>

std::string CShaderManager::loadShaderSource(const char* fileName) {
    if (SHADERS.contains(fileName))
        return SHADERS.at(fileName);

    const std::string message = std::format("[{}] Failed to load shader: {}", PLUGIN_NAME, fileName);
    HyprlandAPI::addNotification(PHANDLE, message, CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
    throw std::runtime_error(message);
}

bool CShaderManager::compileGlassShader() {
    if (!glassShader->createProgram(
            g_pHyprOpenGL->m_shaders->TEXVERTSRC,
            loadShaderSource("liquidglass.frag"),
            true
        )) {
        HyprlandAPI::addNotification(PHANDLE,
            std::format("[{}] Failed to compile glass shader", PLUGIN_NAME),
            CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        return false;
    }

    const auto program = glassShader->program();

    glassUniforms.refractionStrength  = glGetUniformLocation(program, "refractionStrength");
    glassUniforms.uTime               = glGetUniformLocation(program, "uTime");
    glassUniforms.shimmerIntensity    = glGetUniformLocation(program, "shimmerIntensity");
    glassUniforms.shimmerSpeed        = glGetUniformLocation(program, "shimmerSpeed");
    glassUniforms.shimmerScale        = glGetUniformLocation(program, "shimmerScale");
    glassUniforms.shimmerLightFromBackdrop = glGetUniformLocation(program, "shimmerLightFromBackdrop");
    glassUniforms.waveTex                  = glGetUniformLocation(program, "waveTex");
    glassUniforms.shimmerDepth             = glGetUniformLocation(program, "shimmerDepth");
    glassUniforms.waveSubFrac              = glGetUniformLocation(program, "waveSubFrac");
    glassUniforms.waveBias           = glGetUniformLocation(program, "waveBias");
    glassUniforms.shimmerMurk        = glGetUniformLocation(program, "shimmerMurk");
    glassUniforms.shimmerAbsorption  = glGetUniformLocation(program, "shimmerAbsorption");
    glassUniforms.chromaticAberration = glGetUniformLocation(program, "chromaticAberration");
    glassUniforms.fresnelStrength     = glGetUniformLocation(program, "fresnelStrength");
    glassUniforms.specularStrength    = glGetUniformLocation(program, "specularStrength");
    glassUniforms.glassOpacity        = glGetUniformLocation(program, "glassOpacity");
    glassUniforms.edgeThickness       = glGetUniformLocation(program, "edgeThickness");
    glassUniforms.uvPadding           = glGetUniformLocation(program, "uvPadding");
    glassUniforms.tintColor           = glGetUniformLocation(program, "tintColor");
    glassUniforms.tintAlpha           = glGetUniformLocation(program, "tintAlpha");
    glassUniforms.lensDistortion      = glGetUniformLocation(program, "lensDistortion");
    glassUniforms.saturation          = glGetUniformLocation(program, "saturation");
    glassUniforms.vibrancyDarkness    = glGetUniformLocation(program, "vibrancyDarkness");
    glassUniforms.adaptiveDim         = glGetUniformLocation(program, "adaptiveDim");
    glassUniforms.adaptiveBoost       = glGetUniformLocation(program, "adaptiveBoost");
    glassUniforms.maskTex             = glGetUniformLocation(program, "maskTex");
    glassUniforms.useMask             = glGetUniformLocation(program, "useMask");
    glassUniforms.maskUVOffset        = glGetUniformLocation(program, "maskUVOffset");
    glassUniforms.maskUVScale         = glGetUniformLocation(program, "maskUVScale");
    glassUniforms.maskAlphaThreshold  = glGetUniformLocation(program, "maskAlphaThreshold");

    return true;
}

bool CShaderManager::compileBlurShader() {
    if (!blurShader->createProgram(
            g_pHyprOpenGL->m_shaders->TEXVERTSRC,
            loadShaderSource("gaussianblur.frag"),
            true
        )) {
        HyprlandAPI::addNotification(PHANDLE,
            std::format("[{}] Failed to compile blur shader", PLUGIN_NAME),
            CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        return false;
    }

    const auto program = blurShader->program();

    blurUniforms.direction = glGetUniformLocation(program, "direction");
    blurUniforms.radius    = glGetUniformLocation(program, "blurRadius");

    return true;
}

bool CShaderManager::compileWaveSimShader() {
    if (!waveSimShader->createProgram(
            g_pHyprOpenGL->m_shaders->TEXVERTSRC,
            loadShaderSource("wavesim.frag"),
            true
        )) {
        HyprlandAPI::addNotification(PHANDLE,
            std::format("[{}] Failed to compile wave sim shader", PLUGIN_NAME),
            CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        return false;
    }

    const auto program = waveSimShader->program();

    waveSimUniforms.texelSize = glGetUniformLocation(program, "texelSize");
    waveSimUniforms.waveSpeed = glGetUniformLocation(program, "waveSpeed");
    waveSimUniforms.damping   = glGetUniformLocation(program, "damping");
    waveSimUniforms.impulse   = glGetUniformLocation(program, "impulse");
    waveSimUniforms.bedVariation = glGetUniformLocation(program, "bedVariation");
    waveSimUniforms.viscosity    = glGetUniformLocation(program, "viscosity");
    waveSimUniforms.maxSpeed     = glGetUniformLocation(program, "maxSpeed");
    waveSimUniforms.hBias        = glGetUniformLocation(program, "hBias");

    return true;
}

void CShaderManager::initializeIfNeeded() {
    if (m_initialized)
        return;

    if (!compileGlassShader())
        return;

    if (!compileBlurShader())
        return;

    if (!compileWaveSimShader())
        return;

    m_initialized = true;
}

void CShaderManager::destroy() noexcept {
    glassShader->destroy();
    blurShader->destroy();
    m_initialized = false;
}
