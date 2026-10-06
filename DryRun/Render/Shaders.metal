#include <metal_stdlib>
using namespace metal;

// Shared layout with WallRenderer.swift. Every member is 16-byte aligned and a multiple of 16
// long, so MSL's packed `float3` cannot drift from Swift's 16-byte `SIMD3`. Scalars are grouped
// into float4s for the same reason.
struct WallUniforms {
    float4x4 modelViewProjection;   //   0  anchor -> clip
    float3x3 cameraUVTransform;     //  64  screen UV -> camera-image UV
    float3x3 reprojection;          // 112  this frame's screen UV -> last frame's, via the plane
    float4   paint;                 // 160  xyz paint reflectance, linear and adapted; w mean luma
    float4   meanWall;              // 176  xyz mean linear RGB inside the mask; w digital zoom
    float4   viewport;              // 192  xy viewport pixels; z detail gain; w edge feather
    float4   edges;                 // 208  xy one depth texel in screen UV; z band; w ramp
    float4   tuning;                // 224  x range slack; y hysteresis; z planarity; w blend
};
static_assert(sizeof(WallUniforms) == 240, "WallUniforms must stay 240 bytes; Swift mirrors it");

// ARKit delivers 420YpCbCr8BiPlanarFullRange. Full-range BT.601, matching Apple's ARKit samples.
constant float4x4 kYCbCrToRGB = float4x4(
    float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
    float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
    float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
    float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
);

constant float3 kLumaWeights = float3(0.2126729f, 0.7151522f, 0.0721750f);

// Depth agreement band behind the fitted plane, in metres.
constant float kOpeningBand = 0.12f;

// Ramp width for the opening test; a binary accept/reject quantises every edge.
constant float kOpeningSoftZone = 0.05f;

// Guide sensitivity for the cross-bilateral refinement, against gamma-encoded luma.
constant float kGuideSigma = 0.08f;

// Beyond roughly this range the LiDAR stops returning, so an absent sample means nothing.
constant float kDepthRange = 4.5f;

// Planarity taps sit this many depth texels out. Far enough that an adjoining surface has climbed
// clear of LiDAR noise, near enough that the test does not erode a real wall boundary.
constant float kPlanarityReach = 3.0f;

static inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}

static inline float3 linearToSRGB(float3 c) {
    c = max(c, 0.0f);
    return select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, c * 12.92f, c <= 0.0031308f);
}

/// Maps a viewport-relative UV into the camera image, which is captured landscape-native.
///
/// `zoom` is applied here so colour, depth and the bilateral guide crop identically. The wall
/// geometry is magnified to match in `wallMaskVertex`.
static inline float2 cameraUV(float2 screenUV, float3x3 m, float zoom) {
    float2 cropped = (screenUV - 0.5f) / max(zoom, 1e-3f) + 0.5f;
    return (m * float3(cropped, 1.0f)).xy;
}

static inline float3 sampleCameraLinear(texture2d<float> yTex,
                                        texture2d<float> cbcrTex,
                                        float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 ycbcr = float4(yTex.sample(s, uv).r, cbcrTex.sample(s, uv).rg, 1.0f);
    return srgbToLinear(saturate((kYCbCrToRGB * ycbcr).rgb));
}

/// Where `screenUV` sat in the previous frame, or a negative marker if it was off screen.
///
/// Exact for the painted region because that region is a plane, so one homography describes the
/// whole warp. Newly revealed screen edges have no history and must fall back to this frame.
static inline float2 reproject(float2 screenUV, float3x3 warp) {
    float3 h = warp * float3(screenUV, 1.0f);
    if (abs(h.z) < 1e-6f) { return float2(-1.0f); }
    float2 previous = h.xy / h.z;
    if (any(previous < 0.0f) || any(previous > 1.0f)) { return float2(-1.0f); }
    return previous;
}

// MARK: - Pass A: wall mask + masked luma

struct MaskVertexOut {
    float4 position [[position]];
};

/// Rasterises the selected wall plane's geometry into the mask buffer.
vertex MaskVertexOut wallMaskVertex(uint vid [[vertex_id]],
                                    const device float3 *positions [[buffer(0)]],
                                    constant WallUniforms &u [[buffer(1)]]) {
    MaskVertexOut out;
    out.position = u.modelViewProjection * float4(positions[vid], 1.0f);
    // Clip space spans [-w, w], so scaling xy magnifies about the centre; w is left alone.
    out.position.xy *= u.meanWall.w;
    return out;
}

/// Agreement between the measured depth field and the fitted plane over a small neighbourhood.
///
/// A single depth comparison cannot separate the wall from a ceiling or an adjoining wall near
/// their junction, because there the two surfaces very nearly touch. Their *slopes* differ
/// everywhere, though. `slope` is the plane's own screen-space depth gradient, which is smooth
/// because it comes from an interpolated attribute rather than a texture fetch.
static inline float planarity(texture2d<float> depthTex,
                              constant WallUniforms &u,
                              float2 screenUV,
                              float fragmentDepth,
                              float2 slope,
                              float zoom) {
    float tolerance = u.tuning.z;
    if (tolerance <= 0.0f) { return 1.0f; }

    constexpr sampler ds(filter::nearest, address::clamp_to_edge);
    const float2 directions[4] = { float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1) };
    float2 stepUV = u.edges.xy * kPlanarityReach;
    float2 stepPixels = stepUV * u.viewport.xy;

    float worst = 0.0f;
    for (int i = 0; i < 4; ++i) {
        float2 direction = directions[i];
        float2 tapCam = cameraUV(screenUV + direction * stepUV, u.cameraUVTransform, zoom);
        if (any(tapCam < 0.0f) || any(tapCam > 1.0f)) { continue; }

        float measured = depthTex.sample(ds, tapCam).r;
        if (measured <= 0.0f) { continue; }

        float predicted = fragmentDepth + dot(slope, direction * stepPixels);
        worst = max(worst, abs(measured - predicted));
    }
    // One texel of LiDAR noise is unavoidable, so the ramp opens at the tolerance, not at zero.
    return 1.0f - smoothstep(tolerance, tolerance * 2.0f, worst);
}

/// Writes coverage in `.r` and mask-weighted linear RGB in `.gba`.
///
/// One blur downstream divides them: a normalised convolution that does not bleed in pixels from
/// outside the mask, and that carries illuminant colour rather than luma alone.
fragment float4 wallMaskFragment(MaskVertexOut in [[stage_in]],
                                 texture2d<float> yTex       [[texture(0)]],
                                 texture2d<float> cbcrTex    [[texture(1)]],
                                 texture2d<float> depthTex   [[texture(2)]],
                                 texture2d<float> historyTex [[texture(3)]],
                                 constant WallUniforms &u [[buffer(1)]],
                                 constant int &hasDepth [[buffer(2)]]) {
    float zoom = u.meanWall.w;
    float2 screenUV = in.position.xy / u.viewport.xy;

    // Taken before any branch: a derivative inside non-uniform control flow is undefined.
    float fragmentDepth = 1.0f / in.position.w;   // [[position]].w is 1/w_clip
    float2 depthSlope = float2(dfdx(fragmentDepth), dfdy(fragmentDepth));

    float2 uv = cameraUV(screenUV, u.cameraUVTransform, zoom);

    // Zoomed below 1 the sample can fall outside the frame.
    if (any(uv < 0.0f) || any(uv > 1.0f)) { return float4(0.0f); }

    // ARKit tessellates a plane anchor as a filled polygon and never cuts holes, so a doorway
    // arrives as solid geometry. Nearest sampling: linear invents depths inside the band.
    float coverage = 1.0f;

    if (hasDepth != 0) {
        constexpr sampler ds(filter::nearest, address::clamp_to_edge);
        float sceneDepth = depthTex.sample(ds, uv).r;          // metres

        if (sceneDepth > 0.0f) {
            // Hysteresis: a fragment that was wall last frame is held to a looser threshold, so
            // depth noise at the boundary cannot dither it in and out every frame.
            float slack = 0.0f;
            if (u.tuning.w < 1.0f) {
                constexpr sampler hs(filter::linear, address::clamp_to_edge);
                float2 previous = reproject(screenUV, u.reprojection);
                if (previous.x >= 0.0f && historyTex.sample(hs, previous).r > 0.5f) {
                    slack = u.tuning.y;
                }
            }

            float delta = sceneDepth - fragmentDepth;
            // In front: a TV, a picture frame, furniture, a person, trim.
            float tolerance = u.edges.z + u.tuning.x * sceneDepth + slack;
            float nearWeight = smoothstep(-tolerance - max(u.edges.w, 1e-4f),
                                          -tolerance, delta);
            // Behind: a doorway, arch or open window, which would otherwise be painted over.
            float farWeight = 1.0f - smoothstep(kOpeningBand + slack,
                                                kOpeningBand + slack + kOpeningSoftZone, delta);
            coverage = nearWeight * farWeight * planarity(depthTex, u, screenUV,
                                                          fragmentDepth, depthSlope, zoom);

            if (coverage <= 0.0f) { return float4(0.0f); }
        } else if (fragmentDepth < kDepthRange) {
            // In range but no return: an unlit room through a doorway, glass, or a glossy TV panel.
            return float4(0.0f);
        }
    }

    return float4(coverage, sampleCameraLinear(yTex, cbcrTex, uv) * coverage);
}

// MARK: - Pass A2: subtract openings

/// Erases door and window faces from the wall mask.
///
/// Drawn after the walls into the same target, writing zero. No depth attachment is involved, so
/// draw order alone decides.
vertex MaskVertexOut openingMaskVertex(uint vid [[vertex_id]],
                                       const device float3 *positions [[buffer(0)]],
                                       constant WallUniforms &u [[buffer(1)]]) {
    MaskVertexOut out;
    out.position = u.modelViewProjection * float4(positions[vid], 1.0f);
    out.position.xy *= u.meanWall.w;
    return out;
}

fragment float4 openingMaskFragment(MaskVertexOut in [[stage_in]]) {
    return float4(0.0f);
}

// MARK: - Fullscreen passes

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    // Oversized triangle: cheaper than a quad and avoids the diagonal seam.
    float2 uv = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    out.uv = uv;
    return out;
}

// MARK: - Pass A3: temporal resolve

/// Blends this frame's raw mask with the previous frame's, reprojected through the wall plane.
///
/// Without this every source of per-frame noise — the plane re-fit, LiDAR jitter, the depth map's
/// own quantisation — lands straight on screen as a moving edge. All four channels are filtered
/// together, which also steadies the shading field the blur recovers downstream.
fragment float4 resolveFragment(FullscreenOut in [[stage_in]],
                                texture2d<float> rawTex     [[texture(0)]],
                                texture2d<float> historyTex [[texture(1)]],
                                constant WallUniforms &u    [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 current = rawTex.sample(s, in.uv);

    float blend = clamp(u.tuning.w, 0.0f, 1.0f);
    if (blend >= 1.0f) { return current; }

    float2 previous = reproject(in.uv, u.reprojection);
    if (previous.x < 0.0f) { return current; }

    return mix(historyTex.sample(s, previous), current, blend);
}

// MARK: - Pass C: composite

/// Cross-bilateral upsample of the wall mask, guided by the camera's luma plane.
///
/// The depth map is 256x192 however large the drawable is, so sampling it directly staircases along
/// every edge. `step` must span a whole depth texel, so it comes from the map's real dimensions.
static inline float refinedCoverage(texture2d<float> maskTex,
                                    texture2d<float> yTex,
                                    float2 uv,
                                    float3x3 uvTransform,
                                    float2 step,
                                    float zoom,
                                    float centreGuide) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float sum = 0.0f;
    float weight = 0.0f;
    // 5x5 at half-texel spacing: +/-1 depth texel of reach, dense enough to vary smoothly.
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            float2 tapUV = uv + float2(dx, dy) * step * 0.5f;
            float tapCoverage = maskTex.sample(s, tapUV).r;
            float tapGuide = yTex.sample(s, cameraUV(tapUV, uvTransform, zoom)).r;
            float d = (tapGuide - centreGuide) / kGuideSigma;
            float w = exp(-0.5f * d * d);
            sum += tapCoverage * w;
            weight += w;
        }
    }
    return sum / max(weight, 1e-4f);
}

fragment float4 compositeFragment(FullscreenOut in [[stage_in]],
                                  texture2d<float> yTex     [[texture(0)]],
                                  texture2d<float> cbcrTex  [[texture(1)]],
                                  texture2d<float> maskTex  [[texture(2)]],
                                  texture2d<float> blurTex  [[texture(3)]],
                                  constant WallUniforms &u  [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float zoom = u.meanWall.w;
    float2 camUV = cameraUV(in.uv, u.cameraUVTransform, zoom);

    // Outside the captured frame: letterbox. Reached only when zoomed below 1.
    if (any(camUV < 0.0f) || any(camUV > 1.0f)) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    float3 observed = sampleCameraLinear(yTex, cbcrTex, camUV);
    float observedLuma = dot(observed, kLumaWeights);

    float centreGuide = yTex.sample(s, camUV).r;
    float coverage = refinedCoverage(maskTex, yTex, in.uv,
                                     u.cameraUVTransform, u.edges.xy, zoom, centreGuide);

    if (coverage <= 0.001f) {
        return float4(linearToSRGB(observed), 1.0f);
    }

    // --- Relight path ---
    // Normalised convolution: blurred colour / blurred coverage recovers the wall's low-frequency
    // illumination without contamination from outside the mask.
    float4 blurred = blurTex.sample(s, in.uv);
    float3 lowRGB = blurred.gba / max(blurred.r, 1e-4f);
    float lowFreq = dot(lowRGB, kLumaWeights);

    // Shading normalised to mean 1.0, so absolute lightness comes from the paint's measured LRV.
    float shading = lowFreq / max(u.paint.w, 1e-4f);
    shading = clamp(shading, 0.0f, 4.0f);

    // Local chromaticity of the light over the wall's mean: the departure from the global white
    // point. Clamped because in near-black regions the denominator collapses into false colour.
    float meanLuma = max(dot(u.meanWall.xyz, kLumaWeights), 1e-4f);
    float3 localChroma = lowRGB / max(lowFreq, 1e-4f);
    float3 meanChroma  = u.meanWall.xyz / meanLuma;
    float3 tint = clamp(localChroma / max(meanChroma, 1e-4f), 0.75f, 1.33f);

    // High-frequency residual carries drywall texture and roller stipple. Relative, not additive:
    // reflectance is multiplicative, so an absolute residual swamps a dark paint.
    float relativeDetail = (observedLuma - lowFreq) / max(lowFreq, 1e-3f);
    relativeDetail = clamp(relativeDetail * u.viewport.z, -0.5f, 0.5f);

    float3 relit = u.paint.xyz * shading * tint * (1.0f + relativeDetail);

    // Centred on half coverage, so partial coverage stays partial. Ramping from zero instead makes
    // every wobble in the mask read as a hard edge in the wrong place.
    float feather = clamp(u.viewport.w, 0.02f, 0.98f);
    float alpha = smoothstep(0.5f - feather * 0.5f, 0.5f + feather * 0.5f, coverage);
    return float4(linearToSRGB(mix(observed, max(relit, 0.0f), alpha)), 1.0f);
}
