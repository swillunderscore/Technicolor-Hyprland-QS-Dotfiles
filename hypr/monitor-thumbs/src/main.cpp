// monitor-thumbs — the bar's monitor and window pictures, read out of images
// Hyprland already has.
//
// Ported to Hyprland 0.57 (plugin 1.3): same behaviour as 1.2 on 0.56.2.
//
// WHY: the bar used to run grim. Every grim is a new screencopy client, and
// Hyprland serves a new client's first frame by damaging the WHOLE monitor,
// rendering it again into a scratch buffer and reading it back while the main
// thread waits (ScreenshareFrame.cpp in v0.56.2). Measured 2026-10-28: 19 ms
// frozen per monitor capture on DP-1 (18 ms even for a 1x1 region), 5-18 ms per
// hover-card tick of window captures. Wayland has no way to ask for "a few
// pixels".
//
// MONITORS: at most once a second per monitor, at RENDER_POST, the buffer that
// frame just put on the screen is shrunk on the GPU with two linear blits (16
// source pixels per picture pixel, the same density the old grim sampler
// averaged). NOT the frame's own framebuffer inside the pass: in 0.56.2 and
// 0.57.0 that is a pooled work buffer (fp16 when the GPU can, in 0.57) that is
// only right inside the frame's damage (end() copies just the damage to the
// screen buffer; the rest is cleared or left over from other passes).
// Pictured, it showed Brave missing and the wallpaper in its place every other
// second (2026-11-01). The screen buffer (the render context's outFB = the
// swapchain buffer handed to the output) is always whole: Hyprland redraws its
// buffer-age damage (0.57 Renderer.cpp beginRender: getBufferDamage(age)).
//
// WINDOWS: `hyprctl monitorthumbs window <address> <w> <h> [; ...]` asks for a
// window's picture. The next rendered frame draws the window's own surface
// texture — the image the app last handed Hyprland, kept for windows on hidden
// workspaces too — into a w x h framebuffer with a 4-tap box shader (16 texels
// per picture pixel). Nothing of the window is rendered again.
//
// Both start an asynchronous readback of the tiny result into a pixel buffer and
// drop a fence. A later frame's RENDER_BEGIN copies the bytes out once that
// fence has signalled, so Hyprland never waits on the GPU, and writes a small
// PPM: <Hyprland instance dir>/monitor-thumbs/mon-<monitor>.ppm and
// win-<stableId>.ppm. Per instance, so a picture can never outlive the Hyprland
// that drew it; removed on unload, so "no file" always means "no plugin" (the
// bar then shows its plain color blocks / app icons instead of frozen pictures).
//
// Only frames Hyprland renders anyway are sampled: an idle monitor draws
// nothing new and its last picture is still what's on it.

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/ipc/s1/S1.hpp>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/Shader.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/gl/GLFramebuffer.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>

#include <GLES3/gl32.h>

#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <format>
#include <optional>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include <fcntl.h>
#include <unistd.h>

inline HANDLE PHANDLE = nullptr;

namespace {
    constexpr int  THUMB_H = 30;                      // the bar's tallest picture, in pixels
    constexpr auto EVERY   = std::chrono::seconds(1);
    // A workspace switch slides for a moment; picture it once it has settled
    // (the bar asked the old helper for a picture 450 ms after a switch, too).
    constexpr auto AFTER_SWITCH = std::chrono::milliseconds(450);
    constexpr int  MAX_WIN_SIDE = 1024;               // a request bigger than this is a mistake

    // Quad over the whole target (hyprwater's FULLSCREEN_PROJECTION).
    constexpr std::array<float, 9> FULLSCREEN = {2.0f, 0.0f, 0.0f, 0.0f, 2.0f, 0.0f, -1.0f, -1.0f, 1.0f};

    // Four bilinear taps a quarter picture-pixel either side of the centre:
    // each averages 2x2 texels, so 16 texels behind every picture pixel. Alpha
    // is dropped (the PPM has none); the texture's own swizzle applies, so shm
    // formats come out in the right channel order.
    constexpr const char* WIN_FRAG = R"GLSL(#version 300 es
precision highp float;
uniform sampler2D tex;
uniform vec2 tapStep;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
void main() {
    vec3 c = texture(tex, v_texcoord + vec2(-tapStep.x, -tapStep.y)).rgb
           + texture(tex, v_texcoord + vec2( tapStep.x, -tapStep.y)).rgb
           + texture(tex, v_texcoord + vec2(-tapStep.x,  tapStep.y)).rgb
           + texture(tex, v_texcoord + vec2( tapStep.x,  tapStep.y)).rgb;
    fragColor = vec4(c * 0.25, 1.0);
}
)GLSL";

    struct SReadback {
        GLuint pbo   = 0;
        GLsync fence = nullptr;                       // readback in flight
        int    w = 0, h = 0;
    };

    struct SMonitorThumb {
        Time::steady_tp due;                          // next frame at/after this gets sampled
        SReadback       rb;
    };

    struct SWinRequest {
        uintptr_t address = 0;
        int       w = 0, h = 0;
    };

    // Picked at RENDER_LAST_MOMENT (Hyprland forgets outFB in end()), taken at
    // RENDER_POST of the same frame.
    struct SPendingMonitor {
        std::string                  name;
        WP<Render::IFramebuffer>     out;
    };

    std::unordered_map<std::string, SMonitorThumb> g_thumbs;      // monitor name ->
    std::unordered_map<std::string, SReadback>     g_winReads;    // "win-<stableId>" ->
    std::vector<SWinRequest>                       g_winRequests; // waiting for a frame
    std::optional<SPendingMonitor>                 g_pendingMonitor;
    SP<Render::IFramebuffer>                       g_half, g_small, g_winFb;
    SP<CShader>                                    g_winShader;
    GLint                                          g_tapStepLoc = -1;
    bool                                           g_winShaderFailed = false;
    std::string                                    g_dir;
    CHyprSignalListener                            g_stageListener, g_workspaceListener;
    SP<IPC::Socket1::SCommand>                     g_command;
    SP<CEventLoopTimer>                            g_kickTimer;

    GLuint fbId(const SP<Render::IFramebuffer>& fb) {
        // dynamic_cast: anything that is not a GL framebuffer has no FBO, and
        // calling getFBID() through the wrong type is a crash (see hyprwater).
        auto* gl = fb ? dynamic_cast<Render::GL::CGLFramebuffer*>(fb.get()) : nullptr;
        return gl ? gl->getFBID() : 0;
    }

    bool ensureFB(SP<Render::IFramebuffer>& fb, const char* name, int w, int h) {
        if (!fb)
            fb = g_pHyprRenderer->createFB(name);
        if (!fb->isAllocated() || fb->m_size.x != w || fb->m_size.y != h)
            fb->alloc(w, h, DRM_FORMAT_ABGR8888);
        return fbId(fb) != 0;
    }

    void writeThumb(const std::string& file, int w, int h, const uint8_t* rgba) {
        // GL row 0 is the TOP of the picture for both sources: Hyprland's
        // projection draws the monitor y-flipped, and the window quad maps
        // texture row 0 (the app's top row) onto framebuffer row 0. (Writing
        // monitor rows bottom-up came out upside down next to grim.)
        std::string out = std::format("P6\n{} {}\n255\n", w, h);
        out.reserve(out.size() + (size_t)w * h * 3);
        for (int y = 0; y < h; y++) {
            const uint8_t* row = rgba + (size_t)y * w * 4;
            for (int x = 0; x < w; x++)
                out.append(reinterpret_cast<const char*>(row + x * 4), 3);
        }
        const std::string path = g_dir + "/" + file, tmp = path + ".tmp";
        const int         fd   = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0)
            return;
        const bool ok = write(fd, out.data(), out.size()) == (ssize_t)out.size();
        close(fd);
        if (!ok || rename(tmp.c_str(), path.c_str()) != 0)
            unlink(tmp.c_str());
    }

    // 0.57 caches the bound read/draw framebuffers, the active texture unit
    // and the viewport (OpenGL.cpp bindFramebuffer / setActiveTexture /
    // setViewport) and skips a GL call when the cache already matches. A raw
    // glBindFramebuffer / glActiveTexture here would leave that cache
    // believing something else, and Hyprland's next draw would silently land
    // in the wrong framebuffer or sample the wrong unit: always bind through
    // these.
    void bindFB(GLenum target, GLuint fbo) {
        Render::GL::g_pHyprOpenGL->bindFramebuffer(target, fbo);
    }

    // Into a pixel buffer, not client memory: glReadPixels returns at once and
    // the copy happens on the GPU's own time. `fbo` holds the w x h picture.
    // Always called inside an SGLStateGuard (it rebinds the read framebuffer).
    void startReadback(SReadback& rb, GLuint fbo, int w, int h) {
        GLint pack = 4;
        glGetIntegerv(GL_PACK_ALIGNMENT, &pack);
        bindFB(GL_READ_FRAMEBUFFER, fbo);
        if (!rb.pbo)
            glGenBuffers(1, &rb.pbo);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, rb.pbo);
        if (rb.w != w || rb.h != h) {
            glBufferData(GL_PIXEL_PACK_BUFFER, (GLsizeiptr)w * h * 4, nullptr, GL_STREAM_READ);
            rb.w = w;
            rb.h = h;
        }
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glPixelStorei(GL_PACK_ALIGNMENT, pack);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        if (rb.fence)
            glDeleteSync(rb.fence);
        // Flushed by Hyprland's end of frame (window pictures) or by
        // samplePendingMonitor (monitor pictures, taken after that flush).
        rb.fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    }

    // Never waits: a fence that hasn't signalled is simply checked next frame.
    void finishReadback(SReadback& rb, const std::string& file) {
        if (!rb.fence)
            return;
        const GLenum r = glClientWaitSync(rb.fence, 0, 0);
        if (r == GL_TIMEOUT_EXPIRED)
            return;
        glDeleteSync(rb.fence);
        rb.fence = nullptr;
        if (r == GL_WAIT_FAILED)
            return;
        glBindBuffer(GL_PIXEL_PACK_BUFFER, rb.pbo);
        if (const auto* px = static_cast<const uint8_t*>(glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, (GLsizeiptr)rb.w * rb.h * 4, GL_MAP_READ_BIT))) {
            writeThumb(file, rb.w, rb.h, px);
            glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    }

    void releaseReadback(SReadback& rb) {
        if (rb.fence)
            glDeleteSync(rb.fence);
        if (rb.pbo)
            glDeleteBuffers(1, &rb.pbo);
        rb = {};
    }

    // The pass scissors each element to its damage, and blits and draws obey
    // the scissor: left on, only the damaged corner of a picture would update.
    // Blending would mix the picture with whatever the framebuffer held. Raw
    // query + set + restore for those two, not Hyprland's cap cache (it can be
    // out of date). What GL had bound, its viewport and active texture unit
    // come back through Hyprland's own setters, so its caches end up true.
    struct SGLStateGuard {
        GLint     read = 0, draw = 0, unit = GL_TEXTURE0;
        GLint     viewport[4] = {0, 0, 0, 0};
        GLboolean scissor, blend;
        SGLStateGuard() {
            glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
            glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
            glGetIntegerv(GL_ACTIVE_TEXTURE, &unit);
            glGetIntegerv(GL_VIEWPORT, viewport);
            scissor = glIsEnabled(GL_SCISSOR_TEST);
            blend   = glIsEnabled(GL_BLEND);
            glDisable(GL_SCISSOR_TEST);
            glDisable(GL_BLEND);
        }
        ~SGLStateGuard() {
            bindFB(GL_READ_FRAMEBUFFER, read);
            bindFB(GL_DRAW_FRAMEBUFFER, draw);
            Render::GL::g_pHyprOpenGL->setActiveTexture(unit);
            Render::GL::g_pHyprOpenGL->setViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
            if (scissor)
                glEnable(GL_SCISSOR_TEST);
            if (blend)
                glEnable(GL_BLEND);
        }
    };

    // `src` is the finished frame as it goes to the screen.
    void sampleMonitor(const std::string& name, const SP<Render::IFramebuffer>& src) {
        const auto srcId = fbId(src);
        if (!srcId || src->m_size.x < 1 || src->m_size.y < 1)
            return;

        const int h = THUMB_H, w = std::max(8, (int)std::lround(THUMB_H * src->m_size.x / src->m_size.y));
        if (!ensureFB(g_half, "monitor-thumbs-half", w * 2, h * 2) || !ensureFB(g_small, "monitor-thumbs", w, h))
            return;

        SGLStateGuard guard;
        // GL_LINEAR averages the 2x2 texels around each sample point. Step one
        // takes 4 such points per final pixel, step two (an exact 2x) averages
        // them: 16 frame pixels behind every picture pixel.
        bindFB(GL_READ_FRAMEBUFFER, srcId);
        bindFB(GL_DRAW_FRAMEBUFFER, fbId(g_half));
        glBlitFramebuffer(0, 0, src->m_size.x, src->m_size.y, 0, 0, w * 2, h * 2, GL_COLOR_BUFFER_BIT, GL_LINEAR);
        bindFB(GL_READ_FRAMEBUFFER, fbId(g_half));
        bindFB(GL_DRAW_FRAMEBUFFER, fbId(g_small));
        glBlitFramebuffer(0, 0, w * 2, h * 2, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_LINEAR);
        startReadback(g_thumbs[name].rb, fbId(g_small), w, h);
    }

    // RENDER_POST: end() has copied the frame into the screen buffer and
    // Hyprland has already flushed (0.57 endRender: the frame's EGL sync fd /
    // glFlush), so flush the readback ourselves or its fence waits for the next
    // frame (an idle monitor may not have one). No render context is live here
    // (0.57 resets it in endRender); nothing below needs one.
    void samplePendingMonitor() {
        if (!g_pendingMonitor)
            return;
        const auto pending = std::move(*g_pendingMonitor);
        g_pendingMonitor.reset();
        const auto src = pending.out.lock();
        if (!src)
            return;
        Render::GL::g_pHyprOpenGL->makeEGLCurrent();
        sampleMonitor(pending.name, src);
        glFlush();
    }

    bool ensureWinShader() {
        if (g_winShader)
            return true;
        if (g_winShaderFailed)
            return false;
        auto sh = makeShared<CShader>();
        if (!sh->createProgram(Render::GL::g_pHyprOpenGL->m_shaders->TEXVERTSRC, WIN_FRAG, true)) {
            g_winShaderFailed = true;   // don't retry a broken compile every frame
            HyprlandAPI::addNotification(PHANDLE, "[monitor-thumbs] window shader failed to compile", CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
            return false;
        }
        g_tapStepLoc = glGetUniformLocation(sh->program(), "tapStep");
        g_winShader  = sh;
        return true;
    }

    PHLWINDOW windowAt(uintptr_t address) {
        for (const auto& w : Desktop::windowState()->windows())
            if (w && (uintptr_t)w.get() == address)
                return w;
        return nullptr;
    }

    void sampleWindows() {
        auto requests = std::move(g_winRequests);
        g_winRequests.clear();
        if (!ensureWinShader())
            return;

        SGLStateGuard guard;
        auto          sh = Render::GL::g_pHyprOpenGL->useShader(g_winShader);
        sh->setUniformMatrix3fv(SHADER_PROJ, 1, GL_FALSE, FULLSCREEN);
        // Unit 8: the compositor caches what it believes is bound on the low
        // units (hyprwater's rule).
        sh->setUniformInt(SHADER_TEX, 8);
        glBindVertexArray(sh->getUniformLocation(SHADER_SHADER_VAO));
        Render::GL::g_pHyprOpenGL->setActiveTexture(GL_TEXTURE8);

        for (const auto& rq : requests) {
            const auto win = windowAt(rq.address);
            if (!win || !win->mapped() || !win->wlSurface() || !win->wlSurface()->resource())
                continue;
            const auto tex = win->wlSurface()->resource()->m_current.texture;
            // External (EGLImage-only, e.g. YUV video) textures need another
            // sampler type: no picture, the bar shows the app icon instead.
            if (!tex || !tex->m_texID || tex->m_type == Render::TEXTURE_EXTERNAL || tex->m_size.x < 1 || tex->m_size.y < 1)
                continue;
            if (!ensureFB(g_winFb, "monitor-thumbs-window", rq.w, rq.h))
                continue;

            bindFB(GL_FRAMEBUFFER, fbId(g_winFb));
            Render::GL::g_pHyprOpenGL->setViewport(0, 0, rq.w, rq.h);
            tex->bind();
            // Through the texture's own setter: it caches these, and a raw
            // glTexParameteri would leave its cache believing something else.
            tex->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            tex->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            tex->setTexParameter(GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            tex->setTexParameter(GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glUniform2f(g_tapStepLoc, 0.25f / rq.w, 0.25f / rq.h);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

            // Same "{:x}" as hyprctl clients' "stableId" (the helper's file name).
            startReadback(g_winReads[std::format("win-{:x}", win->metadata().stableID())], fbId(g_winFb), rq.w, rq.h);
        }

        glBindVertexArray(0);   // the guard puts the active texture unit back
    }

    // Any frame's start (GL context current): pick up finished readbacks.
    void collect() {
        for (auto& [name, t] : g_thumbs)
            finishReadback(t.rb, "mon-" + name + ".ppm");
        for (auto& [key, rb] : g_winReads)
            finishReadback(rb, key + ".ppm");
    }

    // Window pictures only: they come from each window's own texture, which no
    // damage affects, so any point in the pass will do.
    class CThumbPassElement : public IPassElement {
      public:
        std::vector<UP<IPassElement>> draw(Render::CRenderContext&) override {
            sampleWindows();
            return {};
        }
        bool                needsLiveBlur(Render::CRenderContext&) override { return false; }
        bool                needsPrecomputeBlur(Render::CRenderContext&) override { return false; }
        const char*         passName() override { return "CThumbPassElement"; }
        ePassElementType    type() override { return EK_CUSTOM; }
        bool                undiscardable(Render::CRenderContext&) override { return true; }   // runs whatever the damage
        std::optional<CBox> boundingBox(Render::CRenderContext&) override { return std::nullopt; }
    };

    // 0.57 hands each stage its monitor and (BEGIN..LAST_MOMENT) the frame's
    // render context; the renderer no longer has a global m_renderData /
    // m_renderPass.
    void onStage(const Event::SRenderStageEvent& ev) {
        if (ev.stage == RENDER_BEGIN) {
            collect();
            return;
        }
        if (ev.stage == RENDER_POST) {
            samplePendingMonitor();
            return;
        }
        if (ev.stage != RENDER_LAST_MOMENT || !ev.context)
            return;
        auto&      ctx = ev.context->get();
        const auto mon = ev.monitor;
        if (!mon)
            return;

        g_pendingMonitor.reset();
        // A rotated monitor's frame is stored sideways; nothing here turns it.
        if (mon->m_transform == WL_OUTPUT_TRANSFORM_NORMAL && mon->m_name.find('/') == std::string::npos) {
            auto&      t   = g_thumbs[mon->m_name];
            const auto now = Time::steadyNow();
            if (!t.rb.fence && now >= t.due) {
                if (const auto out = ctx.m_data.outFB) {
                    t.due            = now + EVERY;
                    g_pendingMonitor = SPendingMonitor{mon->m_name, out};
                }
            }
        }
        if (!g_winRequests.empty())
            ctx.m_pass.add(makeUnique<CThumbPassElement>());
    }

    void onWorkspace(PHLWORKSPACE ws) {
        const auto mon = ws ? ws->m_monitor.lock() : nullptr;
        if (!mon)
            return;
        auto&      t    = g_thumbs[mon->m_name];
        const auto soon = Time::steadyNow() + AFTER_SWITCH;
        if (soon < t.due)
            t.due = soon;
    }

    // Window pictures are asked for on demand, and an idle desktop may not
    // draw the frame that takes them, or the one after that collects them.
    // One pixel of damage gets a (cheap) frame without redrawing a screen —
    // on the monitor under the pointer, which is where the bar is being
    // hovered. Never "the first monitor": that can be a fullscreen game on
    // direct scanout, which this extra frame would only get in the way of.
    void kickFrame() {
        const auto pos = g_pInputManager->getMouseCoordsInternal();
        PHLMONITOR pick;
        for (const auto& m : State::monitorState()->monitors())
            if (m && m->m_enabled && m->logicalBox().containsPoint(pos)) {
                pick = m;
                break;
            }
        if (!pick)
            return;
        pick->addDamage(CBox{0, 0, 1, 1});
        pick->scheduleFrame();
    }

    bool windowWorkPending() {
        if (!g_winRequests.empty())
            return true;
        for (const auto& [key, rb] : g_winReads)
            if (rb.fence)
                return true;
        return false;
    }

    // Outside rendering (damage added mid-frame can be dropped with that
    // frame's damage). Re-arms itself until every requested picture is written.
    void onKickTimer(SP<CEventLoopTimer> self, void*) {
        if (!windowWorkPending())
            return;
        kickFrame();
        self->updateTimeout(std::chrono::milliseconds(8));
    }

    // "monitorthumbs window <0xaddress> <w> <h> [; <0xaddress> <w> <h> ...]"
    // Registered as a prefix match, so `command` is the whole request after
    // hyprctl's flags (as 0.56's non-exact SHyprCtlCommand got it).
    IPC::Socket1::SResponse onCommand(const IPC::Socket1::SRequest& req) {
        std::string request = req.command;
        for (auto& c : request)
            if (c == ';')
                c = ' ';
        std::istringstream in(request);
        std::string        word;
        in >> word >> word;   // "monitorthumbs" "window"
        if (word != "window")
            return "error: usage: monitorthumbs window <address> <w> <h> [; ...]";
        int         queued = 0;
        std::string addr;
        int         w = 0, h = 0;
        while (in >> addr >> w >> h) {
            if (w < 1 || h < 1 || w > MAX_WIN_SIDE || h > MAX_WIN_SIDE)
                continue;
            uintptr_t a = 0;
            try {
                a = std::stoull(addr, nullptr, 16);
            } catch (...) { continue; }
            g_winRequests.push_back({a, w, h});
            queued++;
        }
        if (queued && g_kickTimer)
            g_kickTimer->updateTimeout(std::chrono::milliseconds(0));
        return std::format("ok {}", queued);
    }
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();
    if (HASH != CLIENT_HASH) {
        HyprlandAPI::addNotification(PHANDLE, "[monitor-thumbs] Version mismatch!", CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        throw std::runtime_error("Version mismatch");
    }

    g_dir = g_pCompositor->m_instancePath + "/monitor-thumbs";
    std::error_code ec;
    std::filesystem::create_directories(g_dir, ec);
    std::filesystem::permissions(g_dir, std::filesystem::perms::owner_all, ec);

    g_stageListener     = Event::bus()->m_events.render.stage.listen([](const Event::SRenderStageEvent& ev) { onStage(ev); });
    g_workspaceListener = Event::bus()->m_events.workspace.active.listen([](PHLWORKSPACE ws) { onWorkspace(ws); });
    g_command           = HyprlandAPI::registerHyprCtlCommand(PHANDLE, IPC::Socket1::SCommand{"monitorthumbs", IPC::Socket1::COMMAND_MATCH_PREFIX, onCommand});
    g_kickTimer         = makeShared<CEventLoopTimer>(std::nullopt, onKickTimer, nullptr);
    g_pEventLoopManager->addTimer(g_kickTimer);

    return {"monitor-thumbs", "Tiny monitor and window pictures for the bar, from images Hyprland already has", "Swill Software", "1.3"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    // The event loop holds the timer and its callback into this .so: remove it,
    // not just cancel it, or it fires into unmapped code (hyprwater, 2026-08).
    if (g_kickTimer) {
        g_pEventLoopManager->removeTimer(g_kickTimer);
        g_kickTimer->cancel();
        g_kickTimer.reset();
    }
    if (g_command)
        HyprlandAPI::unregisterHyprCtlCommand(PHANDLE, g_command);
    g_command.reset();
    g_stageListener.reset();
    g_workspaceListener.reset();
    // A pass element queued but not yet drawn would call into unmapped code.
    g_pHyprRenderer->context().m_pass.removeAllOfType("CThumbPassElement");

    Render::GL::g_pHyprOpenGL->makeEGLCurrent();
    for (auto& [name, t] : g_thumbs)
        releaseReadback(t.rb);
    for (auto& [key, rb] : g_winReads)
        releaseReadback(rb);
    g_thumbs.clear();
    g_winReads.clear();
    g_winRequests.clear();
    g_pendingMonitor.reset();
    g_half.reset();
    g_small.reset();
    g_winFb.reset();
    g_winShader.reset();

    std::error_code ec;
    std::filesystem::remove_all(g_dir, ec);
}
