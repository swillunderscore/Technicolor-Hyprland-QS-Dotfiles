// minimize-requests — an app's OWN minimize request goes to the minimized shelf.
//
// WHY: Hyprland has no minimize. When an app asks to be minimized — its own
// title-bar button (Window buttons on), Steam's button, an X11 iconify — 0.57
// receives the request and drops it: the window backend emits stateRequest
// with .minimized set, and CWindow::onUpdateState (Window.cpp:841 in v0.57.0)
// forwards only fullscreen and maximized. 0.57's Lua `window.minimize` event
// does NOT cover this; it fires only for TASKBAR requests (wlr-foreign-toplevel).
//
// WHAT: listen to every window's backend stateRequest and pass a minimize
// request on as the socket2 event minimize-watcher.sh was written for:
//     minimize>>ADDRESS,1   stash on special:minimized (same as Super+scroll)
//     minimize>>ADDRESS,0   un-minimize: current workspace, focus, raise
// The watcher owns what happens; this only delivers the request. Only requests
// that change something are passed on: minimize when the window is NOT on the
// shelf, un-minimize only when it IS (an app saying "un-minimize" from a normal
// workspace must not yank it to the current one).

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowBackend.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/ipc/s2/S2.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>

#include <format>
#include <unordered_map>

inline HANDLE PHANDLE = nullptr;

namespace {
    constexpr const char* SHELF = "special:minimized";

    CHyprSignalListener                                         g_openListener;
    CHyprSignalListener                                         g_destroyListener;
    std::unordered_map<const Desktop::View::CWindow*, CHyprSignalListener> g_requestListeners;

    void onStateRequest(const PHLWINDOWREF& ref, const Desktop::View::SBackendStateRequest& request) {
        if (!request.minimized.has_value())
            return;

        const auto window = ref.lock();
        if (!window || !window->mapped())
            return;

        const bool wantsMinimized = *request.minimized;
        const bool onShelf        = window->m_workspace && window->m_workspace->addressableName() == SHELF;
        if (wantsMinimized == onShelf)
            return; // already where it asked to be

        if (const auto& s2 = IPC::Socket2::sock())
            s2->postEvent({"minimize", std::format("{:x},{}", rc<uintptr_t>(window.get()), wantsMinimized ? 1 : 0)});
    }

    void watch(const PHLWINDOW& window) {
        if (!window)
            return;
        PHLWINDOWREF ref = window;
        // Keyed by window: a re-mapped window replaces its old listener.
        g_requestListeners[window.get()] = window->backend().m_events.stateRequest.listen(
            [ref](const Desktop::View::SBackendStateRequest& request) { onStateRequest(ref, request); });
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
        HyprlandAPI::addNotification(PHANDLE, "[minimize-requests] Version mismatch!", CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        throw std::runtime_error("Version mismatch");
    }

    for (const auto& w : Desktop::viewState()->windows())   // windows already open at load
        if (w && w->mapped())
            watch(w);

    g_openListener    = Event::bus()->m_events.window.open.listen([](PHLWINDOW w) { watch(w); });
    g_destroyListener = Event::bus()->m_events.window.destroy.listen([](PHLWINDOWREF ref) {
        if (const auto w = ref.lock())
            g_requestListeners.erase(w.get());
    });

    return {"minimize-requests", "Sends an app's own minimize request to the minimized shelf", "Swill Software", "1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_openListener.reset();
    g_destroyListener.reset();
    g_requestListeners.clear();
}
