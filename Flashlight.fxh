/*
    Flashlight helper library

    This is the companion file for EasyFlashlight.fx. Open that file for more
    information about usage.

// =============================================================================
// Disclaimer
// =============================================================================

    Created by Rikufdi with AI assistance.

    This shader may be used, modified, and redistributed for non-commercial
    purposes only. Commercial use requires prior written permission.

    This software is provided "as is", without warranty of any kind.

// =============================================================================
// Disclaimer
// =============================================================================

*/

// =============================================================================
// HARDCODED CONSTANTS & RATIONALE
// =============================================================================

// Number of raymarch steps per shadow ray. This is a compile-time value (like
// FLASHLIGHT_SHADOW_RES_MULT in EasyFlashlight.fx), so changing it triggers a
// shader recompile - edit it in ReShade's "Preprocessor definitions" panel,
// not a regular slider. Lower it (e.g. 5-6) on lower-tier GPUs to trade some
// contact-shadow smoothness for raymarch cost that scales down roughly
// linearly with step count.
#ifndef FLASHLIGHT_SHADOW_STEPS
    #define FLASHLIGHT_SHADOW_STEPS 8
#endif
static const float Flashlight_ShadowDepthFade = 0.600;
static const int   Flashlight_ShadowSteps = FLASHLIGHT_SHADOW_STEPS;
static const float Flashlight_ShadowStepBias = 1.600;

// --- Surface angle & scattering ---
static const float Flashlight_FacingFloor = 0.850;         // Sets a darkness floor so that angled surfaces don't become too dark
static const float Flashlight_FacingWrap = 0.800;          // Hard edges got identified as very angled surfaces. This wraps around the edge to prevent cel-shaded outlines
static const float Flashlight_FacingPower = 2.0;           // Set purposely high to make angled surfaces stand out more
static const bool  Flashlight_UseAngleScattering = true;   // Be aware that setting this to 'false' will increase the general ambient brightness a lot
static const float Flashlight_ScatteringStrength = 0.750;  // How much of the ambient light should be redirected towards specific angles

// --- Soft-knee luminance floor ---
// 1/(1+k*lum) has its steepest slope at lum=0, so tiny luminance differences
// between near-black pixels (leftover source quantization, or pre-lift's own
// grain/local-avg variation) get amplified into a visible dither-like pattern
// once multiplied by a large coneIntensity/ambIntensity. Flooring the
// luminance fed into the scale factor (not the luminance used elsewhere)
// evaluates the curve on its flatter part instead, killing that amplification
// without shifting overall exposure.
static const float Flashlight_LumFloorForScale = 0.02;

// --- Pure-black artifact grain ---
// Range the grain texture's sampled value gets remapped into before flooring
// near-black pixels. Kept small and close to the old flat 0.0003 floor so
// overall exposure doesn't shift, just how it's textured.
static const float Flashlight_GrainFloorMin = 0.0001;
static const float Flashlight_GrainFloorMax = 0.0010;


// --- Virtual canvas resolution ---
// Reference height used to keep beam-space math (cone size, tilt deflection)
// resolution-independent, expressed as if the screen were always 1080p tall.
static const float VIRTUAL_CANVAS_HEIGHT = 1080.0;

// Calculate the scale factor relative to a 1080p "virtual" target
static const float SHADOW_TARGET_WIDTH = 1920.0;
static const float SHADOW_SCALE = SHADOW_TARGET_WIDTH / BUFFER_WIDTH;

// =============================================================================
// BASIC HELPERS
// =============================================================================

float2 GetDepthGradient(float2 uv) {
    float2 texelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float depthC = ReShade::GetLinearizedDepth(uv);
    float depthR = ReShade::GetLinearizedDepth(uv + float2(texelSize.x, 0));
    float depthU = ReShade::GetLinearizedDepth(uv + float2(0, -texelSize.y));
    return float2(depthR - depthC, depthU - depthC);
}

float3 ReconstructNormal(float2 uv) {
    float2 texelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float depthC = ReShade::GetLinearizedDepth(uv);
    float depthR = ReShade::GetLinearizedDepth(uv + float2(texelSize.x, 0));
    float depthU = ReShade::GetLinearizedDepth(uv + float2(0, -texelSize.y));
    
    float3 posC = float3(uv * 2 - 1, depthC);
    float3 posR = float3((uv + float2(texelSize.x,0)) * 2 - 1, depthR);
    float3 posU = float3((uv + float2(0,-texelSize.y)) * 2 - 1, depthU);
    return normalize(cross(posR - posC, posU - posC));
}

// 12-tap depth- and normal-weighted bilateral blur of the raw normals (from
// ReconstructNormal, sampled via sNormalRaw), used to hide low-poly faceting.
// "center" is the un-blurred (normal.xyz, depth.w) sample for this pixel,
// already fetched by the caller so a plain pass-through can skip this
// entirely when Smooth Normals is off, without doing a redundant tex2D.
float4 Flashlight_BlurNormals(float2 uv, float4 center, float radius) {
    float3 centerNormal = center.xyz;
    float centerDepth = center.w;
    float2 texelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT) * radius;
    static const float2 offsets[12] = {
        float2( 1.00,  0.00), float2(-1.00,  0.00), float2( 0.00,  1.00), float2( 0.00, -1.00),
        float2( 0.71,  0.71), float2(-0.71,  0.71), float2( 0.71, -0.71), float2(-0.71, -0.71),
        float2( 1.73,  1.00), float2(-1.73,  1.00), float2( 1.00,  1.73), float2(-1.00,  1.73)
    };
    float3 totalNormal = centerNormal;
    float totalWeight = 1.0;

    [unroll]
    for (int i = 0; i < 12; i++) {
        float2 sampleUV = uv + offsets[i] * texelSize;
        float4 s = tex2D(sNormalRaw, sampleUV);

        float depthDiff = abs(s.w - centerDepth);
        float depthWeight = exp(-depthDiff * 300.0);
        float normalSimilarity = saturate(dot(s.xyz, centerNormal));
        float normalWeight = pow(normalSimilarity, 4.0);

        float weight = depthWeight * normalWeight;
        totalNormal += s.xyz * weight;
        totalWeight += weight;
    }

    return float4(normalize(totalNormal / max(totalWeight, 0.0001)), centerDepth);
}

// Reconstruct view‑space position from UV coordinates scaled by the Calibration Master.
float3 GetViewSpacePosition(float2 uv) {
    float depth = ReShade::GetLinearizedDepth(uv).r * Flashlight_WorldScale;
    float2 ndc = (uv * 2.0 - 1.0) * float2(1.0, -1.0);
    float aspectRatio = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;
    ndc.x *= aspectRatio;

    // Apply the projection scale – this decouples XY from Z
    return float3(ndc * depth * Flashlight_ProjectionScale, depth);
}

float GetInterleavedNoise(float2 screenPos) {
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    return frac(magic.z * frac(dot(screenPos, magic.xy)));
}

float CalculateFlashlightSize(float depth, float baseSize, float beamShape, float beamSoftness, float divergenceRange, float reachDistance, float worldScale) {
    // Use the same depth fall-off curve that shapes the cone's brightness (Flashlight_Distance)
    // as the near/far reference here, instead of raw scene depth. Raw depth is a fraction of the
    // camera's far clip plane, which is usually hundreds of times larger than the flashlight's
    // actual reach, so "near" and "far" below now mean near/far relative to how far the light
    // reaches, not near/far relative to the whole level.
    // WorldScale is applied directly to depth (matching how it's used everywhere else in this
    // file), not folded into the exponent - putting it in the exponent made the curve's shape
    // (not just its calibration) go increasingly flat as WorldScale grew, which also made
    // beam divergence lose effect at high WorldScale values.
    float worldDepthForFalloff = depth * max(worldScale, 0.001);
    float depthFalloff = pow(max(1.0 - worldDepthForFalloff, 0.0), 1.0 / max(reachDistance, 0.001));
    float normalizedDepth = saturate(1.0 - depthFalloff);
    float sCurveDepth = normalizedDepth * normalizedDepth * (3.0 - 2.0 * normalizedDepth);
    float curve = sCurveDepth;
    float deviation = curve - 0.5;
    float shapedDepth = clamp(0.5 + deviation * beamShape, 0.0, 1.0);
    float softnessFactor = 1.0 / max(beamSoftness, 0.1);
    float sharpenedDepth = clamp(pow(shapedDepth, softnessFactor), 0.0, 1.0);
    float sizeMultiplier = 1.0 + (sharpenedDepth - 0.5) * divergenceRange;
    return baseSize * clamp(sizeMultiplier, 0.15, 2.5);
}

// =============================================================================
// CONSOLIDATED LIVE DEPTH REFERENCE
// =============================================================================

// Weights this pixel by how close it is to the beam centre (flat, unshaped
// cone - see note below) and packs (depth*weight, weight) for the mip chain
// to reduce down to a single weighted-average "what is the beam aimed at"
// depth, read back later by GetAimDepth.
//
// Note: intentionally NOT using CalculateFlashlightSize here. This only needs
// a rough, stable "am I roughly inside the beam" radius to weight the
// aim-depth average - it has nothing to do with the beam's rendered
// cross-sectional shape. Feeding it the shaped/depth-varying size caused the
// aim-depth estimate (and everything downstream that relies on it, including
// shadow raymarching bias) to shift with beam shape rather than staying stable.
float2 Flashlight_ComputeAimAccumSample(float2 uv, float depthVal, float flashlightSize, float edgeFalloff) {
    float2 centerPosUV = float2(0.5, 0.5);
    float halo = length(float2(1920.0, 1080.0) * (uv - centerPosUV));
    float normalizedDist = halo / flashlightSize;
    float coneFalloff = saturate(1.0 - normalizedDist);
    float gaussian = exp(-edgeFalloff * normalizedDist * normalizedDist);
    float weight = (depthVal < 0.99) ? max(gaussian * coneFalloff, 0.001) : 0.0001;
    return float2(depthVal * weight, weight);
}

float GetAimDepth() {
    float2 accum = tex2Dlod(sAimAccum, float4(0.5, 0.5, 0, AIM_ACCUM_MIPS - 1)).rg;
    return max(accum.x / max(accum.y, 0.0001), 0.01) * Flashlight_WorldScale;
}

float GetNormalizedBeamDistance(float2 uv, float3 pixelPos, float3 lightPos, float depthVal, float3 normal, float flashlightSize, out float2 beamUV) {
    float aimDepth = GetAimDepth();
    float3 targetPos = float3(0.0, 0.0, aimDepth);
    float3 beamAxis = normalize(targetPos - lightPos);
    float3 worldUp = (abs(beamAxis.y) > 0.99) ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
    float3 beamRight = normalize(cross(worldUp, beamAxis));
    float3 beamUp = cross(beamAxis, beamRight);
    float3 lightToPixel = pixelPos - lightPos;

    // Floor zBeam so it can never collapse toward zero.
    float minZBeam = (flashlightSize / (0.5 * VIRTUAL_CANVAS_HEIGHT)) * max(pixelPos.z, 0.001);
    float zBeam = max(dot(lightToPixel, beamAxis), minZBeam);
    float2 projBeam = float2(dot(lightToPixel, beamRight), -dot(lightToPixel, beamUp)) / zBeam;

    // Tilt wrap for deflection
    float tilt = dot(normal, -beamAxis);
    float wrapRange = max(Flashlight_TiltWrap, 0.001);
    float wrappedTilt = smoothstep(1.0 - wrapRange, 1.0, tilt);

    // =========================================================================
    // BILATERAL EDGE DAMPENING
    // =========================================================================
    float scale = BUFFER_WIDTH / 1920.0;
    float sampleRadius = max(4.0 * scale, 1.0);
    float2 texelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float2 offX = float2(texelSize.x * sampleRadius, 0.0);
    float2 offY = float2(0.0, texelSize.y * sampleRadius);

    // Depth silhouette
    float dC = depthVal * Flashlight_WorldScale;
    float dR = ReShade::GetLinearizedDepth(uv + offX).r * Flashlight_WorldScale;
    float dL = ReShade::GetLinearizedDepth(uv - offX).r * Flashlight_WorldScale;
    float dU = ReShade::GetLinearizedDepth(uv + offY).r * Flashlight_WorldScale;
    float dD = ReShade::GetLinearizedDepth(uv - offY).r * Flashlight_WorldScale;
    float maxDepthDiff = max(max(abs(dR - dC), abs(dL - dC)), max(abs(dU - dC), abs(dD - dC)));
    float relativeDepthDiff = maxDepthDiff / max(dC, 0.001);
    float depthEdgeDamp = smoothstep(0.0001, 0.0010, relativeDepthDiff);

    // Normal crease
    float3 nR = tex2D(sNormalSmooth, uv + offX).xyz;
    float3 nL = tex2D(sNormalSmooth, uv - offX).xyz;
    float3 nU = tex2D(sNormalSmooth, uv + offY).xyz;
    float3 nD = tex2D(sNormalSmooth, uv - offY).xyz;
    float minDot = min(min(dot(normal, nR), dot(normal, nL)), min(dot(normal, nU), dot(normal, nD)));
    float normalEdgeDamp = smoothstep(0.95, 0.80, minDot);

    float edgeDamp = max(depthEdgeDamp, normalEdgeDamp);
    edgeDamp = lerp(0.0, edgeDamp, Flashlight_EdgeDampening);

    // Depth‑based deflection scale
    float depthDeflectionScale = lerp(1.0, 0.1, saturate(depthVal * 3.0));
    float effectiveDeflection = Flashlight_TiltDeflection * depthDeflectionScale * (1.0 - edgeDamp);

    // Apply deflection
    float2 deflectedBeam = projBeam + normal.xy * (1.0 - wrappedTilt) * effectiveDeflection;

    beamUV = (deflectedBeam * (0.5 * VIRTUAL_CANVAS_HEIGHT)) / max(flashlightSize, 0.001);
    float halo = length(deflectedBeam * (0.5 * VIRTUAL_CANVAS_HEIGHT));
    return halo / max(flashlightSize, 0.001);
}

// Pushes the cookie/grain sample position into (or out of) the surface along
// its normal, then re-derives beam-space UV for that shifted position so the
// cookie's projected size/position stays consistent with the new virtual
// depth instead of just sliding the same 2D UV around. Parallax is skipped
// (texturePos = pixelPos, cookieUV = the un-shifted beamUV) when the offset
// is effectively zero, since it's a no-op there and skips the extra beam-axis
// re-projection work.
void Flashlight_ComputeParallaxOffset(
    float3 pixelPos,
    float3 normal,
    float3 lightPos,
    float2 beamUV,
    float flashlightSizeVisual,
    float textureDepthOffset,
    float worldScale,
    float parallaxCookieMinSize,
    out float3 texturePos,
    out float2 cookieUV
) {
    texturePos = pixelPos;
    cookieUV = beamUV * 0.5 + 0.5;

    if (abs(textureDepthOffset) <= 0.001) return;

    // Shift along the normal (Positive value pushes INTO the geometry)
    float parallaxAmount = textureDepthOffset * worldScale;
    texturePos = pixelPos - normal * parallaxAmount;

    // Recompute the 2D projection for the cookie at the new depth
    float3 targetPos = float3(0.0, 0.0, GetAimDepth());
    float3 beamAxis = normalize(targetPos - lightPos);
    float3 worldUp = (abs(beamAxis.y) > 0.99) ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
    float3 beamRight = normalize(cross(worldUp, beamAxis));
    float3 beamUp = cross(beamAxis, beamRight);

    // Original projection (Calculated first to establish the baseline)
    float3 lightToPixel = pixelPos - lightPos;
    float zBeam = max(dot(lightToPixel, beamAxis), 0.001);
    float2 projBeam = float2(dot(lightToPixel, beamRight), -dot(lightToPixel, beamUp)) / zBeam;

    // Virtual projection
    float3 vLightToPixel = texturePos - lightPos;
    float vZBeamRaw = max(dot(vLightToPixel, beamAxis), 0.001);

    // CLAMP: Prevent the virtual depth from getting so small that the cookie shrinks excessively
    float vZBeam = max(vZBeamRaw, zBeam * parallaxCookieMinSize);

    float2 vProjBeam = float2(dot(vLightToPixel, beamRight), -dot(vLightToPixel, beamUp)) / vZBeam;

    // Apply the difference to the original beamUV
    float2 projDelta = vProjBeam - projBeam;
    float2 uvDelta = (projDelta * (0.5 * VIRTUAL_CANVAS_HEIGHT)) / max(flashlightSizeVisual, 0.001);

    cookieUV = (beamUV + uvDelta) * 0.5 + 0.5;
}

// =============================================================================
// SHADOW OCCLUSION – receiver-depth-relative helpers
// =============================================================================

float ViewSpaceExtentFromPixels(float screenPixels, float depthVal) {
    return (screenPixels / (0.5 * BUFFER_HEIGHT)) * depthVal;
}

bool ShouldSkipShadow(float receiverDepth, float3 lightPos, float shadowMaxRange) {
    if (!Flashlight_UseShadows || Flashlight_ShadowStrength <= 0.0) return true;
    if (receiverDepth <= Flashlight_NearCutoff * Flashlight_WorldScale) return true;

    float lightProximityEps = ViewSpaceExtentFromPixels(2.0, receiverDepth);
    if (receiverDepth <= lightPos.z + lightProximityEps) return true;
    float cameraDistanceFade = 1.0 - smoothstep(shadowMaxRange * 0.75, shadowMaxRange, receiverDepth);
    if (cameraDistanceFade <= 0.0) return true;
    return false;
}

float ComputeShadowStrength(float receiverDepth, float3 normal, float3 rayDir, float shadowMaxRange) {
    float nDotL = dot(normal, rayDir);
    float depthAttenuation = 1.0 / (1.0 + receiverDepth * Flashlight_ShadowDepthFade);
    float nearCutoffScaled = Flashlight_NearCutoff * Flashlight_WorldScale;
    float nearFade = smoothstep(nearCutoffScaled, nearCutoffScaled + 0.015 * Flashlight_WorldScale, receiverDepth);
    float cameraDistanceFade = 1.0 - smoothstep(shadowMaxRange * 0.75, shadowMaxRange, receiverDepth);
    return Flashlight_ShadowStrength * depthAttenuation * nearFade * cameraDistanceFade;
}

float3 MarchShadowRay(
    float3 biasedPos,
    float3 rayDir,
    float maxSearchDist,
    float jitter,
    float dynamicSoftness,
    float contactThreshold,   
    float thicknessLimit,
    float reachRange,         
    float stepBias,
    float sourceRadius
) {
    float hits = 0.0;
    float blockerDistSum = 0.0;
    float blockerWeightSum = 0.0;
    
    float validStepsCount = 0.0001; 
    float averageHitWeight = 0.0;
    int numSteps = clamp(Flashlight_ShadowSteps, 4, 32);
    float aspectRatio = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;
    [unroll]
    for (int i = 1; i <= numSteps; i++) {
        float tLinear = saturate(((float)i + jitter) / (float)numSteps);
        float tDistributed = pow(tLinear, stepBias);
        float distFromReceiver = max(tDistributed * maxSearchDist, 0.0001);
        float3 samplePos = biasedPos + rayDir * distFromReceiver;
        float2 sampleNDC = samplePos.xy / max(samplePos.z, 0.0001);
        sampleNDC.x /= aspectRatio;
        float2 sampleUV = float2(sampleNDC.x, -sampleNDC.y) * 0.5 + 0.5;
        if (sampleUV.x < 0.0 || sampleUV.x > 1.0 || sampleUV.y < 0.0 || sampleUV.y > 1.0) continue;
        
        float sceneDepth = ReShade::GetLinearizedDepth(sampleUV).r * Flashlight_WorldScale;

        if (sceneDepth <= Flashlight_NearCutoff * Flashlight_WorldScale) {
            hits += averageHitWeight;
            continue; 
        }

        float depthDiff = samplePos.z - sceneDepth;
        float baseBias = -contactThreshold * 0.4;
        
        if (depthDiff > baseBias) {
            float contactBlend = smoothstep(baseBias, contactThreshold, depthDiff);
            float thicknessBlend = 1.0 - smoothstep(thicknessLimit * 0.20, thicknessLimit, depthDiff);
            float distAttenuation = 1.0 / (1.0 + tDistributed * dynamicSoftness * 1.8);
            float fadeStart = reachRange * 0.4;
            float fadeEnd = max(reachRange, maxSearchDist * 0.1); 
            float blockerDistanceFade = 1.0 - smoothstep(fadeStart, fadeEnd, distFromReceiver);
            float sampleWeight = contactBlend * thicknessBlend * distAttenuation * blockerDistanceFade;
            hits += sampleWeight;
            if (sampleWeight > 0.001) {
                blockerDistSum += distFromReceiver * sampleWeight;
                blockerWeightSum += sampleWeight;
            }
        }
        validStepsCount += 1.0;
        averageHitWeight = hits / validStepsCount;
    }
    return float3(hits, blockerDistSum, blockerWeightSum);
}

float FinalizeShadow(
    float hits,
    float nDotL,
    float dynamicSoftness,
    float effectiveStrength,
    float blockerDistSum,
    float blockerWeightSum,
    float rayDist,
    float receiverDepth,
    float sourceRadius,
    out float penumbraPixels
) {
    penumbraPixels = 0.0;
    int numSteps = clamp(Flashlight_ShadowSteps, 4, 32);
    float softHitsReq = (float)numSteps * lerp(0.40, 0.22, saturate(dynamicSoftness));
    float crispHitsReq = 0.05; 
    
    float expectedMaxHits = lerp(crispHitsReq, softHitsReq, saturate(dynamicSoftness * 5.0));
    float rawShadow = saturate(hits / max(expectedMaxHits, 0.001));
    float crispnessFactor = 1.0 - saturate(dynamicSoftness * 5.0);
    rawShadow = lerp(rawShadow, step(0.01, rawShadow), crispnessFactor);

    float normalWeight = smoothstep(0.0, 0.20, nDotL);
    float smoothShadow = pow(smoothstep(0.0, 1.0, rawShadow), 1.35) * normalWeight;

    if (blockerWeightSum > 0.001 && sourceRadius > 0.0) {
        float distFromReceiver = blockerDistSum / blockerWeightSum;
        float distFromLight = max(rayDist - distFromReceiver, 0.0001);
        float worldPenumbra = sourceRadius * distFromReceiver / distFromLight;
        penumbraPixels = (worldPenumbra / receiverDepth) * (0.5 * BUFFER_HEIGHT);
    }

    return lerp(1.0, 1.0 - effectiveStrength, smoothShadow);
}

float CalculateDirectionalOcclusion(
    float2 uv,
    float3 pixelPos,
    float3 normal,
    float2 depthGrad,
    float3 lightPos,
    float contactRangePixels,
    float thicknessLimitPixels,
    float reachMultiplier,      
    out float penumbraPixels
) {
    penumbraPixels = 0.0;
    float receiverDepth = max(pixelPos.z, 0.001);

    float maxShadowRangeScaled = min(Flashlight_ShadowMaxRange * Flashlight_WorldScale, 1.0);
    if (ShouldSkipShadow(receiverDepth, lightPos, maxShadowRangeScaled))
        return 1.0;
        
    float3 rayDir = lightPos - pixelPos;
    float rayDist = length(rayDir);
    rayDir /= max(rayDist, 0.0001);

    float nDotL = dot(normal, rayDir);
    float effectiveStrength = ComputeShadowStrength(receiverDepth, normal, rayDir, maxShadowRangeScaled);
    if (nDotL <= 0.0) return 1.0 - effectiveStrength;

    float baseReachPixels = 900.0 * reachMultiplier;
    float distanceFade = 1.0 - smoothstep(0.01 * Flashlight_WorldScale, maxShadowRangeScaled, receiverDepth);
    float dynamicReachPixels = baseReachPixels * lerp(0.10, 1.0, distanceFade);

    float activeReach = ViewSpaceExtentFromPixels(dynamicReachPixels, receiverDepth);
    float maxSearchDist = min(rayDist, activeReach);

    float baseSlopeBias = lerp(0.0015, 0.0080, 1.0 - saturate(nDotL)) * Flashlight_WorldScale;
    float slopeBias = min(baseSlopeBias, maxSearchDist * 0.15);
    float3 biasedPos = pixelPos + normal * slopeBias;
    float jitter = (GetInterleavedNoise(uv * BUFFER_SCREEN_SIZE) - 0.5) * 0.85;

    float activeContactThreshold = ViewSpaceExtentFromPixels(contactRangePixels, receiverDepth);
    activeContactThreshold = min(activeContactThreshold, maxSearchDist * 0.25);

    float activeThicknessLimit = ViewSpaceExtentFromPixels(thicknessLimitPixels, receiverDepth);
    activeThicknessLimit = min(activeThicknessLimit, maxSearchDist * 0.60); 

    float edgeThresholdPixels = 2.5;
    float edgeReference = ViewSpaceExtentFromPixels(edgeThresholdPixels, receiverDepth);
    float edgeMagnitude = length(depthGrad);
    float isGeometricEdge = smoothstep(edgeReference * 0.4, edgeReference * 4.5, edgeMagnitude);
    float distanceSoftnessScale = lerp(4.0, 0.0, distanceFade) * Flashlight_ShadowMasterBlend;
    
    float baseSoftness = max(Flashlight_ShadowSoftness, 0.001) * distanceSoftnessScale;
    float dynamicSoftness = baseSoftness * (1.0 - isGeometricEdge * 0.30) * (1.0 + receiverDepth * (1.2 / max(Flashlight_WorldScale, 0.001)));
    float baseSourceRadius = Flashlight_ShadowSourceRadius * distanceSoftnessScale;
    float sourceRadius = baseSourceRadius * Flashlight_WorldScale;

    float3 marchResult = MarchShadowRay(
        biasedPos, rayDir, maxSearchDist, jitter, dynamicSoftness,
        activeContactThreshold, activeThicknessLimit, activeReach,
        Flashlight_ShadowStepBias, sourceRadius
    );
    
    return FinalizeShadow(
        marchResult.x, nDotL, dynamicSoftness, 
        effectiveStrength, marchResult.y, marchResult.z, rayDist, receiverDepth,
        sourceRadius, penumbraPixels
    );
}

// How far (in beam-radius units) from the beam centre a pixel can be before
// its shadow gets culled/faded out entirely. Wider with ambient on (shadows
// need to reach further to matter for the ambient bounce), boosted for
// pixels near the in-focus depth (so the area the beam is actually pointed
// at gets shadows even past the base radius) and for pixels very close to
// the camera (so near-camera geometry doesn't lose shadows to the base cull
// radius alone).
float Flashlight_ComputeShadowCullLimit(float depthC, float aimDepth, bool useAmbient) {
    float baseCullLimit = useAmbient ? 5.5 : 1.15;

    float depthDiff = abs(depthC * Flashlight_WorldScale - aimDepth);
    float focalRange = max(aimDepth, 0.01) * 0.85;
    float focalCoherence = pow(saturate(1.0 - depthDiff / max(focalRange, 0.0001)), 1.2);
    float focalBoost = useAmbient ? (focalCoherence * 6.5) : 0.0;

    float nearCameraBoost = exp(-25.0 * depthC) * 20.0;
    return baseCullLimit + focalBoost + nearCameraBoost;
}

// Smoothly fades shadow strength to 0 on surfaces nearly parallel to the
// beam axis (grazing angles), where screen-space raymarching is unreliable
// and tends to produce noisy false occlusion. Reconstructs a view-space
// normal from 3 extra depth samples (rather than reusing the smoothed
// G-buffer normal) so the fade responds to the true local surface angle.
float Flashlight_ComputeGrazingFade(float2 uv, float3 beamAxis) {
    float2 texelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float3 posC = GetViewSpacePosition(uv);
    float3 posR = GetViewSpacePosition(uv + float2(texelSize.x, 0));
    float3 posU = GetViewSpacePosition(uv + float2(0, -texelSize.y));
    float3 viewNormal = normalize(cross(posR - posC, posU - posC));

    // Dot with the beam axis – 1.0 = normal points along beam, 0.0 = parallel to beam
    float nDotBeam = dot(viewNormal, beamAxis);

    // Smoothly fade shadow from 0 (parallel) to 1 (facing beam) over a small angle range.
    // The upper bound 0.25 works well in practice; adjust if needed.
    return smoothstep(0.0, 0.25, abs(nDotBeam));
}

// =============================================================================
// LIGHTING HELPERS
// =============================================================================

float Flashlight_SCurve(float v, float strength) {
    float vc = saturate(v);  // Clamp to [0,1] before S-curve
    float s = vc * vc * (3.0 - 2.0 * vc);
    return saturate(lerp(v, s, strength));
}

// =============================================================================
// SAFE INTERNAL HSV CONVERTERS (Guarantees strict 0.0 - 1.0 normalization)
// =============================================================================

float3 Flashlight_SafeRGBtoHSV(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float3 Flashlight_SafeHSVtoRGB(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
}

// =============================================================================
// COLOR TINT: CLEAN HUE SHIFTING BASED ON TRUE FLASHLIGHT CHROMATICITY
// =============================================================================

float3 Flashlight_ApplyColorTint(
    float3 color,         // Input (already boosted)
    float3 lightColor,    // Flashlight_Color
    float intensity,      // Local light intensity (0-1 range)
    float strength        // Flashlight_ColorTintStrength
) {
    if (strength <= 0.0 || intensity < 0.001) return color;

    // Use our safe local converters to completely insulate math from external .fxh bugs
    float3 hsvColor = Flashlight_SafeRGBtoHSV(color);
    float3 hsvLight = Flashlight_SafeRGBtoHSV(lightColor);

    // Dynamic blend factor based on UI slider strength and illumination intensity
    float blend = strength * saturate(intensity * 2.0);
    if (blend <= 0.0) return color;

    // Clean 0.0 - 1.0 shortest-path hue wrapping 
    float hueDiff = hsvLight.x - hsvColor.x;
    if (hueDiff > 0.5) hueDiff -= 1.0;
    if (hueDiff < -0.5) hueDiff += 1.0;
    
    hsvColor.x = frac(hsvColor.x + hueDiff * blend);

    // Saturation Protection: Only adjust scene saturation if the flashlight itself is colored.
    // This stops a pure neutral white flashlight from stripping out the game's native colors.
    hsvColor.y = lerp(hsvColor.y, hsvLight.y, blend * hsvLight.y);

    return Flashlight_SafeHSVtoRGB(hsvColor);
}

float3 Flashlight_ApplyCombinedLight(
    float3 color,
    float3 coneFactor, float coneIntensity, float coneLogIntensity, float coneColorBoost,
    float3 ambFactor, float ambIntensity, float ambLogIntensity, float ambColorBoost, bool ambActive,
    float coneEdgeFactor,   // New: 1 at centre, 0 at the cone edge
    float rescueBrightness
) {
    float luminance = dot(color, float3(0.299, 0.587, 0.114));
    // Only the scale-factor evaluation point is floored, so the brightness
    // curve doesn't get evaluated on its steepest part right near lum=0 (which
    // amplifies tiny luminance differences into visible dither). The additive
    // step further down still uses the real (unfloored) luminance, so true
    // exposure/black level is untouched. See Flashlight_LumFloorForScale.
    float lumForScale = max(luminance, Flashlight_LumFloorForScale);
    float coneScaleFactor = 1.0 / (1.0 + (10.0 / max(coneLogIntensity, 0.001)) * lumForScale);
    float3 coneBoost = coneFactor * coneIntensity * coneScaleFactor;
    
    float3 ambBoost = 0.0;
    if (ambActive) {
        float ambScaleFactor = 1.0 / (1.0 + (10.0 / max(ambLogIntensity, 0.001)) * lumForScale);
        ambBoost = ambFactor * ambIntensity * ambScaleFactor;
    }
    
float3 totalBoost = coneBoost + ambBoost;

    // --- BASE: ORIGINAL MULTIPLICATIVE BOOST ---
    // Scaling every channel by the same-ish factor preserves the ratio between
    // them exactly, regardless of how big the factor is - so this already
    // keeps scene colorfulness AND the flashlight's own color tint intact for
    // any pixel that isn't literally black. This is the right behavior for
    // the vast majority of pixels.
    float3 boosted = color * (1.0 + totalBoost);

    // --- NEAR-BLACK RESCUE: ADDITIVE, CLAMPED-CHROMA ---
    // NEW LOGIC: Calculate luminance based purely on the bounded ~0-1 light shape 
    // and the independent rescue knob, ignoring the massive multiplicative intensity.
    float shapeLum = dot(coneFactor, float3(0.299, 0.587, 0.114));
    float rawLightLum = shapeLum * rescueBrightness; 
    
    float newLumaAdditive = luminance + rawLightLum;
    float3 chroma = color - luminance;
    float chromaScale = min(newLumaAdditive / max(luminance, 0.0001), Flashlight_ChromaScaleLimit);
    float3 rescueResult = max(newLumaAdditive + chroma * chromaScale, 0.0);

    float rescueBlend = 1.0 - smoothstep(0.0, max(Flashlight_NearBlackRescueRange, 0.0001), luminance);
    float3 blended = lerp(boosted, rescueResult, rescueBlend);

    // --- OVERSHOOT TRANSLATION (SOFT SHOULDER) ---
    // Let the boosted color naturally overshoot 1.0.
    float3 rawColor = blended;
    
    // Find the strongest color channel rather than overall luminance.
    // This prevents Red and Blue from being overly suppressed by Green's dominance,
    // which is what causes the "washed out" look.
    float maxC = max(rawColor.r, max(rawColor.g, rawColor.b));
    
    // Define the safe threshold where we begin to smoothly compress.
    float threshold = 0.75; 
    float3 result = rawColor;
    
    if (maxC > threshold) {
        // Calculate exactly how much the strongest channel overshoots the threshold
        float overshoot = maxC - threshold;
        
        // Compress the overshoot using a soft continuous curve (Reinhard-style).
        // It asymptotically approaches 1.0 but never hard-clips, entirely preventing the "blob".
        float compressedOvershoot = overshoot / (1.0 + overshoot);
        
        // Calculate the target max value for the brightest channel
        float newMax = threshold + compressedOvershoot * (1.0 - threshold);
        
        // Translate the whole RGB vector down proportionally.
        // This mathematically preserves the exact hue and relative saturation!
        result = rawColor * (newMax / maxC);
    }

float boostMagnitude = dot(totalBoost, float3(0.299, 0.587, 0.114));

// Use the geometric cone edge factor – smooth 1→0 from centre to edge
float boostPresence = saturate(boostMagnitude * Flashlight_HighlightDesatBoostSensitivity) * coneEdgeFactor;

if (boostPresence > 0.001) {
    float resultLum = dot(result, float3(0.299, 0.587, 0.114));
    float resultMaxC = max(result.r, max(result.g, result.b));
    float highlightMetric = max(resultLum, resultMaxC);

    // Smooth transition over a 0.10 band around the threshold
    // (threshold-0.05) to (threshold+0.05)
    float thresholdLow  = max(Flashlight_HighlightDesatThreshold - 0.05, 0.0);
    float thresholdHigh = min(Flashlight_HighlightDesatThreshold + 0.05, 1.0);
    float desatWeight = smoothstep(thresholdLow, thresholdHigh, highlightMetric);

    float satReduce = desatWeight * Flashlight_HighlightDesatStrength * boostPresence;
    float3 desaturated = dot(result, float3(0.333, 0.333, 0.333));
    result = lerp(result, desaturated, satReduce);
}
    
    return result;
}

// Shared depth-aware ramp-in used by both the ambient ring and the scattering
// boost, so anything that fades in "from inside the cone outward" shares the
// same transition shape and the same depth-dependent rate.
float ComputeAmbientRampIn(float normalizedDist, float depthFactor) {
    float rampRate = lerp(lerp(1.0, 0.4, 0.5), lerp(1.0, 2.5, 0.5), depthFactor);
    return smoothstep(0.20, 0.80, normalizedDist * rampRate);
}

float ComputeAmbientRing(float depthVal, float normalizedDist, float depthFalloff, float ambientDistance) {
    float distFromPeak = normalizedDist - 1.20;
    float ring = exp(-distFromPeak * distFromPeak / (2.5 * 2.5));
    float depthFactor = saturate(1.0 - depthFalloff);
    float ramp = ComputeAmbientRampIn(normalizedDist, depthFactor);
    return ring * lerp(0.15, 1.0, ramp) * pow(max(1.0 - depthVal, 0.0), 1.0 / ambientDistance);
}

float ComputeFacingTerm(float3 normal, float3 lightDir, float depthVal) {
    float rawFacing = dot(normal, lightDir);
    float wrapped = saturate((rawFacing + Flashlight_FacingWrap) / (1.0 + Flashlight_FacingWrap));
    float depthFactor = saturate(depthVal * 4.0);
    float floor = lerp(Flashlight_FacingFloor, 0.95, depthFactor);
    return floor + (1.0 - floor) * pow(wrapped, Flashlight_FacingPower);
}

float ComputeScatteringBoost(float depthVal, float normalizedDist, float aimDepth, float ambientDepthBoost, float coneIntensity, float depthFalloff) {
    float depthDiff = abs(depthVal * Flashlight_WorldScale - aimDepth);
    float rangeDistFactor = 1.0 / (1.0 + 0.15 * max(normalizedDist - 1.0, 0.0));
    float relRange = max(aimDepth, 0.001) * 0.80 * rangeDistFactor;
    float depthCoherence = pow(saturate(1.0 - depthDiff / max(relRange, 0.0001)), 0.80);
    float depthFactor = saturate(1.0 - depthFalloff);
    float rampIn = ComputeAmbientRampIn(normalizedDist, depthFactor);
    float innerMask = rampIn * (1.0 - saturate(coneIntensity * 5.0));
    return 1.0 + depthCoherence * ambientDepthBoost * innerMask;
}

float ComputeAngleScattering(float rawFacing) {
    float scat = pow(1.0 - max(rawFacing, 0.0), 2.0);
    if (rawFacing < 0.0) scat *= max(0.05, 1.0 + rawFacing);
    return lerp(1.0, scat, Flashlight_ScatteringStrength);
}

// Projects the grain texture onto whichever of the three view-space planes
// best matches the surface normal (standard triplanar mapping), so a floor
// samples the texture top-down and a wall samples it front-on instead of
// getting a single flat screen-space pattern smeared across every surface.
//
// Caveat: "pos" here is view-space (camera-relative), not true world-space,
// since this shader has no access to the camera's view/rotation matrix.
// That means the grain holds up well under camera movement, but will drift
// slightly on the surface when you turn/look around, rather than being
// perfectly world-locked.
float Flashlight_SampleGrain(float3 pos, float3 normal, float tileSize) {
    float invTile = 1.0 / max(tileSize, 0.001);
    float texX = tex2D(sFlashlightGrain, pos.yz * invTile).r;
    float texY = tex2D(sFlashlightGrain, pos.xz * invTile).r;
    float texZ = tex2D(sFlashlightGrain, pos.xy * invTile).r;

    // Winner-take-all axis selection rather than a wide weighted blend.
    // Blending independent noise samples together (as a standard weighted
    // triplanar blend does) statistically washes contrast out wherever the
    // normal isn't closely axis-aligned -- exactly the close-up, busy
    // geometry case this grain is meant for. Picking a single dominant
    // sample keeps full contrast almost everywhere; only pixels within a
    // narrow band of a tie between two axes blend at all, which avoids a
    // one-pixel-wide flip that would flicker as the normal wobbles.
    float3 absN = abs(normal);
    float maxN = max(absN.x, max(absN.y, absN.z));
    const float crossoverBand = 0.12;
    float3 weight = smoothstep(maxN - crossoverBand, maxN, absN);
    weight /= max(weight.x + weight.y + weight.z, 0.0001);

    return texX * weight.x + texY * weight.y + texZ * weight.z;
}

// =============================================================================
// PRE‑LIFT: RESCUE PURE‑BLACK PIXELS USING LOCAL SCENE COLOUR
// =============================================================================

// How much a single scene-colour sample counts toward the downsampled local
// average. Pixels that are too dark or too washed-out/overexposed contribute
// nothing, so the average stays focused on vibrant midtone colour instead of
// being dragged toward grey by the much more common dark/desaturated pixels.
float Flashlight_SceneColorWeight(float3 color) {
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    float maxC = max(color.r, max(color.g, color.b));
    float minC = min(color.r, min(color.g, color.b));
    float sat = (maxC - minC) / max(maxC, 0.0001);

    // Filters out dark pixels (<0.10) AND overexposed highlights (>0.50)
    // keeping the average focused purely on vibrant midtone colors.
    float satWeight = smoothstep(0.15, 0.50, sat);
    float lumWeight = smoothstep(0.10, 0.35, lum) * (1.0 - smoothstep(0.50, 0.95, lum));

    return satWeight * lumWeight;
}

float3 Flashlight_GetLocalAverageColor(float2 uv) {
    // Sample from the 1x1 mipmap (the last level in the chain) exactly at the
    // center of the screen to pull a true, unified whole-frame average color.
    float3 avg = tex2Dlod(sSceneColorDownsampled, float4(0.5, 0.5, 0, SCENE_DOWNSCALE_MIPS - 1)).rgb;
    
    // Prevent blowout (pure white) by scaling the brightness back down
    // to a safe 0-1 range while perfectly preserving the hue.
    float maxC = max(avg.r, max(avg.g, avg.b));
    if (maxC > 1.0) {
        avg /= maxC;
    }
    
    return max(avg, float3(0.0150, 0.0150, 0.0150));
}

float3 Flashlight_ApplyPreLift(
    float3 color,
    float2 uv,
    float3 pixelPos,
    float3 normal,
    float normalizedDist,
    float ambientShape,
    bool debugMode
) {
    if (!Flashlight_UseArtifactRemoval) return color;

    float nearCutoffScaled = Flashlight_NearCutoff * Flashlight_WorldScale;
    if (pixelPos.z <= nearCutoffScaled) return color;

    float aimDepth = GetAimDepth();
    float depthDiff = abs(pixelPos.z - aimDepth);
    float flexibleWindow = max(aimDepth * 0.4, 0.15 * Flashlight_WorldScale);
    float groundingMask = smoothstep(flexibleWindow * 1.5, flexibleWindow * 0.5, depthDiff);

    float worldDepthForFalloff = pixelPos.z;
    float depthFalloff = pow(max(1.0 - worldDepthForFalloff, 0.0), 1.0 / max(Flashlight_Distance, 0.001));
    
    float depthMask = groundingMask * depthFalloff;
    if (depthMask <= 0.001) return color;

    float lum = dot(color, float3(0.299, 0.587, 0.114));
    
    float isDark = 1.0 - smoothstep(0.0, 0.012, lum);
    if (isDark <= 0.0) return color;

    // --- THE FIX 1: FLATTER FOOTPRINT (CORRECTED) ---
    // Properly ordered smoothstep (min, max, value) to fix the dead center
    float flatConeMask = 1.0 - smoothstep(0.001, 1.15, normalizedDist);
    
    // Use max() instead of + to prevent double-dipping in the ramp-up overlap
    float footprint = saturate(max(flatConeMask, ambientShape * 0.8)) * depthMask;
    if (footprint < 0.01) return color;

    // Sample the local scene average early so debug mode can use it
    float3 localAvg = Flashlight_GetLocalAverageColor(uv);

    // --- DEBUG OVERRIDE ---
    if (debugMode) {
        float3 debugColor = localAvg * max(footprint, 0.5);
        color = lerp(color, debugColor, isDark);
        return max(color, 0.001);
    }

    // --- COLOR SEED FOR PURE-BLACK PIXELS ---
    float grainSample = Flashlight_SampleGrain(pixelPos, normal, Flashlight_GrainScale);
    float grainBrightness = saturate(Flashlight_GrainBrightness / 10.0);
    float seedMagnitude = lerp(Flashlight_GrainFloorMin, Flashlight_GrainFloorMax, grainSample * grainBrightness) * footprint;

    // Since the center isn't dead anymore, you can drop this multiplier back down 
    // to a reasonable number (e.g., 25.0 to 50.0) instead of 125 or 1000.
    color = max(color, localAvg * seedMagnitude * 40.0 * isDark);

    return color;
}


// =============================================================================
// ARTIFACT REMOVAL (Desaturate lopsided near‑black pixels)
// =============================================================================

float3 Flashlight_ApplyArtifactRemoval(float3 color, float artifactThreshold, float3 viewPos, float3 normal, out float attenuation) {
    attenuation = 1.0;
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    if (lum < artifactThreshold) {
        float darknessWeight = 0.8 - saturate(lum / artifactThreshold);
        darknessWeight *= darknessWeight;
        float maxC = max(color.r, max(color.g, color.b));
        float minC = min(color.r, min(color.g, color.b));
        float lopsidedness = saturate(((maxC - minC) / max(maxC, 0.0001)) * 1.5);
        float desatAmount = saturate(darknessWeight * lopsidedness);
        color = lerp(color, lum.xxx, desatAmount);
        float noisePenalty = lerp(0.60, 1.00, lopsidedness);
        attenuation = 1.0 - saturate(darknessWeight * noisePenalty);
    }
    return max(color, 0.0001);
}

// =============================================================================
// SHARPENING & CONTRAST
// =============================================================================

float3 ApplySharpening(float3 color, float2 uv, float sharpenWeight, float strength) {
    if (sharpenWeight <= 0.01) return color;
    float2 texelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float3 neighbor = (tex2D(sColor, saturate(uv + float2(-texelSize.x, 0))).rgb +
                       tex2D(sColor, saturate(uv + float2( texelSize.x, 0))).rgb +
                       tex2D(sColor, saturate(uv + float2(0, -texelSize.y))).rgb +
                       tex2D(sColor, saturate(uv + float2(0,  texelSize.y))).rgb) * 0.25;
    float3 sharpened = saturate(color + (color - neighbor) * strength * 2.0);
    return lerp(color, sharpened, sharpenWeight * 0.30);
}

float3 ApplyContrast(float3 color, float normalizedDist, float ambientShape, float contrastMaster, float depthVal, float reachDistance, float lightIntensity) {
    if (contrastMaster <= 0.0) return color;

    // --- Depth-based Contrast Modulator ---
    float nearFade = smoothstep(0.0, 0.006 * Flashlight_WorldScale, depthVal);
    float depthFalloff = pow(max(1.0 - (depthVal * max(Flashlight_WorldScale, 0.001)), 0.0), 1.0 / max(reachDistance, 0.001));
    
    // --- Angle Dimming & Deformation Throttle ---
    float intensityThrottle = smoothstep(0.02, 0.25, lightIntensity);
    
    float depthModulator = nearFade * depthFalloff * intensityThrottle;

    // --- Deformation-Aware Masks ---
    float geometricMask = saturate(1.0 - reachDistance); //normalizedDist);
    float coneMask = saturate(lightIntensity * 1.5) * geometricMask; 
    
    float lightMask = max(coneMask, ambientShape);
    if (lightMask <= 0.001) return color;
    
    float coneDominance = coneMask / max(lightMask, 0.001);

    // --- Compute contrast strengths ---
    float dynamicShape = saturate(1.0 - lightIntensity);
    
    float coneContrast = (contrastMaster * 1.45) * pow(dynamicShape, 0.8) * depthModulator;
    float ambientContrast = (contrastMaster * 0.60) * ambientShape * depthModulator;

    float totalContrast = lerp(ambientContrast, coneContrast, coneDominance);

    // --- PREPARE LUMINANCE ---
    float lum = dot(color, float3(0.299, 0.587, 0.114));

    // --- FIX 1: Darkness Protection (Shadow Crush) ---
    // Smoothly fades out the extreme contrast multiplier on pixels sitting in the 
    // delicate pre-lift range (0.005 - 0.040), preventing them from being pushed 
    // into negative numbers and crushed back to pure black.
    float darknessProtection = smoothstep(0.005, 0.150, lum);
    totalContrast *= darknessProtection;

    // --- FIX 2: Overbright Inversion (Center Black Hole) ---
    // Extracts any brightness above 1.0 so the S-Curve only evaluates the safe 0-1 range.
    // This stops the lerp extrapolation from creating a downward mathematical slope that
    // inverts the overbright center of the beam into pure black.
    float clampedLum = saturate(lum);
    float overbright = max(lum - 1.0, 0.0);
    
    float curvedLum = Flashlight_SCurve(clampedLum, totalContrast) + overbright;
    
    // --- Apply contrast ---
    float3 contrasted = color * (curvedLum / max(lum, 0.0001));
    
    float effectFade = lightMask * saturate(totalContrast * 2.0);
    return lerp(color, contrasted, effectFade);
}