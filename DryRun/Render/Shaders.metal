#include <metal_stdlib>
using namespace metal;

// Shared layout with WallRenderer.swift. Field order must stay in sync.
struct WallUniforms {
    float4x4 modelViewProjection;   // anchor -> clip
    float3x3 cameraUVTransform;     // screen UV -> camera-image UV
    float3   paintLinear;           // paint reflectance, linear, illuminant-adapted
    float    meanWallLuma;          // mean linear luma inside the mask; normalises shading to 1.0
    float2   viewportSize;
    float    detailGain;            // how much high-frequency wall texture survives
    float    edgeFeather;           // mask softening in normalised units
    // 8 bytes of implicit padding here, aligning meanWallRGB to 16; Swift inserts the same gap.
    float3   meanWallRGB;           // mean linear RGB inside the mask; normalises the illuminant tint
    float2   bilateralStep;         // one depth texel in screen UV; sets the edge-refinement radius
    float    occluderBand;          // metres in front of the plane still treated as wall
    float    occluderRamp;          // metres over which that falls off to fully excluded
    float    zoom;                  // digital zoom; crops the camera sample and scales geometry
    float    occluderRange;         // extra occluder tolerance per metre of measured range
};

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
    out.position.xy *= u.zoom;
    return out;
}

/// Writes coverage in `.r` and mask-weighted linear RGB in `.gba`.
///
/// One blur downstream divides them: a normalised convolution that does not bleed in pixels from
/// outside the mask, and that carries illuminant colour rather than luma alone.
fragment float4 wallMaskFragment(MaskVertexOut in [[stage_in]],
                                 texture2d<float> yTex   [[texture(0)]],
                                 texture2d<float> cbcrTex[[texture(1)]],
                                 texture2d<float> depthTex [[texture(2)]],
                                 constant WallUniforms &u [[buffer(1)]],
                                 constant int &hasDepth [[buffer(2)]]) {
    float2 screenUV = in.position.xy / u.viewportSize;
    float2 uv = cameraUV(screenUV, u.cameraUVTransform, u.zoom);

    // Zoomed below 1 the sample can fall outside the frame.
    if (any(uv < 0.0f) || any(uv > 1.0f)) { return float4(0.0f); }

    // ARKit tessellates a plane anchor as a filled polygon and never cuts holes, so a doorway
    // arrives as solid geometry. Nearest sampling: linear invents depths inside the band.
    float coverage = 1.0f;

    if (hasDepth != 0) {
        constexpr sampler ds(filter::nearest, address::clamp_to_edge);
        float sceneDepth = depthTex.sample(ds, uv).r;          // metres
        float fragmentDepth = 1.0f / in.position.w;            // [[position]].w is 1/w_clip

        if (sceneDepth > 0.0f) {
            float delta = sceneDepth - fragmentDepth;
            // In front: a TV, a picture frame, furniture, a person, trim.
            float tolerance = u.occluderBand + u.occluderRange * sceneDepth;
            float nearWeight = smoothstep(-tolerance - max(u.occluderRamp, 1e-4f),
                                          -tolerance, delta);
            // Behind: a doorway, arch or open window, which would otherwise be painted over.
            float farWeight = 1.0f - smoothstep(kOpeningBand, kOpeningBand + kOpeningSoftZone, delta);
            coverage = nearWeight * farWeight;

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
    out.position.xy *= u.zoom;
    return out;
}

fragment float4 openingMaskFragment(MaskVertexOut in [[stage_in]]) {
    return float4(0.0f);
}

// MARK: - Pass B: composite

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

    float2 camUV = cameraUV(in.uv, u.cameraUVTransform, u.zoom);

    // Outside the captured frame: letterbox. Reached only when zoomed below 1.
    if (any(camUV < 0.0f) || any(camUV > 1.0f)) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    float3 observed = sampleCameraLinear(yTex, cbcrTex, camUV);
    float observedLuma = dot(observed, kLumaWeights);

    constexpr sampler guideSampler(filter::linear, address::clamp_to_edge);
    float centreGuide = yTex.sample(guideSampler, camUV).r;
    float coverage = refinedCoverage(maskTex, yTex, in.uv,
                                     u.cameraUVTransform, u.bilateralStep, u.zoom, centreGuide);

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
    float shading = lowFreq / max(u.meanWallLuma, 1e-4f);
    shading = clamp(shading, 0.0f, 4.0f);

    // Local chromaticity of the light over the wall's mean: the departure from the global white
    // point. Clamped because in near-black regions the denominator collapses into false colour.
    float meanLuma = max(dot(u.meanWallRGB, kLumaWeights), 1e-4f);
    float3 localChroma = lowRGB / max(lowFreq, 1e-4f);
    float3 meanChroma  = u.meanWallRGB / meanLuma;
    float3 tint = clamp(localChroma / max(meanChroma, 1e-4f), 0.75f, 1.33f);

    // High-frequency residual carries drywall texture and roller stipple. Relative, not additive:
    // reflectance is multiplicative, so an absolute residual swamps a dark paint.
    float relativeDetail = (observedLuma - lowFreq) / max(lowFreq, 1e-3f);
    relativeDetail = clamp(relativeDetail * u.detailGain, -0.5f, 0.5f);

    float3 relit = u.paintLinear * shading * tint * (1.0f + relativeDetail);

    float alpha = smoothstep(0.0f, max(u.edgeFeather, 1e-4f), coverage);
    return float4(linearToSRGB(mix(observed, max(relit, 0.0f), alpha)), 1.0f);
}
