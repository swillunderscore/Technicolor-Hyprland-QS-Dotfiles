#include "GlassLayerCompositeElement.hpp"
#include "GlassLayerSurface.hpp"
#include "GlassRenderer.hpp"
#include "Globals.hpp"
#include "LayerGeometry.hpp"

#include <cmath>

CGlassLayerCompositeElement::CGlassLayerCompositeElement(const SGlassLayerCompositeData& data)
    : m_data(data) {}

std::vector<UP<IPassElement>> CGlassLayerCompositeElement::draw(Render::CRenderContext& ctx) {
    if (m_data.layerState && m_data.layerState->getLayerSurface())
        m_data.layerState->compositeAndRestore(ctx, ctx.m_data.pMonitor.lock(), m_data.alpha);

    return {};
}

std::optional<CBox> CGlassLayerCompositeElement::boundingBox(Render::CRenderContext& ctx) {
    if (!m_data.layerState)
        return std::nullopt;

    auto layerSurface = m_data.layerState->getLayerSurface();
    if (!layerSurface)
        return std::nullopt;

    const auto monitor = ctx.m_data.pMonitor.lock();
    auto box = LayerGeometry::computeLayerBox(layerSurface, monitor);
    if (!box)
        return std::nullopt;

    const float scale = monitor->m_scale > 0.0f ? monitor->m_scale : 1.0f;
    box->scale(1.0 / scale).expand(GlassRenderer::SAMPLE_PADDING_PX / scale).noNegativeSize().round();
    if (!std::isfinite(box->x) || !std::isfinite(box->y) || !std::isfinite(box->w) || !std::isfinite(box->h) || box->w <= 0.0 || box->h <= 0.0)
        return std::nullopt;

    return box;
}

bool CGlassLayerCompositeElement::needsLiveBlur(Render::CRenderContext& ctx) {
    return false;
}

bool CGlassLayerCompositeElement::needsPrecomputeBlur(Render::CRenderContext& ctx) {
    return false;
}
