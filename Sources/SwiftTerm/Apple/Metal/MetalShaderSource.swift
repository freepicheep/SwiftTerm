#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
// Generated from Shaders.metal by scripts/embed-metal-shaders.sh.
// Do not edit this string directly.
let swiftTermMetalShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct GlyphVertex {
    float2 position;
    float2 texCoord;
    float4 color;
};

struct TextCell {
    float2 position;
    float2 size;
    float2 texOrigin;
    float2 texSize;
    float4 color;
};

struct ColorCell {
    float2 position;
    float2 size;
    float4 color;
};

struct GlyphOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

constant float2 kQuadCorners[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 0.0),
    float2(1.0, 1.0),
    float2(0.0, 1.0),
};

vertex GlyphOut terminal_text_vertex(uint vid [[vertex_id]],
                                     const device GlyphVertex *vertices [[buffer(0)]],
                                     constant float4 &viewport [[buffer(1)]]) {
    GlyphVertex v = vertices[vid];
    float2 ndc = float2(((v.position.x + viewport.z) / viewport.x) * 2.0 - 1.0,
                        ((v.position.y + viewport.w) / viewport.y) * 2.0 - 1.0);
    GlyphOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = v.texCoord;
    out.color = v.color;
    return out;
}

vertex GlyphOut terminal_cell_text_vertex(uint vid [[vertex_id]],
                                          const device TextCell *cells [[buffer(0)]],
                                          constant float4 &viewport [[buffer(1)]]) {
    uint cellIndex = vid / 6;
    uint cornerIndex = vid % 6;
    TextCell cell = cells[cellIndex];
    float2 corner = kQuadCorners[cornerIndex];
    float2 position = cell.position + cell.size * corner;
    float2 ndc = float2(((position.x + viewport.z) / viewport.x) * 2.0 - 1.0,
                        ((position.y + viewport.w) / viewport.y) * 2.0 - 1.0);
    GlyphOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = cell.texOrigin + cell.texSize * corner;
    out.color = cell.color;
    return out;
}

fragment float4 terminal_text_fragment(GlyphOut in [[stage_in]],
                                       texture2d<float> atlas [[texture(0)]],
                                       sampler samp [[sampler(0)]]) {
    float4 tex = atlas.sample(samp, in.texCoord);
    return float4(tex.rgb * in.color.rgb, tex.a * in.color.a);
}

fragment float4 terminal_text_fragment_gray(GlyphOut in [[stage_in]],
                                            texture2d<float> atlas [[texture(0)]],
                                            sampler samp [[sampler(0)]]) {
    float coverage = atlas.sample(samp, in.texCoord).r;
    return float4(in.color.rgb * coverage, in.color.a * coverage);
}

struct ColorVertex {
    float2 position;
    float4 color;
};

struct ColorOut {
    float4 position [[position]];
    float4 color;
};

vertex ColorOut terminal_color_vertex(uint vid [[vertex_id]],
                                      const device ColorVertex *vertices [[buffer(0)]],
                                      constant float4 &viewport [[buffer(1)]]) {
    ColorVertex v = vertices[vid];
    float2 ndc = float2(((v.position.x + viewport.z) / viewport.x) * 2.0 - 1.0,
                        ((v.position.y + viewport.w) / viewport.y) * 2.0 - 1.0);
    ColorOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = v.color;
    return out;
}

vertex ColorOut terminal_cell_color_vertex(uint vid [[vertex_id]],
                                           const device ColorCell *cells [[buffer(0)]],
                                           constant float4 &viewport [[buffer(1)]]) {
    uint cellIndex = vid / 6;
    uint cornerIndex = vid % 6;
    ColorCell cell = cells[cellIndex];
    float2 corner = kQuadCorners[cornerIndex];
    float2 position = cell.position + cell.size * corner;
    float2 ndc = float2(((position.x + viewport.z) / viewport.x) * 2.0 - 1.0,
                        ((position.y + viewport.w) / viewport.y) * 2.0 - 1.0);
    ColorOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = cell.color;
    return out;
}

fragment float4 terminal_color_fragment(ColorOut in [[stage_in]]) {
    return in.color;
}

// A rounded selection: each row's run of cells with its own corner radii, and
// fillets that round the inside corners where one row's run meets the next.
struct SelectionCell {
    float2 position;
    float2 size;
    float4 color;
    float4 radii;   // top left, top right, bottom right, bottom left
    float4 shape;   // x: 0 run, 1 fillet; fillet: yz centre, w radius
};

struct SelectionOut {
    float4 position [[position]];
    float2 local;
    float2 size [[flat]];
    float4 color [[flat]];
    float4 radii [[flat]];
    float4 shape [[flat]];
};

vertex SelectionOut terminal_selection_vertex(uint vid [[vertex_id]],
                                              const device SelectionCell *cells [[buffer(0)]],
                                              constant float4 &viewport [[buffer(1)]]) {
    SelectionCell cell = cells[vid / 6];
    float2 corner = kQuadCorners[vid % 6];
    float2 position = cell.position + cell.size * corner;
    float2 ndc = float2(((position.x + viewport.z) / viewport.x) * 2.0 - 1.0,
                        ((position.y + viewport.w) / viewport.y) * 2.0 - 1.0);
    SelectionOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.local = cell.size * corner;
    out.size = cell.size;
    out.color = cell.color;
    out.radii = cell.radii;
    out.shape = cell.shape;
    return out;
}

// Straight edges stay as crisp as the cells' own backgrounds, so rows meet with
// no seam; only the arcs are smoothed, by a pixel.
fragment float4 terminal_selection_fragment(SelectionOut in [[stage_in]]) {
    float coverage = 1.0;
    if (in.shape.x < 0.5) {
        float2 halfSize = in.size * 0.5;
        float2 p = in.local - halfSize;
        float r = p.x < 0.0 ? (p.y > 0.0 ? in.radii.x : in.radii.w)
                            : (p.y > 0.0 ? in.radii.y : in.radii.z);
        float2 q = abs(p) - (halfSize - r);
        if (r > 0.0 && q.x > 0.0 && q.y > 0.0) {
            coverage = clamp(r - length(q) + 0.5, 0.0, 1.0);
        }
    } else {
        coverage = clamp(length(in.local - in.shape.yz) - in.shape.w + 0.5, 0.0, 1.0);
    }
    return float4(in.color.rgb, in.color.a * coverage);
}

// A cursor on its way between cells (TerminalView.cursorMotion): four corners
// that each ease toward the cell on their own, so the quad can draw out along
// its path. Its edges are smoothed by a pixel.
struct CursorQuad {
    float2 c0;
    float2 c1;
    float2 c2;
    float2 c3;
    float4 color;
};

struct CursorQuadOut {
    float4 position [[position]];
    float2 pixel;
};

vertex CursorQuadOut terminal_cursor_vertex(uint vid [[vertex_id]],
                                            constant CursorQuad &quad [[buffer(0)]],
                                            constant float4 &viewport [[buffer(1)]]) {
    float2 lo = min(min(quad.c0, quad.c1), min(quad.c2, quad.c3)) - 1.0;
    float2 hi = max(max(quad.c0, quad.c1), max(quad.c2, quad.c3)) + 1.0;
    float2 pixel = mix(lo, hi, kQuadCorners[vid]);
    CursorQuadOut out;
    out.position = float4(((pixel.x + viewport.z) / viewport.x) * 2.0 - 1.0,
                          ((pixel.y + viewport.w) / viewport.y) * 2.0 - 1.0, 0.0, 1.0);
    out.pixel = pixel;
    return out;
}

fragment float4 terminal_cursor_fragment(CursorQuadOut in [[stage_in]],
                                         constant CursorQuad &quad [[buffer(0)]]) {
    float2 c[4] = { quad.c0, quad.c1, quad.c2, quad.c3 };
    float area = 0.0;
    for (int i = 0; i < 4; i++) {
        float2 a = c[i];
        float2 b = c[(i + 1) % 4];
        area += a.x * b.y - b.x * a.y;
    }
    float turn = area >= 0.0 ? 1.0 : -1.0;
    // How far inside every edge the pixel is; negative outside one.
    float inside = 1e6;
    for (int i = 0; i < 4; i++) {
        float2 a = c[i];
        float2 e = c[(i + 1) % 4] - a;
        float size = sqrt(dot(e, e));
        if (size < 1e-3) {
            continue;
        }
        float2 w = in.pixel - a;
        inside = min(inside, turn * (e.x * w.y - e.y * w.x) / size);
    }
    float coverage = clamp(inside + 0.5, 0.0, 1.0);
    return float4(quad.color.rgb, quad.color.a * coverage);
}
"""#
#endif
#endif
