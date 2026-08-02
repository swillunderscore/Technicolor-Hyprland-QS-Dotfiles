#include "GlassRenderer.hpp"
#include "BuiltInPresets.hpp"
#include "Globals.hpp"

#include <array>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <drm_fourcc.h>
#include <GLES3/gl32.h>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>

namespace GlassRenderer {

static GLuint fbId(const SP<Render::IFramebuffer>& framebuffer) {
    // dynamic_cast returns null for anything that is not a GL framebuffer, and
    // calling ->getFBID() on that jumps through a garbage vtable — which shows
    // up in a crash report as a bare unresolved address with no symbol.
    if (!framebuffer)
        return 0;
    auto* gl = dynamic_cast<Render::GL::CGLFramebuffer*>(framebuffer.get());
    return gl ? gl->getFBID() : 0;
}

static void uploadThemeUniforms(const SResolveContext& ctx) {
    const auto& uniforms = g_pGlobalState->shaderManager.glassUniforms;
    const auto& glassShader = g_pGlobalState->shaderManager.glassShader;
    const auto& defaults = ctx.isDark ? DARK_THEME_DEFAULTS : LIGHT_THEME_DEFAULTS;

    glassShader->setUniformFloat(SHADER_BRIGHTNESS, resolvePresetFloat(ctx, &SPresetValues::brightness, &SOverridableConfig::brightness, defaults.brightness));
    glassShader->setUniformFloat(SHADER_CONTRAST,   resolvePresetFloat(ctx, &SPresetValues::contrast, &SOverridableConfig::contrast, defaults.contrast));
    glUniform1f(uniforms.saturation,                 resolvePresetFloat(ctx, &SPresetValues::saturation, &SOverridableConfig::saturation, defaults.saturation));
    glassShader->setUniformFloat(SHADER_VIBRANCY,   resolvePresetFloat(ctx, &SPresetValues::vibrancy, &SOverridableConfig::vibrancy, defaults.vibrancy));
    glUniform1f(uniforms.vibrancyDarkness,           resolvePresetFloat(ctx, &SPresetValues::vibrancyDarkness, &SOverridableConfig::vibrancyDarkness, defaults.vibrancyDarkness));

    glUniform1f(uniforms.adaptiveDim,   resolvePresetFloat(ctx, &SPresetValues::adaptiveDim, &SOverridableConfig::adaptiveDim, defaults.adaptiveDim));
    glUniform1f(uniforms.adaptiveBoost, resolvePresetFloat(ctx, &SPresetValues::adaptiveBoost, &SOverridableConfig::adaptiveBoost, defaults.adaptiveBoost));
}

void sampleBackground(SP<Render::IFramebuffer>& sampleFramebuffer, SP<Render::IFramebuffer> sourceFramebuffer,
                       CBox box, Vector2D& outPaddingRatio, int downscale) {
    if (!sourceFramebuffer)
        return;
    const int pad = SAMPLE_PADDING_PX;
    int fullWidth  = static_cast<int>(box.width) + 2 * pad;
    int fullHeight = static_cast<int>(box.height) + 2 * pad;

    // Allocate sample FBO at reduced resolution when blur is strong enough
    // to hide the lower resolution. Weak blur at half-res shows pixelation.
    int sampleWidth  = std::max(1, fullWidth / downscale);
    int sampleHeight = std::max(1, fullHeight / downscale);

    if (!sampleFramebuffer)
        sampleFramebuffer = g_pHyprRenderer->createFB("hyprglass-sample");

    if (sampleFramebuffer->m_size.x != sampleWidth || sampleFramebuffer->m_size.y != sampleHeight)
        sampleFramebuffer->alloc(sampleWidth, sampleHeight, sourceFramebuffer->m_drmFormat);

    int srcX0 = static_cast<int>(box.x) - pad;
    int srcX1 = static_cast<int>(box.x + box.width) + pad;
    int srcY0 = static_cast<int>(box.y) - pad;
    int srcY1 = static_cast<int>(box.y + box.height) + pad;

    // Clamp source coordinates to framebuffer bounds to avoid reading black/undefined pixels
    int framebufferWidth  = static_cast<int>(sourceFramebuffer->m_size.x);
    int framebufferHeight = static_cast<int>(sourceFramebuffer->m_size.y);

    // Destination coords in downscaled FBO space
    int dstX0 = 0, dstY0 = 0, dstX1 = sampleWidth, dstY1 = sampleHeight;

    // Scale destination adjustments proportionally for the downscaled FBO
    const float xScale = static_cast<float>(sampleWidth) / fullWidth;
    const float yScale = static_cast<float>(sampleHeight) / fullHeight;

    if (srcX0 < 0) { dstX0 += static_cast<int>(-srcX0 * xScale); srcX0 = 0; }
    if (srcY0 < 0) { dstY0 += static_cast<int>(-srcY0 * yScale); srcY0 = 0; }
    if (srcX1 > framebufferWidth)  { dstX1 -= static_cast<int>((srcX1 - framebufferWidth) * xScale);  srcX1 = framebufferWidth; }
    if (srcY1 > framebufferHeight) { dstY1 -= static_cast<int>((srcY1 - framebufferHeight) * yScale); srcY1 = framebufferHeight; }

    // Padding ratio is relative to the logical content area (resolution-independent)
    outPaddingRatio = Vector2D(
        static_cast<double>(pad) / fullWidth,
        static_cast<double>(pad) / fullHeight
    );

    // The render pass scissors each element to its damage region.
    // That scissor state leaks here and clips glBlitFramebuffer on the
    // DRAW framebuffer, causing partial writes and stale noise artifacts.
    g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);

    // Clear the sample FBO before blitting. Clamped regions (near edges)
    // would otherwise contain uninitialized GPU memory (pink artifacts).
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(sampleFramebuffer));
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(sourceFramebuffer));
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(sampleFramebuffer));
    glBlitFramebuffer(srcX0, srcY0, srcX1, srcY1,
                      dstX0, dstY0, dstX1, dstY1,
                      GL_COLOR_BUFFER_BIT, GL_LINEAR);
}

// ============================================================================
//  WAVE SIMULATION STEP
//
//  One explicit integration of d2h/dt2 = c^2*lap(h) per frame, ping-ponged
//  between two framebuffers. This is the state that makes the surface a
//  DYNAMICAL SYSTEM rather than a formula: a disturbance spreads at finite
//  speed, bounces off the edges, interferes with its own reflections, and dies
//  out. Sums of sines cannot do any of that, which is why every analytic
//  variant read as "patterned" no matter how it was tuned.
//
//  Small grid on purpose: 512x512 costs ~260k texels x 5 taps once per frame,
//  which is nothing beside the caustic pass running over every glass pixel.
// ============================================================================
void stepWaveSim() {
    static constexpr int SIM = 512;

    auto& shaderManager = g_pGlobalState->shaderManager;
    if (!shaderManager.isInitialized())
        return;

    // Called from the glass pass, which runs once PER GLASSED SURFACE — with
    // several glass windows up that would advance the simulation several times
    // per frame, so the water would speed up as you opened windows. Rate-limit
    // to one step per ~8ms so the surface evolves at the same pace regardless
    // of how much glass is on screen.
    // FIXED TIMESTEP, not a "has 8ms passed yet" gate.
    //
    // The old gate compared against a fixed 8ms while frames arrive every ~6ms
    // at 165Hz, so it ran on every other frame — and because frame timing
    // jitters, sometimes two frames in a row were skipped and sometimes two ran
    // back to back. The water genuinely sped up and slowed down: the "pulsing in
    // and out of full framerate", with no GPU load behind it.
    //
    // Instead accumulate real elapsed time and run however many WHOLE steps it
    // buys, so the simulation advances at a constant rate no matter how the
    // frames land — which also makes wave speed independent of refresh rate.
    int steps = 0;
    {
        using namespace std::chrono;
        static steady_clock::time_point last{};
        static double accum = 0.0;
        constexpr double STEP = 1.0 / 120.0;

        // SPEED BELOW 1x MUST NOT REDUCE THE STEP RATE.
        // Scaling the accumulator was the obvious move and it is wrong: at 0.1x
        // the simulation only advanced ~12 times a second, so the water was slow
        // AND choppy. Slow motion has to stay smooth.
        // Below 1x the step rate is held at the full 120/s and each step simply
        // advances the physics less (see waveSpeed). Above 1x the per-step speed
        // is already at the stability ceiling, so extra speed has to come from
        // running more steps.
        const auto& spcfg = g_pGlobalState->config;
        const double speed = spcfg.shimmerSpeed
            ? std::clamp(static_cast<double>(**spcfg.shimmerSpeed), 0.0, 4.0) : 1.0;
        const double speedMul = std::max(1.0, speed);

        const auto now = steady_clock::now();
        if (last.time_since_epoch().count() == 0)
            last = now;
        double dt = duration<double>(now - last).count();
        last = now;

        // Clamp catch-up. After a stall (VT switch, a heavy frame) accum can be
        // huge; replaying all of it at once both stutters and can destabilise
        // the integrator. Dropping the excess is the right trade.
        if (dt > 0.25) dt = 0.25;
        accum += dt * speedMul;

        steps = static_cast<int>(accum / STEP);
        if (steps <= 0)
            return;
        if (steps > 4) steps = 4;
        accum -= steps * STEP;
    }

    auto& fbA = g_pGlobalState->waveFb[0];
    auto& fbB = g_pGlobalState->waveFb[1];
    if (!fbA) fbA = g_pHyprRenderer->createFB("hyprglass-wave-a");
    if (!fbB) fbB = g_pHyprRenderer->createFB("hyprglass-wave-b");

    // HALF FLOAT IS REQUIRED, not a nicety. Wave heights here are ~0.01, and an
    // 8-bit UNORM quantises to 1/255 ~ 0.004 — two or three levels of signal.
    // The finite-difference Hessian then reads almost pure quantisation noise,
    // which showed up as isolated white specks instead of caustic filaments.
    // Half float is strongly preferred (8-bit quantises the wave to noise), but
    // it is NOT guaranteed to be a valid render target everywhere. If the alloc
    // does not produce a usable texture, fall back rather than sailing on with
    // null framebuffers — that is what turned a driver limitation into a
    // compositor SIGSEGV during ordinary rendering.
    static uint32_t fmt = DRM_FORMAT_ABGR16161616F;
    bool fresh = false;
    if (fbA->m_size.x != SIM || fbA->m_size.y != SIM) { fbA->alloc(SIM, SIM, fmt); fresh = true; }
    if (fbB->m_size.x != SIM || fbB->m_size.y != SIM) { fbB->alloc(SIM, SIM, fmt); fresh = true; }

    if (fresh && fmt == DRM_FORMAT_ABGR16161616F &&
        (!fbA->getTexture() || !fbB->getTexture() || fbId(fbA) == 0 || fbId(fbB) == 0)) {
        fmt = DRM_FORMAT_ABGR8888;
        fbA->alloc(SIM, SIM, fmt);
        fbB->alloc(SIM, SIM, fmt);
    }

    // Whatever happened above, refuse to proceed with an unusable target.
    if (!fbA->getTexture() || !fbB->getTexture() || fbId(fbA) == 0 || fbId(fbB) == 0)
        return;

    // A flat surface encodes as 0.5 in both channels, NOT zero: the height is
    // stored biased so a UNORM target can carry negative amplitude. Clearing to
    // black would mean "h = -0.5 everywhere", i.e. a giant step the first frame
    // would violently ring.
    if (fresh) {
        for (auto* fb : {&fbA, &fbB}) {
            glBindFramebuffer(GL_FRAMEBUFFER, fbId(*fb));
            glClearColor(0.5f, 0.5f, 0.0f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT);
        }
        g_pGlobalState->waveStepCount = 0;
    }

    GLint prevFbo = 0, prevVp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
    glGetIntegerv(GL_VIEWPORT, prevVp);


    static constexpr std::array<float, 9> FULLSCREEN_PROJECTION = {
        2.0f, 0.0f, 0.0f,
        0.0f, 2.0f, 0.0f,
       -1.0f,-1.0f, 1.0f,
    };

    const auto& u = shaderManager.waveSimUniforms;
    auto shader = g_pHyprOpenGL->useShader(shaderManager.waveSimShader);
    shader->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, FULLSCREEN_PROJECTION);
    shader->setUniformInt(SHADER_TEX, 3);

    glUniform2f(u.texelSize, 1.0f / SIM, 1.0f / SIM);
    // Courant condition: (c*dt/dx)^2 must stay below 0.5 or the explicit scheme
    // diverges into NaN within a few frames. 0.22 leaves comfortable margin.
    // Close to the 0.5 stability ceiling on purpose. At 0.22 a wavefront only
    // crossed ~22 texels between impulses, so the surface stayed a field of
    // small local dents instead of spread waves that interfere — which read as
    // grain rather than caustics.
    // Sub-1x speed lives HERE, as a smaller physical wave speed, so the step
    // rate — and therefore the smoothness — never drops. Stays under the 0.5
    // Courant ceiling at all times.
    {
        const auto& spc = g_pGlobalState->config;
        const float sp  = spc.shimmerSpeed
            ? std::clamp(static_cast<float>(**spc.shimmerSpeed), 0.0f, 4.0f) : 1.0f;
        glUniform1f(u.waveSpeed, 0.45f * std::min(sp, 1.0f));
    }
    // Just under 1: energy bleeds away, so agitation SETTLES instead of ringing
    // forever. This is what gives the "everyone got out of the pool" pacing.
    // Closer to 1: energy survives long enough for many disturbances to be in
    // flight at once and interfere, instead of one lonely wavefront at a time.
    // Still below 1, so agitation genuinely settles when impulses pause.
    // DAMPING MUST SCALE WITH SPEED TOO.
    // Below 1x the step rate is held constant (so slow stays smooth), which
    // means a step of wall-clock time buys less simulated time. Leaving damping
    // per-step therefore decays energy at the SAME real rate while the waves
    // crawl — at 0.002 they died essentially where they were born instead of
    // travelling slowly. Scaling the loss per step keeps decay tied to simulated
    // time, so slow water is slow in every respect rather than just sluggish.
    {
        const auto& dpc = g_pGlobalState->config;
        const float dsp = dpc.shimmerSpeed
            ? std::clamp(static_cast<float>(**dpc.shimmerSpeed), 0.0f, 4.0f) : 1.0f;
        const float sub = std::min(dsp, 1.0f);
        glUniform1f(u.damping, 1.0f - (1.0f - 0.9994f) * sub);
    }
    glUniform1f(u.bedVariation,
                g_pGlobalState->config.shimmerBed
                    ? static_cast<float>(**g_pGlobalState->config.shimmerBed) : 0.45f);

    // Occasional localized push. Deterministic LCG rather than a random device
    // so behaviour is reproducible when debugging a bad-looking frame.
    const auto& scfg = g_pGlobalState->config;
    const float agit = scfg.shimmerAgitation ? static_cast<float>(**scfg.shimmerAgitation) : 0.5f;
    const float chop = scfg.shimmerChop      ? static_cast<float>(**scfg.shimmerChop)      : 0.5f;
    // agitation 0..1 -> an event every 90..8 steps of SIMULATED time
    uint64_t every = static_cast<uint64_t>(90.0f - 82.0f * std::clamp(agit, 0.0f, 1.0f));
    // DELIBERATELY NOT scaled by speed. Tying it to simulated time was correct
    // in physics and wrong in use: at speed 0.002 it worked out to one
    // disturbance every ~6 MINUTES, so the surface just sat there. "Slow" is
    // wanted as slow MOTION, not as a slow world where nothing happens.
    // Keeping the rate in real time means low speed reads as a gently evolving
    // texture that is still fed, and "How often" stays an independent control.


    glBindVertexArray(shader->getUniformLocation(SHADER_SHADER_VAO));
    g_pHyprOpenGL->setViewport(0, 0, SIM, SIM);
    g_pHyprOpenGL->setCapStatus(GL_BLEND, false);

    for (int i = 0; i < steps; i++) {
        auto& s0 = g_pGlobalState->waveFb[g_pGlobalState->waveCurrent];
        auto& d0 = g_pGlobalState->waveFb[1 - g_pGlobalState->waveCurrent];
        if (!s0 || !s0->getTexture() || fbId(d0) == 0)
            break;

        // Impulses are decided per STEP, so their rate follows simulated time
        // rather than however many frames happened to get drawn.
        const uint64_t nn = g_pGlobalState->waveStepCount++;
        if (nn % std::max<uint64_t>(every, 2) == 0) {
            uint64_t r = nn * 6364136223846793005ULL + 1442695040888963407ULL;
            auto fr = [&](int sh) { return static_cast<float>((r >> sh) & 0xFFFF) / 65535.0f; };
            // Outer ring only: the shader samples just the middle of the sim, so
            // these are genuinely off-screen and their waves travel inward.
            const float ang = fr(16) * 6.2831853f;
            const float rr  = 0.40f + 0.09f * fr(32);
            const float rad = 0.075f - 0.050f * std::clamp(chop, 0.0f, 1.0f) + 0.020f * fr(40);
            glUniform4f(u.impulse, 0.5f + std::cos(ang) * rr, 0.5f + std::sin(ang) * rr,
                        rad, 0.10f + 0.16f * fr(48));
        } else {
            glUniform4f(u.impulse, 0.0f, 0.0f, 1.0f, 0.0f);
        }

        glBindFramebuffer(GL_FRAMEBUFFER, fbId(d0));
        // Unit 3, NOT unit 0: unit 0 is the glass shader's backdrop sampler, and
        // leaving the sim texture bound there makes the glass sample the water
        // height as if it were the wallpaper (observed: windows went flat grey).
        glActiveTexture(GL_TEXTURE3);
        s0->getTexture()->bind();
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        g_pGlobalState->waveCurrent = 1 - g_pGlobalState->waveCurrent;
    }

    g_pHyprOpenGL->setCapStatus(GL_BLEND, true);
    glBindVertexArray(0);
    glActiveTexture(GL_TEXTURE0);   // leave the active unit as the caller expects

    // Restore the caller's target and viewport. blurBackground() does the same;
    // leaving the sim's 512x512 viewport bound would scissor the glass pass down
    // to a corner of the screen.
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
    g_pHyprOpenGL->setViewport(0, 0, prevVp[2], prevVp[3]);

}

void blurBackground(SP<Render::IFramebuffer> sampleFramebuffer, float radius, int iterations,
                    GLuint callerFramebufferID, int viewportWidth, int viewportHeight) {
    auto& shaderManager = g_pGlobalState->shaderManager;
    if (!sampleFramebuffer || radius <= 0.0f || iterations <= 0 || !shaderManager.isInitialized())
        return;

    int width  = static_cast<int>(sampleFramebuffer->m_size.x);
    int height = static_cast<int>(sampleFramebuffer->m_size.y);

    auto& blurTempFramebuffer = g_pGlobalState->blurTempFramebuffer;
    if (!blurTempFramebuffer)
        blurTempFramebuffer = g_pHyprRenderer->createFB("hyprglass-blur-temp");

    if (blurTempFramebuffer->m_size.x != width || blurTempFramebuffer->m_size.y != height)
        blurTempFramebuffer->alloc(width, height, sampleFramebuffer->m_drmFormat);

    // Fullscreen quad projection: maps VAO positions [0,1] to clip space [-1,1]
    static constexpr std::array<float, 9> FULLSCREEN_PROJECTION = {
        2.0f, 0.0f, 0.0f,
        0.0f, 2.0f, 0.0f,
       -1.0f,-1.0f, 1.0f,
    };

    const auto& blurUniforms = shaderManager.blurUniforms;

    auto shader = g_pHyprOpenGL->useShader(shaderManager.blurShader);
    shader->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, FULLSCREEN_PROJECTION);
    shader->setUniformInt(SHADER_TEX, 0);
    glUniform1f(blurUniforms.radius, radius);
    glBindVertexArray(shader->getUniformLocation(SHADER_SHADER_VAO));
    g_pHyprOpenGL->setViewport(0, 0, width, height);
    glActiveTexture(GL_TEXTURE0);

    // Ping-pong at full resolution: sampleFramebuffer ↔ blurTempFramebuffer
    for (int iteration = 0; iteration < iterations; iteration++) {
        // Horizontal pass: sampleFramebuffer → blurTempFramebuffer
        glBindFramebuffer(GL_FRAMEBUFFER, fbId(blurTempFramebuffer));
        sampleFramebuffer->getTexture()->bind();
        glUniform2f(blurUniforms.direction, 1.0f / width, 0.0f);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        // Vertical pass: blurTempFramebuffer → sampleFramebuffer
        glBindFramebuffer(GL_FRAMEBUFFER, fbId(sampleFramebuffer));
        blurTempFramebuffer->getTexture()->bind();
        glUniform2f(blurUniforms.direction, 0.0f, 1.0f / height);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    // Restore caller's GL state without querying (avoids pipeline stalls)
    glBindFramebuffer(GL_FRAMEBUFFER, callerFramebufferID);
    glBindVertexArray(0);
    g_pHyprOpenGL->setViewport(0, 0, viewportWidth, viewportHeight);
}

void applyGlassEffect(SP<Render::IFramebuffer> sampleFramebuffer, SP<Render::IFramebuffer> targetFramebuffer,
                       CBox& rawBox, CBox& transformedBox,
                       float alpha, float cornerRadius, float roundingPower,
                       const Vector2D& paddingRatio, const SResolveContext& resolveContext,
                       const SMaskInfo* mask) {
    if (!sampleFramebuffer || !targetFramebuffer)
        return;

    auto& shaderManager  = g_pGlobalState->shaderManager;
    const auto& uniforms = shaderManager.glassUniforms;

    const auto transform = Math::wlTransformToHyprutils(
        Math::invertTransform(g_pHyprRenderer->m_renderData.pMonitor->m_transform));

    Mat3x3 glMatrix = g_pHyprRenderer->projectBoxToTarget(rawBox, transform);
    auto texture    = sampleFramebuffer->getTexture();

    glMatrix.transpose();

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(targetFramebuffer));
    glActiveTexture(GL_TEXTURE0);
    texture->bind();

    // Layers only: bind the temp FBO texture (rendered surface) on texture unit 1.
    // The shader samples it to mask glass to visible content and composite surface on top.
    // Windows pass mask=nullptr so this block is skipped.
    if (mask && mask->textureId != 0) {
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(mask->target, mask->textureId);
        glActiveTexture(GL_TEXTURE0);
    }

    // Advance the water BEFORE binding the glass program: stepWaveSim binds its
    // own shader/FBO/viewport, so it must not run between useShader() and the
    // glass uniform uploads.
    {
        const auto& wcfg = g_pGlobalState->config;
        const bool wOn = wcfg.shimmerEnabled && **wcfg.shimmerEnabled != 0
                      && wcfg.shimmerIntensity && **wcfg.shimmerIntensity > 0.0;
        if (wOn)
            stepWaveSim();
    }

    auto shader = g_pHyprOpenGL->useShader(shaderManager.glassShader);

    shader->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, glMatrix.getMatrix());
    shader->setUniformInt(SHADER_TEX, 0);

    const auto fullSize = Vector2D(transformedBox.width, transformedBox.height);
    shader->setUniformFloat2(SHADER_FULL_SIZE,
        static_cast<float>(fullSize.x), static_cast<float>(fullSize.y));

    glUniform1f(uniforms.refractionStrength,  resolvePresetFloat(resolveContext, &SPresetValues::refractionStrength, &SOverridableConfig::refractionStrength));
    glUniform1f(uniforms.chromaticAberration, resolvePresetFloat(resolveContext, &SPresetValues::chromaticAberration, &SOverridableConfig::chromaticAberration));
    glUniform1f(uniforms.fresnelStrength,     resolvePresetFloat(resolveContext, &SPresetValues::fresnelStrength, &SOverridableConfig::fresnelStrength));
    glUniform1f(uniforms.specularStrength,    resolvePresetFloat(resolveContext, &SPresetValues::specularStrength, &SOverridableConfig::specularStrength));
    glUniform1f(uniforms.glassOpacity,        resolvePresetFloat(resolveContext, &SPresetValues::glassOpacity, &SOverridableConfig::glassOpacity) * alpha);
    glUniform1f(uniforms.edgeThickness,       resolvePresetFloat(resolveContext, &SPresetValues::edgeThickness, &SOverridableConfig::edgeThickness));
    glUniform1f(uniforms.lensDistortion,      resolvePresetFloat(resolveContext, &SPresetValues::lensDistortion, &SOverridableConfig::lensDistortion));

    // ── Animated caustics ───────────────────────────────────────────────────
    // Global rather than per-preset on purpose: this is a "does the desktop
    // move" decision, not a per-window look, and the effects governor toggles
    // it as one switch. Intensity is forced to exactly 0 when disabled so the
    // shader's early-out skips the wave sum entirely — a disabled shimmer must
    // cost nothing, not merely a little.
    //
    // The clock is monotonic seconds, wrapped at 3600 before reaching the GPU.
    // A float32 holding uptime-in-seconds loses sub-frame resolution after a
    // few days of uptime (mantissa runs out), and the wave field would visibly
    // quantise on a machine that is never rebooted — which is this one.
    {
        const auto& cfg = g_pGlobalState->config;
        const bool  on  = cfg.shimmerEnabled && **cfg.shimmerEnabled != 0;
        const float intensity = on && cfg.shimmerIntensity ? static_cast<float>(**cfg.shimmerIntensity) : 0.0f;
        const float speed     = cfg.shimmerSpeed ? static_cast<float>(**cfg.shimmerSpeed) : 0.35f;
        const float scale     = cfg.shimmerScale ? static_cast<float>(**cfg.shimmerScale) : 1.0f;

        float t = 0.0f;
        if (intensity > 0.0f) {
            const auto now = std::chrono::steady_clock::now().time_since_epoch();
            const auto ms  = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
            t = static_cast<float>(ms % 3600000LL) / 1000.0f;
        }
        glUniform1f(uniforms.uTime,            t);
        glUniform1f(uniforms.shimmerIntensity, intensity);
        glUniform1f(uniforms.shimmerSpeed,     speed);
        glUniform1f(uniforms.shimmerScale,     scale);
        glUniform1f(uniforms.shimmerDepth,
                    cfg.shimmerDepth ? static_cast<float>(**cfg.shimmerDepth) : 1.0f);
        glUniform1i(uniforms.shimmerLightFromBackdrop,
                    (cfg.shimmerLightFromBackdrop && **cfg.shimmerLightFromBackdrop != 0) ? 1 : 0);

        // Bind the CURRENT surface. The simulation itself is stepped before the
        // glass shader is bound (see above) — stepping it here would switch the
        // active program mid-uniform-upload and every glass uniform after this
        // point would be written to the wrong program.
        if (intensity > 0.0f) {
            auto& wfb = g_pGlobalState->waveFb[g_pGlobalState->waveCurrent];
            if (wfb && wfb->getTexture()) {
                glActiveTexture(GL_TEXTURE2);
                wfb->getTexture()->bind();
                glActiveTexture(GL_TEXTURE0);
                glUniform1i(uniforms.waveTex, 2);
            }
        }
    }

    uploadThemeUniforms(resolveContext);

    const int64_t tintColorValue = resolvePresetInt(resolveContext, &SPresetValues::tintColor, &SOverridableConfig::tintColor);
    glUniform3f(uniforms.tintColor,
        static_cast<float>((tintColorValue >> 24) & 0xFF) / 255.0f,
        static_cast<float>((tintColorValue >> 16) & 0xFF) / 255.0f,
        static_cast<float>((tintColorValue >> 8) & 0xFF) / 255.0f);
    glUniform1f(uniforms.tintAlpha,
        static_cast<float>(tintColorValue & 0xFF) / 255.0f);

    glUniform2f(uniforms.uvPadding,
        static_cast<float>(paddingRatio.x),
        static_cast<float>(paddingRatio.y));

    // Layers only: enable mask and provide UV mapping from the glass quad into
    // the monitor-sized temp FBO. Windows use useMask=0 (no masking).
    if (mask && mask->textureId != 0) {
        glUniform1i(uniforms.useMask, 1);
        glUniform1i(uniforms.maskTex, 1);
        glUniform2f(uniforms.maskUVOffset,
            static_cast<float>(mask->uvOffset.x),
            static_cast<float>(mask->uvOffset.y));
        glUniform2f(uniforms.maskUVScale,
            static_cast<float>(mask->uvScale.x),
            static_cast<float>(mask->uvScale.y));
        glUniform1f(uniforms.maskAlphaThreshold, mask->alphaThreshold);
    } else {
        glUniform1i(uniforms.useMask, 0);
        glUniform1f(uniforms.maskAlphaThreshold, 0.001f);
    }

    shader->setUniformFloat(SHADER_RADIUS, cornerRadius);
    shader->setUniformFloat(SHADER_ROUNDING_POWER, roundingPower);

    glBindVertexArray(shader->getUniformLocation(SHADER_SHADER_VAO));
    g_pHyprOpenGL->scissor(rawBox);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    g_pHyprOpenGL->scissor(nullptr);
}

} // namespace GlassRenderer
