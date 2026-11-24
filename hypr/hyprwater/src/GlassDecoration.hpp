#pragma once

#include "GlassRenderer.hpp"
#include "PluginConfig.hpp"

#include <hyprland/src/desktop/view/window/Window.hpp>   // 0.57: views moved into view/window/
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/WindowRenderPresentation.hpp>

class CGlassDecoration : public IHyprWindowDecoration {
  public:
    explicit CGlassDecoration(PHLWINDOW window);
    ~CGlassDecoration() override = default;

    [[nodiscard]] SDecorationPositioningInfo getPositioningInfo() override;
    void                                     onPositioningReply(const SDecorationPositioningReply& reply) override;
    // 0.57: the render context and the window's resolved presentation (workspace /
    // floating offsets) are passed in explicitly instead of read from renderer globals.
    void                                     draw(Render::CRenderContext& ctx, PHLMONITOR monitor, float const& alpha,
                                                  const Render::SWindowRenderPresentation& presentation) override;
    [[nodiscard]] eDecorationType            getDecorationType() override;
    void                                     updateWindow(PHLWINDOW window) override;
    void                                     damageEntire() override;
    [[nodiscard]] eDecorationLayer           getDecorationLayer() override;
    [[nodiscard]] uint64_t                   getDecorationFlags() override;
    [[nodiscard]] std::string                getDisplayName() override;

    [[nodiscard]] PHLWINDOW getOwner();
    void                    renderPass(Render::CRenderContext& rctx, PHLMONITOR monitor, const float& alpha,
                                       const Render::SWindowRenderPresentation& presentation);

    // Adaptive tint on this window and its glass drawn within the last second
    // (i.e. on screen). See draw() for why that needs whole-glass redraws.
    [[nodiscard]] bool adaptiveActive() const;
    // Add the whole glass box to `monitor`'s pending damage WITHOUT scheduling a
    // frame. For use just before a frame renders (render.pre), so it joins that
    // frame instead of asking for another.
    void damageGlassOn(PHLMONITOR monitor);

    WP<CGlassDecoration> m_self;

  private:
    PHLWINDOWREF m_window;
    SP<Render::IFramebuffer> m_sampleFramebuffer;
    SP<Render::IFramebuffer> m_sampleHalfFramebuffer;   // see sampleBackground()
    // Per-window blur ping-pong scratch. Sized to THIS window's sample, so it
    // must not be shared with other decorations — see blurBackground().
    SP<Render::IFramebuffer> m_blurTempFramebuffer;
    // 1x1 ping-pong holding this window's time-smoothed average backdrop luma.
    // A fragment shader has no memory between frames; this is that memory.
    GlassRenderer::SAdaptiveLumaState m_luma;
    Vector2D     m_samplePaddingRatio;

    // Track last rendered position/size to detect actual changes and seed damage
    Vector2D m_lastPosition;
    Vector2D m_lastSize;

    std::chrono::steady_clock::time_point m_lastAdaptiveDraw{};

    [[nodiscard]] bool        adaptiveApplies() const;
    // The glass's damage box in global logical coords, padded by the sample
    // margin. Empty if the window is gone.
    [[nodiscard]] CBox        glassDamageBox() const;
    [[nodiscard]] bool        resolveEnabled() const;
    [[nodiscard]] bool        resolveThemeIsDark() const;
    [[nodiscard]] std::string resolvePresetName() const;

    friend class CGlassPassElement;
};
