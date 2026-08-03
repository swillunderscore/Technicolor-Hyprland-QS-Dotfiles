#include "GlassRenderer.hpp"
#include "BuiltInPresets.hpp"
#include "Globals.hpp"

#include <array>
#include <cstdint>
#include <unordered_map>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <drm_fourcc.h>
#include <cstdarg>
#include <unistd.h>
#include <GLES3/gl32.h>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>

namespace GlassRenderer {

// TEMPORARY diagnostic logging (enabled by HYPRWATER_DEBUG_LOG in the
// environment): timestamps of glass renders, window positions, sim steps and
// trail renders, to correlate against frame captures. Remove after the
// low-speed tick hunt.
static FILE* dbgLog() {
    static FILE* f = [] {
        if (const char* p = getenv("HYPRWATER_DEBUG_LOG"))
            return fopen(p, "w");
        // A live session cannot be handed a new environment variable, so a
        // trigger file works too: touch /tmp/hyprwater-debug, reload the
        // plugin, read /tmp/hyprwater-debug.log.
        if (access("/tmp/hyprwater-debug", F_OK) == 0)
            return fopen("/tmp/hyprwater-debug.log", "w");
        return static_cast<FILE*>(nullptr);
    }();
    return f;
}
static double dbgNow() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}
#define DBG(...) do { if (FILE* _f = dbgLog()) { fprintf(_f, __VA_ARGS__); fflush(_f); } } while (0)

// Same sink, callable from the other translation units (timestamp prefixed).
void DBG_LOG(const char* fmt, ...) {
    FILE* f = dbgLog();
    if (!f)
        return;
    fprintf(f, "%.4f ", dbgNow());
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fflush(f);
}

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
        sampleFramebuffer = g_pHyprRenderer->createFB("hyprwater-sample");

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
// Push a finished stroke segment into the pending ring. A FULL ring REFUSES
// the push (returns false) and the caller keeps extending its live segment
// instead: a lengthening chord is CONTINUOUS, so trail fidelity degrades
// smoothly under saturation. The earlier policy merged the two oldest
// segments into a chord — a discrete geometry snap that fired many times a
// second during a hard whip at ultra-low sim speed (one absorption step per
// SECOND at speed 0.002), which was exactly the residual jitter the user
// kept seeing on window and mouse drags while clicks stayed smooth.
static bool pushPendStroke(const SGlobalState::SDrag& s) {
    auto& st = *g_pGlobalState;
    if (st.pendLen == SGlobalState::PEND_RING)
        return false;
    st.pendRing[(st.pendHead + st.pendLen) % SGlobalState::PEND_RING] = s;
    st.pendLen++;
    return true;
}

// Shared by the wave step and the fluid passes: draw one quad over the whole
// target, no window geometry involved.
static constexpr std::array<float, 9> FULLSCREEN_PROJECTION = {
    2.0f, 0.0f, 0.0f,
    0.0f, 2.0f, 0.0f,
   -1.0f,-1.0f, 1.0f,
};

// ============================================================================
//  CURRENTS — one Stable Fluids step (Stam 1999): advect, force, project.
//
//  The wave sim above this is a SCALAR height field; curl of a scalar is
//  undefined, so it structurally cannot hold an eddy — the user's whirlpools
//  need an actual velocity field. This maintains one at low resolution
//  (velocity fields are smooth; the projection smooths them further) and the
//  wave step samples it bilinearly, so currents bend and carry the waves.
//
//  Deliberately NOT moving solid boundaries: window edges inject FORCE into
//  one shared sheet (they are permeable — windows contain nothing, overlapping
//  windows are two viewports onto the same fluid). A force can move water but
//  never create it; the pressure projection enforcing div v = 0 IS the mass
//  conservation that makes this safe. Real moving walls would need solid-fluid
//  coupling and can trap and compress fluid — that case is intentionally out.
//
//  Cost: (2 + 24 + 1) draws over 256^2 per step ≈ 2M texel updates, against a
//  caustic pass doing ~18 BILLION reads/sec. Invisible. Verified against a
//  numpy prototype first: vortex dipole forms behind a drag, a wave packet is
//  carried at the current's speed, and 4000 steps stay bounded.
// ============================================================================
static constexpr int FLUID_JACOBI = 24;
static constexpr int SIM          = 1024;   // height-field grid

// Grid size comes from shimmer:currents_resolution (default 512). At 512 the
// desktop spans ~107 fluid texels, a typical window ~27 — swirls small enough
// to read as corner turbulence rather than one window-sized smear. The FBO
// alloc below compares against this every step, so changing the key live just
// reallocates and restarts the field from still water.
static int fluidRes() {
    const auto& cfg = g_pGlobalState->config;
    const int64_t r = cfg.shimmerCurrentsRes ? **cfg.shimmerCurrentsRes : 512;
    return static_cast<int>(std::clamp<int64_t>(r, 64, 2048));
}

static void bindSimTexture(int unit, const SP<Render::IFramebuffer>& fb) {
    // Explicit filtering EVERY bind, same lesson as the wave texture: nothing
    // else sets these, and NEAREST prints the grid. CLAMP keeps the boundary
    // from wrapping to the far side. LINEAR is exact at texel centers, so the
    // whole-texel offsets of the derivative stencils are unaffected.
    glActiveTexture(GL_TEXTURE0 + unit);
    fb->getTexture()->bind();
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

static void stepFluidAdvect(const SGlobalState::SDrag& dragNow, const int res, const float dt) {
    auto& st = *g_pGlobalState;
    const auto& fu = st.shaderManager.fluidUniforms;
    const float texel = 1.0f / res;

    g_pHyprOpenGL->setViewport(0, 0, res, res);

    // 1) Advect the velocity by itself + inject the drag's momentum + bleed.
    {
        auto sh = g_pHyprOpenGL->useShader(st.shaderManager.fluidAdvectShader);
        sh->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, FULLSCREEN_PROJECTION);
        sh->setUniformInt(SHADER_TEX, 3);
        glBindVertexArray(sh->getUniformLocation(SHADER_SHADER_VAO));
        glUniform1f(fu.aDt, dt);
        // ~4 s momentum half-life on top of what the projection and the
        // semi-Lagrangian interpolation already dissipate: eddies outlive the
        // drag that made them by a few seconds, then the water goes still.
        // Per-step retention follows the sub-step size so the half-life is a
        // property of simulated time, not of how finely it is sliced.
        glUniform1f(fu.aDissipation, std::pow(0.998f, dt * 120.0f));
        if (dragNow.amount > 1e-5f) {
            // Same spot, direction and window-width radius as the height
            // dipole this step will fire — the dipole is the bow wave, this is
            // the momentum the hull leaves in the water. The dipole amplitude
            // (~0.002-0.05 per spend) maps to a peak velocity kick of
            // ~0.02-0.6 uv/s, the range the prototype showed makes visible
            // swirls without outrunning the advection.
            glUniform2f(fu.aForceDir, dragNow.dx, dragNow.dy);
            glUniform4f(fu.aForce, dragNow.x, dragNow.y,
                        dragNow.r > 0.0f ? dragNow.r : 0.045f,
                        dragNow.amount * 12.0f);
        } else {
            glUniform2f(fu.aForceDir, 0.0f, 0.0f);
            glUniform4f(fu.aForce, 0.0f, 0.0f, 1.0f, 0.0f);
        }
        glBindFramebuffer(GL_FRAMEBUFFER, fbId(st.fluidVelFb[1 - st.fluidVelCurrent]));
        bindSimTexture(3, st.fluidVelFb[st.fluidVelCurrent]);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        st.fluidVelCurrent = 1 - st.fluidVelCurrent;
    }

    // 2) How much each cell is now being pumped or drained.
    {
        auto sh = g_pHyprOpenGL->useShader(st.shaderManager.fluidDivergenceShader);
        sh->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, FULLSCREEN_PROJECTION);
        sh->setUniformInt(SHADER_TEX, 3);
        glBindVertexArray(sh->getUniformLocation(SHADER_SHADER_VAO));
        glUniform2f(fu.dTexelSize, texel, texel);
        glBindFramebuffer(GL_FRAMEBUFFER, fbId(st.fluidDivFb));
        bindSimTexture(3, st.fluidVelFb[st.fluidVelCurrent]);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    // 3+4) The pressure solve is QUEUED, not run. The 24 Jacobi iterations +
    // gradient are a burst of GPU work that, injected into one frame on top
    // of an already-heavy glass pass, blew the frame deadline on the real
    // desktop — one dropped frame per sim step, which at low sim speed reads
    // as the render ticking at exactly the step rate (and currents-off being
    // perfectly smooth, since only currents carry the burst). runFluidSolve
    // spends the queue: inline when steps arrive at frame rate, a few
    // iterations per frame when steps are slower than frames.
    st.fluidJacobiLeft = FLUID_JACOBI;
    st.fluidNeedGrad   = true;
}

// Spend up to maxIters of the queued pressure solve, finishing with the
// gradient subtraction when the last iteration lands. q is warm-started from
// the previous step, so iterations compound instead of starting over. Until
// the gradient fires, fluidVelCurrent holds the post-advect velocity —
// slightly divergent, but fresher than the previous projected field and only
// on screen for the few frames a spread solve takes. Assumes blend is off.
static void runFluidSolve(const int res, const int maxIters) {
    auto& st = *g_pGlobalState;
    const auto& fu = st.shaderManager.fluidUniforms;
    const float texel = 1.0f / res;

    g_pHyprOpenGL->setViewport(0, 0, res, res);

    if (st.fluidJacobiLeft > 0) {
        auto sh = g_pHyprOpenGL->useShader(st.shaderManager.fluidJacobiShader);
        sh->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, FULLSCREEN_PROJECTION);
        sh->setUniformInt(SHADER_TEX, 3);
        glBindVertexArray(sh->getUniformLocation(SHADER_SHADER_VAO));
        glUniform2f(fu.jTexelSize, texel, texel);
        glUniform1i(fu.jDivTex, 4);
        bindSimTexture(4, st.fluidDivFb);
        const int n = std::min(st.fluidJacobiLeft, maxIters);
        for (int j = 0; j < n; j++) {
            glBindFramebuffer(GL_FRAMEBUFFER, fbId(st.fluidPrsFb[1 - st.fluidPrsCurrent]));
            bindSimTexture(3, st.fluidPrsFb[st.fluidPrsCurrent]);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            st.fluidPrsCurrent = 1 - st.fluidPrsCurrent;
        }
        st.fluidJacobiLeft -= n;
    }

    // Keep only the swirl — once the iterations are all spent.
    if (st.fluidJacobiLeft == 0 && st.fluidNeedGrad) {
        auto sh = g_pHyprOpenGL->useShader(st.shaderManager.fluidGradientShader);
        sh->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, FULLSCREEN_PROJECTION);
        sh->setUniformInt(SHADER_TEX, 3);
        glBindVertexArray(sh->getUniformLocation(SHADER_SHADER_VAO));
        glUniform2f(fu.gTexelSize, texel, texel);
        glUniform1i(fu.gPrsTex, 4);
        glBindFramebuffer(GL_FRAMEBUFFER, fbId(st.fluidVelFb[1 - st.fluidVelCurrent]));
        bindSimTexture(3, st.fluidVelFb[st.fluidVelCurrent]);
        bindSimTexture(4, st.fluidPrsFb[st.fluidPrsCurrent]);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        st.fluidVelCurrent = 1 - st.fluidVelCurrent;
        st.fluidNeedGrad = false;
    }
}

// Per-FRAME slice of a spread-out solve, called from the glass pass next to
// the trail render. 6 iterations a frame retires a step's 24 in ~4 frames —
// far inside the ≥1 s between steps at the speeds where spreading engages.
static void runFluidBudgetFrame() {
    if (!g_pGlobalState)
        return;
    auto& st = *g_pGlobalState;
    if (st.fluidJacobiLeft <= 0 && !st.fluidNeedGrad)
        return;
    if (!st.fluidDivFb || !st.fluidVelFb[0] || !st.fluidVelFb[1]
        || !st.fluidPrsFb[0] || !st.fluidPrsFb[1] || fbId(st.fluidDivFb) == 0)
        return;
    // One slice per frame, not per glassed surface — same guard as the trail.
    static std::chrono::steady_clock::time_point lastSlice{};
    const auto now = std::chrono::steady_clock::now();
    if (now - lastSlice < std::chrono::milliseconds(3))
        return;
    lastSlice = now;

    GLint prevFbo = 0, prevVp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
    glGetIntegerv(GL_VIEWPORT, prevVp);
    g_pHyprOpenGL->setCapStatus(GL_BLEND, false);

    runFluidSolve(static_cast<int>(st.fluidDivFb->m_size.x), 6);
    DBG("%.4f FLUIDB left=%d grad=%d\n", dbgNow(), st.fluidJacobiLeft,
        static_cast<int>(st.fluidNeedGrad));

    g_pHyprOpenGL->setCapStatus(GL_BLEND, true);
    glBindVertexArray(0);
    glActiveTexture(GL_TEXTURE0);
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
    g_pHyprOpenGL->setViewport(0, 0, prevVp[2], prevVp[3]);
}

// A click is a TAP on the surface: a small round press-in at the cursor,
// spent by the next simulation step. Strength rides the same mouse slider as
// the trailing wake — the weight of the fingertip governs both — so there is
// no separate toggle to find; slider at zero lifts the whole hand off.
// Called from the mouse-button listener in main.cpp on every press.
void queueClickSplash() {
    if (!g_pGlobalState)
        return;
    const auto& cfg = g_pGlobalState->config;
    const bool on = cfg.shimmerEnabled && **cfg.shimmerEnabled != 0;
    const float mforce = cfg.shimmerMouse
                       ? std::clamp(static_cast<float>(**cfg.shimmerMouse), 0.0f, 1.0f) : 0.0f;
    if (!on || mforce <= 0.001f || !g_pInputManager)
        return;
    const Vector2D cur  = g_pInputManager->getMouseCoordsInternal();
    const auto&    desk = g_pGlobalState->deskMax;
    const float    sc   = cfg.shimmerScale ? static_cast<float>(**cfg.shimmerScale) : 1.0f;
    const Vector2D g{(cur.x - desk.x * 0.5) / std::max(desk.x, 1.0),
                     (cur.y - desk.y * 0.5) / std::max(desk.x, 1.0)};
    auto& ck = g_pGlobalState->click;
    ck.x  = static_cast<float>(0.5 + g.x * 0.85 * sc * 2.0 * 0.105);
    ck.y  = static_cast<float>(0.5 + g.y * 0.85 * sc * 2.0 * 0.105);
    ck.dx = 0.0f;   // zero direction = the shader's ROUND splash, not a dipole
    ck.dy = 0.0f;
    // A touch wider than the wake radius: short wavelengths carry the square
    // grid's residual anisotropy (the faint 4-cornered ring the user spotted)
    // and a broader tap simply emits fewer of them.
    ck.r  = 0.022f;
    // Rapid clicks stack a little, capped: a drum-roll is a bigger splash,
    // not an unbounded one. Mostly slider-proportional with only a whisper of
    // a floor — the first cut had a fat constant base, which at a low slider
    // made every click dwarf the wake it was supposed to accompany.
    ck.amount = std::min(ck.amount + 0.012f + 0.06f * mforce, 0.20f);
}

// Sum the analytic stroke trail into its own texture, once per FRAME — the
// trail moves with the window every frame, unlike the sim. ~26 capsules per
// texel evaluated ONCE here beats evaluating them inside all ~26 stencil taps
// of every caustic pixel, and puts no ceiling on how finely a whip is traced.
void renderTrailTex() {
    auto& st = *g_pGlobalState;
    auto& sm = st.shaderManager;
    if (!sm.isInitialized())
        return;

    using namespace std::chrono;
    static steady_clock::time_point last{};
    const auto now = steady_clock::now();
    if (duration_cast<microseconds>(now - last).count() < 3000)
        return;   // several glassed surfaces per frame; render once
    last = now;

    if (!st.trailFb)
        st.trailFb = g_pHyprRenderer->createFB("hyprwater-trail");
    static uint32_t fmt = DRM_FORMAT_ABGR16161616F;
    if (st.trailFb->m_size.x != SIM || st.trailFb->m_size.y != SIM) {
        st.trailFb->alloc(SIM, SIM, fmt);
        if (!st.trailFb->getTexture() || fbId(st.trailFb) == 0) {
            // UNORM fallback loses the trough half (no negatives) — degraded
            // but functional, and matches the sim's own fallback policy.
            fmt = DRM_FORMAT_ABGR8888;
            st.trailFb->alloc(SIM, SIM, fmt);
        }
    }
    if (!st.trailFb->getTexture() || fbId(st.trailFb) == 0)
        return;

    GLint prevFbo = 0, prevVp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
    glGetIntegerv(GL_VIEWPORT, prevVp);

    float seg[104] = {0}, par[104] = {0};
    int   n = 0;
    auto put = [&](const SGlobalState::SDrag& s, float wScale) {
        if (n >= 26 || s.amount <= 1e-5f || wScale <= 0.0f)
            return;
        const float ra  = s.r > 0.0f ? s.r : 0.045f;
        const float len = std::hypot(s.x - s.px, s.y - s.py);
        seg[n * 4 + 0] = s.px; seg[n * 4 + 1] = s.py;
        seg[n * 4 + 2] = s.x;  seg[n * 4 + 3] = s.y;
        par[n * 4 + 0] = s.dx; par[n * 4 + 1] = s.dy;
        par[n * 4 + 2] = ra;
        par[n * 4 + 3] = wScale * s.amount / (1.0f + 0.6f * len / ra);
        n++;
    };
    for (int i = 0; i < st.pendLen; i++)
        put(st.pendRing[(st.pendHead + i) % SGlobalState::PEND_RING], 1.0f);
    put(st.drag, 1.0f);
    put(st.mouse, 1.0f);   // the cursor's live stroke rides the trail too
    // The strokes absorbed by the current sim step fade here at exactly the
    // complement of the crossfade their texture copies are arriving with.
    for (int i = 0; i < st.lastAbsCount; i++)
        put(st.lastAbs[i], 1.0f - st.waveSubFrac);

    DBG("%.4f TRAIL n(pending)=%d subFrac=%.3f\n", dbgNow(), st.pendLen, st.waveSubFrac);
    auto sh = g_pHyprOpenGL->useShader(sm.trailShader);
    sh->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, FULLSCREEN_PROJECTION);
    glBindVertexArray(sh->getUniformLocation(SHADER_SHADER_VAO));
    glUniform4fv(sm.trailUniforms.tSeg, 26, seg);
    glUniform4fv(sm.trailUniforms.tPar, 26, par);
    g_pHyprOpenGL->setViewport(0, 0, SIM, SIM);
    g_pHyprOpenGL->setCapStatus(GL_BLEND, false);
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(st.trailFb));
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    g_pHyprOpenGL->setCapStatus(GL_BLEND, true);
    glBindVertexArray(0);
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
    g_pHyprOpenGL->setViewport(0, 0, prevVp[2], prevVp[3]);
}

void stepWaveSim() {
    auto& shaderManager = g_pGlobalState->shaderManager;
    if (!shaderManager.isInitialized())
        return;

    // Crude integrator of recently-injected wave energy, for the
    // self-limiting agitation: real water cannot stack waves without bound —
    // past a point they break and the energy leaves the wave field. A height
    // field has no breaking, so this is its diminishing-returns stand-in.
    static float seaEnergy = 0.0f;
    int SUB = 1;   // sub-steps per nominal 1/120 s step (see the time block)

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
    // Steps per real second, hoisted for the fluid-solve scheduling below:
    // steps slower than frames leave idle frames to spread the solve into.
    double stepHz = 480.0;
    {
        using namespace std::chrono;
        // ANCHORED TO ABSOLUTE TIME, not to "elapsed since I was last called".
        //
        // Monitors at different refresh rates render at different moments, so a
        // window spanning two screens has its halves drawn at different times.
        // With an elapsed-time accumulator each half could catch a different
        // simulation state and the seam showed it as flicker. Deriving the state
        // from a clock instead means any surface, on any monitor, at any moment,
        // asks for the same answer.
        static steady_clock::time_point origin{};
        static double simTime  = 0.0;   // simulated seconds consumed so far
        static double simDone  = 0.0;   // simulated seconds already integrated
        static double lastReal = 0.0;
        constexpr double STEP  = 1.0 / 120.0;

        const auto now = steady_clock::now();
        if (origin.time_since_epoch().count() == 0) origin = now;
        const double real = duration<double>(now - origin).count();

        const auto& spcfg = g_pGlobalState->config;
        const double speed = spcfg.shimmerSpeed
            ? std::clamp(static_cast<double>(**spcfg.shimmerSpeed), 0.0, 4.0) : 1.0;

        double dReal = real - lastReal;
        if (dReal < 0.0)  dReal = 0.0;
        if (dReal > 0.25) dReal = 0.25;   // swallow stalls rather than replaying them
        lastReal = real;
        simTime += dReal * speed;
        // Injected-energy estimate for the self-limiting agitation below:
        // bleeds away on a ~2 s time constant of REAL time.
        seaEnergy *= static_cast<float>(std::exp(-dReal * 0.5));

        // SUB-STEPPING. At low speed, whole 1/120 s steps arrive so rarely
        // that the surface — and especially a drag's deposits — visibly tick
        // between states. Instead of stepping rarely at full size, step more
        // often at reduced size: SUB sub-steps of STEP/SUB with the Courant
        // number divided by SUB² keeps the physical wave speed identical
        // (c ∝ sqrt(s)·rate) while the update rate stays ≥ ~40 Hz well down
        // the slider. Never smaller than STEP/4: the Laplacian's per-step
        // contribution must stay above fp16 precision — the old "just scale
        // dt" approach died exactly there.
        SUB = speed >= 0.4 ? 1 : (speed >= 0.15 ? 2 : 4);
        const double sub = STEP / SUB;
        stepHz = 120.0 * SUB * speed;

        double pending = simTime - simDone;
        int n = static_cast<int>(pending / sub);
        const int cap = 4 * SUB;
        if (n > cap) { n = cap; simDone = simTime - cap * sub; }   // caught up after a stall
        steps = n;
        simDone += n * sub;

        // Phase within the current sub-step, also from the clock, so both
        // halves of a monitor-spanning window blend to the same point.
        g_pGlobalState->waveSubFrac =
            static_cast<float>(std::clamp((simTime - simDone) / sub, 0.0, 1.0));

        if (steps > 0)
            DBG("%.4f STEP-BEGIN n=%d SUB=%d\n", dbgNow(), steps, SUB);
        if (steps <= 0)
            return;
    }

    // ---- Mouse wake ------------------------------------------------------
    // The cursor is a fingertip trailed in the pool: same distance-based
    // accumulator as a dragged window, mapped through the same desktop-space
    // formula so it disturbs the same sheet, but far lighter and far smaller.
    // Sampled here (once per sim advance) rather than per surface — the cursor
    // is global, there is nothing per-window about it.
    {
        const auto& mcfg = g_pGlobalState->config;
        const float mforce = mcfg.shimmerMouse
                           ? std::clamp(static_cast<float>(**mcfg.shimmerMouse), 0.0f, 1.0f) : 0.0f;
        static Vector2D prevCur{-1e9, -1e9};
        const Vector2D cur = g_pInputManager ? g_pInputManager->getMouseCoordsInternal() : prevCur;
        const Vector2D d{cur.x - prevCur.x, cur.y - prevCur.y};
        prevCur = cur;
        const double mag = std::sqrt(d.x * d.x + d.y * d.y);
        // Same sanity window as window drags: ignore sub-pixel jitter and
        // teleports (first sample, warps).
        if (mforce > 0.001f && mag > 0.3 && mag < 400.0) {
            const auto& desk = g_pGlobalState->deskMax;
            const float sc = mcfg.shimmerScale
                           ? static_cast<float>(**mcfg.shimmerScale) : 1.0f;
            const Vector2D g{(cur.x - desk.x * 0.5) / std::max(desk.x, 1.0),
                             (cur.y - desk.y * 0.5) / std::max(desk.x, 1.0)};
            auto& mk = g_pGlobalState->mouse;
            const float mx = static_cast<float>(0.5 + g.x * 0.85 * sc * 2.0 * 0.105);
            const float my = static_cast<float>(0.5 + g.y * 0.85 * sc * 2.0 * 0.105);
            if (mk.amount <= 1e-6f) {
                const float k = static_cast<float>(0.85 * sc * 2.0 * 0.105 / std::max(desk.x, 1.0));
                mk.px = mx - static_cast<float>(d.x) * k;
                mk.py = my - static_cast<float>(d.y) * k;
            }
            mk.x  = mx;
            mk.y  = my;
            mk.dx = static_cast<float>(d.x / mag);
            mk.dy = static_cast<float>(d.y / mag);
            // A fingertip, not a hull: ~10 sim texels wide, and per-pixel
            // deposit about a third of a window's at full slider.
            mk.r  = 0.010f;
            mk.amount = std::min(mk.amount + static_cast<float>(mag) * 0.00012f * mforce,
                                 0.012f * std::max(mforce, 0.05f));
            // The mouse wake goes through the SAME ring and analytic trail as
            // window drags. It previously spent straight into the sim — which
            // renders at the STEP rate, i.e. once per second at the bottom of
            // the speed slider: the cursor's wake was a 1 Hz slideshow while
            // window wakes were smooth. Same physics, same pipeline.
            if (std::hypot(mk.x - mk.px, mk.y - mk.py) > 0.009f && pushPendStroke(mk)) {
                mk.px = mk.x;
                mk.py = mk.y;
                mk.amount = 0.0f;
            }
        }
    }

    auto& fbA = g_pGlobalState->waveFb[0];
    auto& fbB = g_pGlobalState->waveFb[1];
    if (!fbA) fbA = g_pHyprRenderer->createFB("hyprwater-wave-a");
    if (!fbB) fbB = g_pHyprRenderer->createFB("hyprwater-wave-b");

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
        g_pGlobalState->waveBias = 0.5f;
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
    // Flipping the master switch should start from still water. Leaving the
    // textures alone meant re-enabling resumed a surface that had been sloshing
    // in the dark, so the effect appeared mid-storm with no way to see it begin.
    static bool wasOn = false;
    const bool  isOn  = g_pGlobalState->config.shimmerEnabled
                     && **g_pGlobalState->config.shimmerEnabled != 0;
    if (isOn && !wasOn)
        fresh = true;
    wasOn = isOn;

    if (fresh) {
        for (auto* fb : {&fbA, &fbB}) {
            glBindFramebuffer(GL_FRAMEBUFFER, fbId(*fb));
            glClearColor(g_pGlobalState->waveBias, g_pGlobalState->waveBias, 0.0f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT);
        }
        g_pGlobalState->waveStepCount = 0;
    }

    GLint prevFbo = 0, prevVp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
    glGetIntegerv(GL_VIEWPORT, prevVp);

    // ---- Currents: velocity-field housekeeping ---------------------------
    // Gated on the half-float path: velocity is SIGNED and small, and unlike
    // the height field it has no bias trick worth doing on a UNORM target —
    // quantised velocity reads as the water jittering in place. No fallback,
    // the toggle just does nothing on hardware that can't render to fp16.
    bool fluidOn = fmt == DRM_FORMAT_ABGR16161616F
                && g_pGlobalState->config.shimmerCurrents
                && **g_pGlobalState->config.shimmerCurrents != 0;
    {
        static bool currentsWere = false;
        bool freshFluid = fresh;
        if (fluidOn && !currentsWere)
            freshFluid = true;   // stale field from before the toggle flipped
        currentsWere = fluidOn;
        if (fluidOn) {
            auto& st = *g_pGlobalState;
            const int res = fluidRes();
            SP<Render::IFramebuffer>* fbs[] = {&st.fluidVelFb[0], &st.fluidVelFb[1],
                                               &st.fluidPrsFb[0], &st.fluidPrsFb[1],
                                               &st.fluidDivFb};
            const char* names[] = {"hyprwater-vel-a", "hyprwater-vel-b",
                                   "hyprwater-prs-a", "hyprwater-prs-b",
                                   "hyprwater-div"};
            for (size_t i = 0; i < std::size(names); i++) {
                auto& fb = *fbs[i];
                if (!fb)
                    fb = g_pHyprRenderer->createFB(names[i]);
                if (fb->m_size.x != res || fb->m_size.y != res) {
                    fb->alloc(res, res, fmt);
                    freshFluid = true;
                }
                if (!fb || !fb->getTexture() || fbId(fb) == 0)
                    fluidOn = false;
            }
            // Zero is genuinely zero here (still water, no pressure), unlike
            // the height textures whose flat state is the bias value.
            if (fluidOn && freshFluid) {
                for (auto* fb : fbs) {
                    glBindFramebuffer(GL_FRAMEBUFFER, fbId(*fb));
                    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
                    glClear(GL_COLOR_BUFFER_BIT);
                }
                // Any solve queued against the old field is now moot.
                st.fluidJacobiLeft = 0;
                st.fluidNeedGrad   = false;
            }
        }
    }

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
    // FIXED. Speed must not touch the physics.
    // Scaling c^2 dt^2 was wrong twice over. Linearly it scaled dt by sqrt();
    // squared it scaled dt correctly but drove the constant to ~1.8e-6 at the
    // low end, where the laplacian's contribution per step falls BELOW HALF
    // FLOAT PRECISION and vanishes into rounding — the simulation stopped
    // behaving like a wave equation at all, which is why slow water looked like
    // a different effect rather than the same one slowed down.
    // Time is scaled by running the simulation less often instead, and the gap
    // between steps is interpolated so it still looks smooth.
    // Now a plain multiplier on the stability ceiling, not an absolute Courant
    // number -- the ceiling itself moves with viscosity.
    // Shallow-water waves travel at sqrt(g*h): DEEPER WATER IS FASTER, which is
    // why swell slows and piles up as it reaches a beach. Depth already sets the
    // refraction and the focusing, so this is the third thing it should do.
    // Capped at 1 because the stability ceiling is the real limit past that
    // point -- deeper than nominal cannot actually run faster here.
    const float dep = g_pGlobalState->config.shimmerDepth
                    ? static_cast<float>(**g_pGlobalState->config.shimmerDepth) : 1.0f;
    glUniform1f(u.waveSpeed, std::min(std::sqrt(std::max(dep, 0.01f)), 1.0f));
    // Just under 1: energy bleeds away, so agitation SETTLES instead of ringing
    // forever. This is what gives the "everyone got out of the pool" pacing.
    // Closer to 1: energy survives long enough for many disturbances to be in
    // flight at once and interfere, instead of one lonely wavefront at a time.
    // Still below 1, so agitation genuinely settles when impulses pause.
    // Also fixed, for the same reason: decay is part of the physics, and
    // scaling it changed how the water behaved rather than how fast it ran.
    // Per-SUB-step: damping is a per-step retention, so K smaller steps need
    // the K-th root to bleed the same energy per simulated second.
    glUniform1f(u.damping, SUB == 1 ? 0.9994f : std::pow(0.9994f, 1.0f / SUB));
    // Fixed, not exposed. This varies the local wave speed the way an uneven
    // bottom does, which is what stops wavefronts from staying perfect arcs.
    // There was a slider for it, but "how fake would you like the floor to be"
    // is not a real choice -- every floor is uneven, and the clean version it
    // offered is a thing that does not occur.
    glUniform1f(u.bedVariation, 1.0f);


    // Occasional localized push. Deterministic LCG rather than a random device
    // so behaviour is reproducible when debugging a bad-looking frame.
    const auto& scfg = g_pGlobalState->config;
    const float agit = scfg.shimmerAgitation ? static_cast<float>(**scfg.shimmerAgitation) : 0.5f;
    const float thick = scfg.shimmerViscosity ? static_cast<float>(**scfg.shimmerViscosity) : 0.6f;
    // agitation 0..1 -> an event every 900..6 steps, GEOMETRICALLY.
    // The old mapping was linear from 90 down to 8, which had two faults. The
    // bottom of the slider still fired 120/90 = 1.3 disturbances per SECOND --
    // that is not calm water, that is rain, and it is why the surface stayed
    // chaotic no matter how far the control came down. And a linear ramp on a
    // RATE spends most of its travel in the busy half: 90 to 8 is one order of
    // magnitude crammed into the last third of the slider. Rates are perceived
    // in ratios, so interpolate the logarithm and the whole range is usable.
    // At 0 this is one disturbance every 7.5 s of simulated time; damping only
    // removes about 40% of the energy over that gap, so the surface glides
    // rather than going flat.
    const float ag  = std::clamp(agit, 0.0f, 1.0f);
    uint64_t every = static_cast<uint64_t>(
        std::exp(std::log(900.0f) + (std::log(6.0f) - std::log(900.0f)) * ag) + 0.5f);
    // `every` counts STEPS; sub-steps are SUB× more frequent, so scale it to
    // keep the disturbance rate fixed in real time.
    every *= static_cast<uint64_t>(SUB);

    // "Ripples vs swell" IS viscosity: impulse size only chooses what goes IN,
    // viscosity chooses what SURVIVES, and the latter is what the label means.
    //
    // STABILITY. The usual Courant limit s < 0.5 does NOT survive the viscous
    // term. Writing one mode as h+ = d[(2 + (s+v)L)h - (1 + vL)h-] with L the
    // Laplacian eigenvalue on [-8,0], bounded roots need A^2 < 4B, and the
    // (1 + vL) term is what viscosity attacks: it drives B toward zero, the
    // roots go real, and one of them leaves the unit circle. Working it out at
    // L = -8 gives
    //
    //     s + v < sqrt(s / 2)
    //
    // which collapses to s < 0.5 only when v = 0. Assuming the two simply
    // shared a 0.5 budget was wrong and diverged at every setting except the
    // thinnest -- the Nyquist mode amplifying every step, which is the
    // pixel-checkerboard that ate the window.
    //
    // Solving s + v = K*sqrt(s/2) for s, in u = sqrt(s):
    //     u^2 - (K/sqrt2) u + v = 0
    // and taking the larger root gives the fastest speed this viscosity allows.
    // K is the fraction of the boundary used; 0.78 keeps the worst-case
    // per-step gain at 0.9996 instead of sitting on 1.0.
    // Reads in the same direction as its name: right is thicker.
    const float visc = 0.005f + 0.060f * std::clamp(thick, 0.0f, 1.0f);
    constexpr float K = 0.78f;
    const float disc = std::max(K * K * 0.5f - 4.0f * visc, 0.0f);
    const float uRoot = (K / std::sqrt(2.0f) + std::sqrt(disc)) * 0.5f;
    glUniform1f(u.hBias, g_pGlobalState->waveBias);
    // Courant number and viscosity both scale with dt² ∝ 1/SUB², which is
    // exactly what keeps the physical wave speed and dissipation identical
    // across sub-step regimes (and strictly inside the stability ceiling,
    // which was solved for the full-size step).
    glUniform1f(u.viscosity, visc / (SUB * SUB));
    glUniform1f(u.maxSpeed, uRoot * uRoot / (SUB * SUB));
    // Exactly 0 when currents are off: the shader's advection branch keys on
    // it, so a disabled field costs one compare and no texture read.
    glUniform1i(u.velTex, 4);
    glUniform1f(u.flowAdvect, fluidOn ? 1.0f / (120.0f * SUB) : 0.0f);
    g_pGlobalState->flowDt = fluidOn ? 1.0f / (120.0f * SUB) : 0.0f;
    // DELIBERATELY NOT scaled by speed. Tying it to simulated time was correct
    // in physics and wrong in use: at speed 0.002 it worked out to one
    // disturbance every ~6 MINUTES, so the surface just sat there. "Slow" is
    // wanted as slow MOTION, not as a slow world where nothing happens.
    // Keeping the rate in real time means low speed reads as a gently evolving
    // texture that is still fed, and "How often" stays an independent control.


    g_pHyprOpenGL->setCapStatus(GL_BLEND, false);

    for (int i = 0; i < steps; i++) {
        auto& s0 = g_pGlobalState->waveFb[g_pGlobalState->waveCurrent];
        auto& d0 = g_pGlobalState->waveFb[1 - g_pGlobalState->waveCurrent];
        if (!s0 || !s0->getTexture() || fbId(d0) == 0)
            break;

        // Currents advance FIRST so this wave step reads the freshly projected
        // field. The drag state is read here and spent (zeroed) by the wave
        // impulse branch below — the same drag feeds both on the same step:
        // the height dipole is the bow wave, the velocity splat is the
        // momentum left in the water. The dipole stays even with currents on
        // because a divergence-free field advecting a FLAT surface leaves it
        // flat — momentum alone cannot raise water here, so without the dipole
        // a drag across calm water would be invisible.
        if (fluidOn) {
            const int res = fluidRes();
            // A solve still spreading from the previous step must land before
            // this step advects through its field.
            if (g_pGlobalState->fluidJacobiLeft > 0 || g_pGlobalState->fluidNeedGrad)
                runFluidSolve(res, FLUID_JACOBI);
            // One force slot per step; the window's momentum outranks the
            // fingertip's. Whichever is skipped keeps its accumulation for a
            // later step.
            stepFluidAdvect(g_pGlobalState->drag.amount > 1e-5f
                                ? g_pGlobalState->drag : g_pGlobalState->mouse,
                            res, 1.0f / (120.0f * SUB));
            // Steps at frame rate keep the pressure solve inline (spreading
            // could never catch up); steps slower than frames leave it queued
            // for the per-frame budget slice instead of bursting 25 draws
            // into this frame — that burst was the low-speed tick.
            if (stepHz >= 45.0)
                runFluidSolve(res, FLUID_JACOBI);
            // The fluid passes bound their own programs; the wave uniforms set
            // above still live in the wave program's state, so rebinding is
            // all that is needed.
            shader = g_pHyprOpenGL->useShader(shaderManager.waveSimShader);
        }
        glBindVertexArray(shader->getUniformLocation(SHADER_SHADER_VAO));
        g_pHyprOpenGL->setViewport(0, 0, SIM, SIM);

        // Impulses are decided per STEP, so their rate follows simulated time
        // rather than however many frames happened to get drawn.
        const uint64_t nn = g_pGlobalState->waveStepCount++;
        // Zero means zero. Any nonzero rate, however slow, still eventually
        // fires, so the bottom of the slider has to be an actual OFF rather
        // than the slowest available drip -- otherwise there is no way to watch
        // the water finish settling, which is the only way to judge damping.
        // ── SLOT 2: round events (ambient swell / click tap) ─────────────
        // Independent of the stroke slot below, so splashes never starve the
        // drag-trail absorption and vice versa.
        {
            auto& st2 = *g_pGlobalState;
            const bool fire = ag > 0.001f && nn % std::max<uint64_t>(every, 2) == 0;
            if (fire) {
                uint64_t r = nn * 6364136223846793005ULL + 1442695040888963407ULL;
                auto fr = [&](int sh) { return static_cast<float>((r >> sh) & 0xFFFF) / 65535.0f; };
                // Outer ring only: the shader samples just the middle of the
                // sim, so these are genuinely off-screen and travel inward.
                const float ang = fr(16) * 6.2831853f;
                const float rr  = 0.40f + 0.09f * fr(32);
                const float rad = 0.025f + 0.050f * std::clamp(thick, 0.0f, 1.0f) + 0.020f * fr(40);
                // Calm water is disturbed more GENTLY, not merely less often;
                // and SELF-LIMITING by the energy already in flight — real
                // waves break instead of stacking without bound.
                const float tame = 1.0f / (1.0f + seaEnergy * 0.12f);
                const float amp = (0.10f + 0.16f * fr(48)) * (0.45f + 0.55f * ag) * tame;
                seaEnergy += amp;
                // A SWELL, not a pop: the amplitude enters over 6 steps. At
                // low sim speed a one-step splash materialised in ~60 ms while
                // everything else crawled — the user's video caught them as
                // isolated ticks on otherwise still water.
                st2.ambX = 0.5f + std::cos(ang) * rr;
                st2.ambY = 0.5f + std::sin(ang) * rr;
                st2.ambR = rad;
                st2.ambChunk = amp / 6.0f;
                st2.ambLeft  = amp;
            }
            if (st2.click.amount > 1e-5f) {
                // A tap presses IN — negative amplitude — and the rebound ring
                // is the ripple. Taps are real-time user actions: immediate.
                glUniform4f(u.impulse2, st2.click.x, st2.click.y,
                            st2.click.r > 0.0f ? st2.click.r : 0.016f, -st2.click.amount);
                st2.click.amount = 0.0f;
            } else if (st2.ambLeft > 0.0f) {
                const float chunk = std::min(st2.ambChunk, st2.ambLeft);
                glUniform4f(u.impulse2, st2.ambX, st2.ambY, st2.ambR, chunk);
                st2.ambLeft -= chunk;
            } else {
                glUniform4f(u.impulse2, 0.0f, 0.0f, 1.0f, 0.0f);
            }
        }

        // ── STROKE SLOTS: drain the ring HARD, up to 8 segments per step ──
        // Segments waiting around analytically while their absorbed siblings
        // flow with the currents was the static-vs-flowing handoff chop; with
        // 8 slots the ring drains faster than any whip can fill it, so a
        // segment spends at most a step or two analytic — while the currents
        // near a fresh drag are still too weak to expose the handoff.
        {
            auto& st2 = *g_pGlobalState;
            st2.lastAbsCount = 0;
            if (st2.drag.amount > 1e-5f) {
                pushPendStroke(st2.drag);
                st2.drag.px = st2.drag.x;
                st2.drag.py = st2.drag.y;
                st2.drag.amount = 0.0f;
            }
            float seg[32] = {0}, par[32] = {0};
            int   ns = 0;
            auto slot = [&](const SGlobalState::SDrag& s, float fallbackR, bool round) {
                if (ns >= 8 || s.amount <= 1e-5f)
                    return;
                const float ra  = s.r > 0.0f ? s.r : fallbackR;
                const float len = std::hypot(s.x - s.px, s.y - s.py);
                seg[ns * 4 + 0] = round ? s.x : s.px;
                seg[ns * 4 + 1] = round ? s.y : s.py;
                seg[ns * 4 + 2] = s.x;  seg[ns * 4 + 3] = s.y;
                par[ns * 4 + 0] = round ? 0.0f : s.dx;
                par[ns * 4 + 1] = round ? 0.0f : s.dy;
                par[ns * 4 + 2] = ra;
                par[ns * 4 + 3] = s.amount / (round ? 1.0f : (1.0f + 0.6f * len / ra));
                ns++;
            };
            while (st2.pendLen > 0 && ns < 8) {
                const auto& sgm = st2.pendRing[st2.pendHead];
                // Remember what is being absorbed: the trail pass keeps
                // rendering it this interval at (1 - subFrac), the exact
                // complement of its texture copy fading in.
                if (st2.lastAbsCount < 8)
                    st2.lastAbs[st2.lastAbsCount++] = sgm;
                slot(sgm, 0.045f, false);
                st2.pendHead = (st2.pendHead + 1) % SGlobalState::PEND_RING;
                st2.pendLen--;
            }
            glUniform4fv(u.sSeg, 8, seg);
            glUniform4fv(u.sPar, 8, par);
        }

        glBindFramebuffer(GL_FRAMEBUFFER, fbId(d0));
        // Unit 3, NOT unit 0: unit 0 is the glass shader's backdrop sampler, and
        // leaving the sim texture bound there makes the glass sample the water
        // height as if it were the wallpaper (observed: windows went flat grey).
        glActiveTexture(GL_TEXTURE3);
        s0->getTexture()->bind();
        // The wave texture is read at roughly one texel per five screen
        // pixels, so its filtering is not a detail: on NEAREST the height
        // field is piecewise constant and its finite-difference curvature is
        // either zero or enormous exactly on texel boundaries, which prints
        // the simulation grid onto the window as blocky steps. Nothing ever
        // set these, so they were whatever the framebuffer allocation left
        // behind. CLAMP matters as much: the reflecting boundary needs
        // samples past the edge to repeat the edge, not wrap to the far side.
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        // The freshly projected velocity, for the advection lookup. Unit 4 —
        // unit 0 is the glass backdrop, unit 3 is the height field.
        if (fluidOn) {
            bindSimTexture(4, g_pGlobalState->fluidVelFb[g_pGlobalState->fluidVelCurrent]);
            glActiveTexture(GL_TEXTURE3);
        }
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        g_pGlobalState->waveCurrent = 1 - g_pGlobalState->waveCurrent;
    }

    DBG("%.4f STEP-DRAWS-DONE\n", dbgNow());
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
        blurTempFramebuffer = g_pHyprRenderer->createFB("hyprwater-blur-temp");

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
        if (wOn) {
            stepWaveSim();
            // The trail pass renders per FRAME even when the sim does not
            // step — that independence is the whole point. Same for the
            // fluid budget: it retires a queued pressure solve a slice per
            // frame on the frames BETWEEN steps.
            runFluidBudgetFrame();
            renderTrailTex();
        }
    }

    auto shader = g_pHyprOpenGL->useShader(shaderManager.glassShader);

    shader->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, glMatrix.getMatrix());
    shader->setUniformInt(SHADER_TEX, 0);

    const auto fullSize = Vector2D(transformedBox.width, transformedBox.height);
    shader->setUniformFloat2(SHADER_FULL_SIZE,
        static_cast<float>(fullSize.x), static_cast<float>(fullSize.y));

    // Desktop-space anchor for the water. transformedBox is monitor-local, so
    // the monitor's own position is added back to get a coordinate that means
    // the same thing on every screen -- otherwise the two monitors would each
    // start their own pool at the same origin and the sheet would tear at the
    // seam.
    Vector2D monOff{0.0, 0.0};
    Vector2D desk{1920.0, 1080.0};
    // The origin counts from the far left of ALL monitors, so the reference
    // width must too. Dividing by ONE monitor's width while measuring from the
    // desktop's left edge pushed second-monitor windows far outside the field,
    // near where waves are born, so they saw their sources from much closer.
    // Bounds accumulate as each monitor renders, so no compositor-wide list is
    // needed here. Held in global state (not a function-local static) because
    // the mouse wake in stepWaveSim maps the cursor through the same bounds.
    auto& deskMax = g_pGlobalState->deskMax;
    if (const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock()) {
        monOff = mon->m_position;
        deskMax.x = std::max(deskMax.x, mon->m_position.x + mon->m_size.x);
        deskMax.y = std::max(deskMax.y, mon->m_position.y + mon->m_size.y);
    }
    desk = deskMax;
    // rawBox, not transformedBox: rawBox is what gets projected to the target,
    // so it is the one carrying the window's real position. transformedBox is
    // relative to the sampled framebuffer, which is window-sized and therefore
    // sits at the origin -- constant no matter where the window is, which is
    // why nothing moved when the window did.
    glUniform2f(uniforms.winOrigin,
                static_cast<float>(rawBox.x + monOff.x),
                static_cast<float>(rawBox.y + monOff.y));

    // A dragged edge sweeps water aside. What it deposits is proportional to
    // the DISTANCE it covered, not to how long it spent covering it, so this
    // adds a little every frame and the simulation spends whatever has built up
    // when it next steps. Dragging 500px delivers the same displacement whether
    // it took half a second or five.
    {
        const Vector2D here{rawBox.x + monOff.x, rawBox.y + monOff.y};
        struct STrack { Vector2D prev{}; Vector2D smooth{}; };
        static std::unordered_map<uint64_t, STrack> track;
        const uint64_t id = reinterpret_cast<uintptr_t>(sampleFramebuffer.get());
        auto& tr = track[id];
        auto& prev = tr.prev;
        const Vector2D vel{here.x - prev.x, here.y - prev.y};
        prev = here;
        const double mag = std::sqrt(vel.x * vel.x + vel.y * vel.y);

        // Smoothed per-window velocity for the real-time bow wave. Rises fast
        // while dragging, decays over a few frames when the window stops, so
        // the crest melts back instead of vanishing.
        DBG("%.4f GLASS fb=%lx x=%.1f y=%.1f mag=%.2f pend=%d\n",
            dbgNow(), (unsigned long)id, here.x, here.y, mag, g_pGlobalState->pendLen);
        tr.smooth.x = tr.smooth.x * 0.75 + vel.x * 0.25;
        tr.smooth.y = tr.smooth.y * 0.75 + vel.y * 0.25;
        const double smag = std::sqrt(tr.smooth.x * tr.smooth.x + tr.smooth.y * tr.smooth.y);
        {
            const float sc2 = g_pGlobalState->config.shimmerScale
                            ? static_cast<float>(**g_pGlobalState->config.shimmerScale) : 1.0f;
            const bool wp2 = !g_pGlobalState->config.shimmerWindowPhysics
                          || **g_pGlobalState->config.shimmerWindowPhysics != 0;
            // Strength saturates by ~12 px/frame; below ~0.5 it is off.
            const float wake = (wp2 && smag > 0.5 && smag < 400.0)
                             ? static_cast<float>(std::min(smag / 12.0, 1.0)) : 0.0f;
            const double kk = 0.85 * sc2 * 2.0 * 0.105 / std::max(desk.x, 1.0);
            const Vector2D c2{here.x + rawBox.width * 0.5, here.y + rawBox.height * 0.5};
            glUniform4f(uniforms.winWake,
                        smag > 1e-5 ? static_cast<float>(tr.smooth.x / smag) : 0.0f,
                        smag > 1e-5 ? static_cast<float>(tr.smooth.y / smag) : 0.0f,
                        wake, 0.0f);
            glUniform4f(uniforms.winRectSim,
                        static_cast<float>(0.5 + (c2.x - desk.x * 0.5) * kk),
                        static_cast<float>(0.5 + (c2.y - desk.y * 0.5) * kk),
                        static_cast<float>(std::max(rawBox.width  * 0.5 * kk, 1e-4)),
                        static_cast<float>(std::max(rawBox.height * 0.5 * kk, 1e-4)));

            // (The analytic stroke trail is no longer uploaded here — it is
            // summed into its own texture once per frame by renderTrailTex,
            // and the glass shader reads it with a single tap.)
        }
        // A toggle, not a force slider: windows either sit in the water or
        // they don't. Position tracking above still runs while off, so
        // flipping it on mid-drag doesn't read the accumulated gap as one
        // violent shove.
        const bool wPhys = !g_pGlobalState->config.shimmerWindowPhysics
                        || **g_pGlobalState->config.shimmerWindowPhysics != 0;
        if (wPhys && mag > 0.3 && mag < 400.0) {
            const float sc = g_pGlobalState->config.shimmerScale
                           ? static_cast<float>(**g_pGlobalState->config.shimmerScale) : 1.0f;
            // Centre, not leading edge: the dipole already puts the crest ahead
            // and the trough behind on its own.
            const Vector2D c{here.x + rawBox.width * 0.5, here.y + rawBox.height * 0.5};
            const Vector2D g{(c.x - desk.x * 0.5) / std::max(desk.x, 1.0),
                             (c.y - desk.y * 0.5) / std::max(desk.x, 1.0)};
            const Vector2D wp{0.5 + g.x * 0.85 * sc, 0.5 + g.y * 0.85 * sc};
            auto& dg = g_pGlobalState->drag;
            const float sx = static_cast<float>(0.5 + (wp.x - 0.5) * 2.0 * 0.105);
            const float sy = static_cast<float>(0.5 + (wp.y - 0.5) * 2.0 * 0.105);
            // Fresh stroke: anchor its start one frame back, so even the very
            // first spend covers the distance moved rather than a point.
            if (dg.amount <= 1e-6f) {
                const float k = static_cast<float>(0.85 * sc * 2.0 * 0.105 / std::max(desk.x, 1.0));
                dg.px = sx - static_cast<float>(vel.x) * k;
                dg.py = sy - static_cast<float>(vel.y) * k;
            }
            dg.x  = sx;
            dg.y  = sy;
            dg.dx = static_cast<float>(vel.x / mag);
            dg.dy = static_cast<float>(vel.y / mag);
            // The disturbance is as wide as the window, because the whole
            // advancing face is what pushes the water. A fixed small radius put
            // a blob in the middle of the window instead of a front along its
            // edge, which is why it looked like it came from the wrong place.
            const double halfW = rawBox.width / std::max(desk.x, 1.0)
                               * 0.85 * sc * 2.0 * 0.105 * 0.5;
            dg.r = static_cast<float>(std::clamp(halfW * 0.9, 0.02, 0.16));
            // The force the slider used to control, fixed at the value it
            // shipped tuned to. The knob became the window_physics toggle.
            constexpr float force = 0.35f;
            dg.amount = std::min(dg.amount + static_cast<float>(mag) * 0.00035f * force,
                                 0.05f * force);
            // Subdivide by DISTANCE, per frame: once the live segment is
            // about a radius of arc long, commit it to the ring and start a
            // new one at its end. This keeps a hard whip a fine smooth curve
            // at ANY sim speed — subdividing only at sim steps turned the
            // trail into step-rate chords whose tails teleported (the tick
            // the user kept catching at minimum speed).
            if (std::hypot(dg.x - dg.px, dg.y - dg.py) > std::max(0.9f * dg.r, 0.004f)
                && pushPendStroke(dg)) {
                dg.px = dg.x;
                dg.py = dg.y;
                dg.amount = 0.0f;
            }
        }
    }

    glUniform2f(uniforms.winSize,
                static_cast<float>(rawBox.width), static_cast<float>(rawBox.height));
    glUniform2f(uniforms.deskSize,
                static_cast<float>(desk.x), static_cast<float>(desk.y));

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
        glUniform1f(uniforms.waveSubFrac, g_pGlobalState->waveSubFrac);
        glUniform1f(uniforms.waveTexel, 1.0f / SIM);
        glUniform1f(uniforms.waveBias, g_pGlobalState->waveBias);
        glUniform1f(uniforms.shimmerAbsorption,
                    cfg.shimmerAbsorption ? static_cast<float>(**cfg.shimmerAbsorption) : 1.0f);
        glUniform1f(uniforms.shimmerMurk,
                    cfg.shimmerMurk ? static_cast<float>(**cfg.shimmerMurk) : 0.0f);
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
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
                glActiveTexture(GL_TEXTURE0);
                glUniform1i(uniforms.waveTex, 2);
            }
            // The analytic stroke trail, freshly summed this frame. Unit 5 —
            // 0 backdrop, 1 layer mask, 2 water, 3/4 sim internals. The
            // uniform is set UNCONDITIONALLY: if it defaulted to unit 0 the
            // height read would add the BACKDROP's red channel to the water.
            // An unbound unit 5 samples as zero, which is merely a flat trail.
            glUniform1i(uniforms.trailTex, 5);
            auto& tfb = g_pGlobalState->trailFb;
            if (tfb && tfb->getTexture()) {
                glActiveTexture(GL_TEXTURE5);
                tfb->getTexture()->bind();
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
                glActiveTexture(GL_TEXTURE0);
            }
            // Velocity field for advected interpolation, unit 6. flowShift is
            // forced to 0 whenever the texture is unusable so the shader
            // falls back to the plain crossfade.
            glUniform1i(uniforms.velTexG, 6);
            auto& vfb = g_pGlobalState->fluidVelFb[g_pGlobalState->fluidVelCurrent];
            const bool velOk = g_pGlobalState->flowDt > 0.0f && vfb && vfb->getTexture();
            glUniform1f(uniforms.flowShift, velOk ? g_pGlobalState->flowDt : 0.0f);
            if (velOk) {
                glActiveTexture(GL_TEXTURE6);
                vfb->getTexture()->bind();
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
                glActiveTexture(GL_TEXTURE0);
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
