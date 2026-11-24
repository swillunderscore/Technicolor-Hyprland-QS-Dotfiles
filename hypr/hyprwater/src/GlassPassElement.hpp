#pragma once

#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprutils/math/Box.hpp>
#include <hyprutils/math/Region.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/render/WindowRenderPresentation.hpp>

class CGlassDecoration;

class CGlassPassElement : public IPassElement {
  public:
    struct SGlassPassData {
        WP<CGlassDecoration> decoration;
        float                alpha = 1.0f;
        // 0.57: the presentation the window was drawn with (workspace + floating
        // offset). Hyprland now resolves it once per draw and places the window
        // with it, so the glass box must use the same one.
        Render::SWindowRenderPresentation presentation;
    };

    explicit CGlassPassElement(const SGlassPassData& data);
    ~CGlassPassElement() override = default;

    // 0.57: every pass-element hook receives the render context explicitly.
    std::vector<UP<IPassElement>> draw(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool                needsLiveBlur(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool                needsPrecomputeBlur(Render::CRenderContext& ctx) override;
    [[nodiscard]] std::optional<CBox> boundingBox(Render::CRenderContext& ctx) override;
    [[nodiscard]] bool                disableSimplification(Render::CRenderContext& ctx) override;

    [[nodiscard]] const char* passName() override { return "CGlassPassElement"; }
    [[nodiscard]] ePassElementType type() override { return EK_CUSTOM; }

  private:
    SGlassPassData m_data;
};
