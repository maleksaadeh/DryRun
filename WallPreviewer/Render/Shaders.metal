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
    // 8 bytes of implicit padding here, aligning meanWallRGB to 16. Swift's WallUniforms
    // inserts the same gap, so the shared stride stays 208.
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
//
// Loose, because it has to absorb plane-fit error plus LiDAR noise, which grows with range. A
// doorway reveals at least the jamb depth (~0.1 m) before the far room, so 0.12 m separates a real
// opening from a merely badly fitted plane.
//
// The band *in front* of the plane is `WallUniforms.occluderBand`, tunable at runtime: it decides
// whether a televison or picture frame counts as wall, and the right value depends on how far the
// object actually stands off the wall. See the note there.
constant float kOpeningBand = 0.12f;

// Ramp width for the *opening* test behind the plane. A binary accept/reject quantises every edge
// to the depth map's own resolution, which is far coarser than the drawable; ramping instead gives
// the downstream bilateral filter a continuous signal to sharpen.
//
// The ramp in front of the plane is `WallUniforms.occluderRamp`, since it has to stay narrower
// than the objects being rejected: at 0.05 m a 5 cm-deep TV landed halfway up the ramp and came
// out half-painted, which reads worse than either outcome.
constant float kOpeningSoftZone = 0.05f;

// Guide sensitivity for the cross-bilateral edge refinement, against the camera's gamma-encoded
// luma plane. Taps whose luminance differs from the centre by much more than this are treated as
// belonging to a different surface and drop out, which is what pulls the mask boundary onto the
// visible edge. Gamma-encoded rather than linear on purpose: it is closer to perceptually uniform,
// so one threshold behaves the same on a dark wall as on a bright one.
constant float kGuideSigma = 0.08f;

// Beyond roughly this range the LiDAR stops returning, so an absent sample is uninformative
// rather than evidence of an opening.
constant float kDepthRange = 4.5f;

static inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}

static inline float3 linearToSRGB(float3 c) {
    c = max(c, 0.0f);
    return select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, c * 12.92f, c <= 0.0031308f);
}

/// Maps a viewport-relative UV into the camera image, which is captured landscape-native
/// and must be rotated and cropped to the current interface orientation.
///
/// `zoom` narrows the field of view by sampling a smaller region about the centre. Applying it
/// here rather than at each call site means colour, depth and the bilateral guide all crop
/// identically — the alternative is one read drifting out of step with the others, which shows up
/// as the mask sliding off the wall under zoom rather than as anything obviously zoom-related.
///
/// The wall geometry is magnified to match in `wallMaskVertex`. The two must move together.
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
    // Clip space spans [-w, w], so scaling xy magnifies about the centre. w is deliberately left
    // alone: the fragment stage recovers metric depth from it for the plane-agreement test.
    out.position.xy *= u.zoom;
    return out;
}

/// Writes coverage in `.r` and mask-weighted linear RGB in `.gba`.
///
/// Packing both into one RGBA target means a single blur pass downstream produces both a blurred
/// colour and a blurred coverage, which divide to give a *normalised convolution* — a low-pass of
/// the wall's shading that does not bleed in pixels from outside the mask. A plain Gaussian
/// would drag furniture and trim luminance into the wall's shading estimate and halo the edges.
///
/// Carrying full RGB rather than luma alone is what lets the composite recover illuminant
/// *colour* across the wall, so a surface lit warm at one end and cool at the other repaints
/// with that variation intact instead of under one global white point.
fragment float4 wallMaskFragment(MaskVertexOut in [[stage_in]],
                                 texture2d<float> yTex   [[texture(0)]],
                                 texture2d<float> cbcrTex[[texture(1)]],
                                 texture2d<float> depthTex [[texture(2)]],
                                 constant WallUniforms &u [[buffer(1)]],
                                 constant int &hasDepth [[buffer(2)]]) {
    float2 screenUV = in.position.xy / u.viewportSize;
    float2 uv = cameraUV(screenUV, u.cameraUVTransform, u.zoom);

    // Zoomed out past 1, the sample can fall outside the captured frame. Reject rather than let
    // `clamp_to_edge` supply a smeared edge pixel: the mean reduction downstream averages whatever
    // this pass writes, so a border of repeated edge colour would bias the shading normalisation
    // for the whole wall.
    if (any(uv < 0.0f) || any(uv > 1.0f)) { return float4(0.0f); }

    // Keep only fragments whose measured depth agrees with the fitted plane. The plane itself
    // cannot express this: ARKit tessellates a plane anchor as a filled polygon over its extent
    // and never cuts holes, so a doorway in the middle of a wall arrives as solid geometry.
    //
    // Nearest sampling matters here. Linear filtering across a depth discontinuity interpolates
    // between the wall and the room beyond it, manufacturing intermediate depths that fall inside
    // the band and paint a ring around every opening.
    float coverage = 1.0f;

    if (hasDepth != 0) {
        constexpr sampler ds(filter::nearest, address::clamp_to_edge);
        float sceneDepth = depthTex.sample(ds, uv).r;          // metres
        float fragmentDepth = 1.0f / in.position.w;            // [[position]].w is 1/w_clip

        if (sceneDepth > 0.0f) {
            float delta = sceneDepth - fragmentDepth;
            // In front: a TV, a picture frame, furniture, a person, trim, a door frame.
            //
            // Tolerance grows with range because the error being absorbed does. Holding it fixed
            // made the paint retreat from the far end of a wall, where plane-fit error and LiDAR
            // noise are largest and where nothing needs excluding anyway.
            float tolerance = u.occluderBand + u.occluderRange * sceneDepth;
            float nearWeight = smoothstep(-tolerance - max(u.occluderRamp, 1e-4f),
                                          -tolerance, delta);
            // Behind: a doorway, arch, pass-through or open window. Without this the opening is
            // treated as wall and painted over, which is the most visible failure mode there is.
            float farWeight = 1.0f - smoothstep(kOpeningBand, kOpeningBand + kOpeningSoftZone, delta);
            coverage = nearWeight * farWeight;

            if (coverage <= 0.0f) { return float4(0.0f); }
        } else if (fragmentDepth < kDepthRange) {
            // In range but no return at all. An unlit room through a doorway, or glass, both of
            // which are openings — and also a dark glossy TV panel, which absorbs the laser.
            return float4(0.0f);
        }
    }

    return float4(coverage, sampleCameraLinear(yTex, cbcrTex, uv) * coverage);
}

// MARK: - Pass A2: subtract openings

/// Erases door and window faces from the wall mask.
///
/// Drawn after the walls, into the same target, writing zero. Rasterising the classified geometry
/// is exact and scales to any number of openings, where a per-fragment test against bounding
/// volumes would both cost more and over-reject: a door on a wall running diagonally to the world
/// axes has an axis-aligned box far larger than the door.
///
/// No depth attachment is involved, so a door coplanar with its wall cannot z-fight — draw order
/// alone decides, and this pass is unconditionally later.
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
/// The mask boundary around an occluder or an opening is set by LiDAR depth, whose map is 256x192
/// however large the drawable is — about one texel per ten screen pixels on a 16 Pro Max. Sampling
/// it directly staircases along every pillar, vent and doorway at exactly that pitch.
///
/// Re-weighting neighbouring mask taps by how closely their luminance matches the centre pulls the
/// boundary onto the luminance edge that is actually visible, at full drawable resolution, without
/// inventing depth that was never measured. Same principle as a joint bilateral upsample in a
/// matting pipeline, minus the network: depth supplies *where*, the camera supplies *exactly where*.
///
/// - Important: the kernel must span a whole depth texel or it cannot see across the step it is
///   meant to remove. `step` is therefore derived from the depth map's real dimensions rather than
///   from a fixed pixel count, which an earlier revision got wrong by a factor of four.
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
    // 5x5 at half-texel spacing: +/-1 depth texel of reach, sampled densely enough that the
    // weighted result varies smoothly rather than snapping between a handful of taps.
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

    // Outside the captured frame: letterbox. Reached only when zoomed below 1, where the viewport
    // is wider than the source can fill.
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
    // The only path. Alpha-blending the paint over the camera instead would be far cheaper, and
    // is what most visualisers do, but it cannot lighten a dark wall: blending white over
    // near-black yields grey. Everything below exists to avoid that.
    // Normalised convolution: blurred colour / blurred coverage recovers the wall's low-frequency
    // illumination without contamination from outside the mask.
    float4 blurred = blurTex.sample(s, in.uv);
    float3 lowRGB = blurred.gba / max(blurred.r, 1e-4f);
    float lowFreq = dot(lowRGB, kLumaWeights);

    // Shading normalised to mean 1.0 across the wall. Because the mean divides out, the result's
    // absolute lightness comes entirely from the paint's measured LRV and the wall supplies only
    // *relative* shading. This is the step that makes a light colour over a dark wall correct
    // rather than merely tinted.
    float shading = lowFreq / max(u.meanWallLuma, 1e-4f);
    shading = clamp(shading, 0.0f, 4.0f);

    // Spatially varying illuminant colour. `lowRGB` normalised by its own luma is the local
    // chromaticity of the light falling on the wall; dividing by the wall's mean chromaticity
    // leaves only the *departure* from the global white point that calibration already handled.
    // A wall lit by a window at one end and a tungsten lamp at the other keeps that gradient
    // instead of being flattened to a single temperature.
    //
    // Clamped because chromaticity is a ratio: in near-black regions the denominator collapses
    // and noise turns into vivid false colour. +/-33% spans real mixed-illuminant interiors while
    // staying well inside the range where the division is trustworthy.
    float meanLuma = max(dot(u.meanWallRGB, kLumaWeights), 1e-4f);
    float3 localChroma = lowRGB / max(lowFreq, 1e-4f);
    float3 meanChroma  = u.meanWallRGB / meanLuma;
    float3 tint = clamp(localChroma / max(meanChroma, 1e-4f), 0.75f, 1.33f);

    // High-frequency residual carries drywall texture, roller stipple and fine shadow. Dropping it
    // makes the wall read as a flat CG plane, which is the usual tell in AR paint demos.
    //
    // It must be applied as a *relative* modulation, not an absolute offset. Reflectance is
    // multiplicative: the texture visible on a wall scales with that wall's own reflectance, so
    // carrying an absolute residual measured off a white wall onto a dark paint swamps it. At
    // LRV 6 the paint contributes about 0.06 in linear light while the residual swings +/-0.1, so
    // an additive term buries the colour and the wall reads mid-grey — roughly four times too
    // light — with the negative lobes then rectified away by the clamp below, brightening it
    // further. Dividing by the local mean makes the term scale-free, so the same expression is
    // correct at LRV 6 and LRV 90.
    float relativeDetail = (observedLuma - lowFreq) / max(lowFreq, 1e-3f);
    relativeDetail = clamp(relativeDetail * u.detailGain, -0.5f, 0.5f);

    float3 relit = u.paintLinear * shading * tint * (1.0f + relativeDetail);

    float alpha = smoothstep(0.0f, max(u.edgeFeather, 1e-4f), coverage);
    return float4(linearToSRGB(mix(observed, max(relit, 0.0f), alpha)), 1.0f);
}
