#pragma once

#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/WindowRenderPresentation.hpp>
#include <hyprutils/math/Box.hpp>
#include <optional>

namespace WindowGeometry {

// 0.57: Hyprland resolves a window's workspace offset (zero when pinned) and
// floating offset into an SWindowRenderPresentation before drawing it, and
// places the window surface with exactly those two vectors. The glass box uses
// the same presentation so it sits where the window is drawn.
[[nodiscard]] inline std::optional<CBox> computeWindowBox(PHLWINDOW window, PHLMONITOR monitor,
                                                          const Render::SWindowRenderPresentation& presentation) {
    if (!window || !monitor)
        return std::nullopt;

    auto box = window->getWindowMainSurfaceBox();
    box.translate(presentation.workspaceOffset);
    box.translate(-monitor->m_position + presentation.floatingOffset);
    box.scale(monitor->m_scale);
    box.round();
    return box;
}

} // namespace WindowGeometry
