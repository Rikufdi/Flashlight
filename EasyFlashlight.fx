/*
    Easy Flashlight Shader - True 3D Flashlight Beam with logarithmic depth-aware brightness and somewhat crappy contact shadows.

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


    ****IMPORTANT****           Needs access to the depth buffer!           ****IMPORTANT****

        Use the DisplayDepth.fx in Reshade to see if you have access to the depth buffer.
        Sometimes you need to change the Global Preprocessor Definitions to Reversed or
        Upside Down. Also, in some games you need to turn off AA to get access to the
        depth buffer. Sometimes you need to manually select the depth buffer in the
        Reshade add-on and/or use the "Copy depth buffer before clear operations".

        One sneaky workaround is to use the add-on Reshade Effect Shader Toggler (REST)
        and manually pick out the shaders which have the full depth buffer and only run
        the Flashlight on those. Can be a bit tricky though.

    ****IMPORTANT****           Needs access to the depth buffer!           ****IMPORTANT****
    
    Not really an "easy" flashlight since there are way too many sliders which needs to be
    individually tuned per game to look right. Especially shadows needs tuning per game to
    be near decently looking as the hard limits of screen-space reconstruction makes them
    look really bad in most cases. Best I've managed have been to only allow shadows on
    close geometry and exaggerate with the FOV/parallax slider. Using the offsets causes
    "Ghost Shadows" and other issues so it's been best to have them at zero. Important
    to use the FOV Projection and tune shadows so that they move properly as that is what
    subjectively "anchors" them to the surface behind the occluder. The world scale was an
    attempt to have all variables and functions have that as a sort of "master" slider so
    that at least you only had one slider to tune per game but that road failed halfway
    there. The problem is that each game have different depth scales and it's been difficult
    to find a solution to that. If you don't want to do the trial and error needed for the
    shadows, just keep them turned off.

    Mostly tested with boomer-shooters such as Q1, Q2, Prodeus, Aeon: Wrath of Ruin,
    Sprawl, Dusk, and Dread Templar. All behave differently so you need to tune the
    settings per-game to get a decently working flashlight.

    I've tried a few different methods of adding light to a pixel and have ended up with
    this hybrid approach because it preserved colors best. There are essentially two light
    passes. One additive, for black and near-black pixels which also borrows color from a
    weighted average taken from the whole scene and adds a grain texture. Then, the main
    lighting pass takes over which uses a logarithmic multiplicative approach that preserves
    colors pretty well while it also manages to not blow out already bright and saturated
    pixels.

    The other methods have been:
        1.  Purely additive where you compress the whole range towards full brightness.
            Works well in lighting up black and dark pixels but got very washed out colors
            even with tries to preserve color saturation.

        2.  Convert the rgb channels into negative log space but clamping black pixels to a
            minimum (0.003) before converting. I think this will eventually beat this hybrid
            approach but have had problems implementing it so far.

        3.  Some variants of the additive above to try and preserve colors but ultimately
            didn't work out.

    Vibe-coded by many different AIs so I have no idea if everything is a mess or not as I
    have limited coding experience myself but have tried to keep it modular. The
    EasyFlashlight.fx is supposed to be more like a recipe of what to do and when and then
    call the helper library at the appropriate step.

    Don't forget the companion file Flashlight.fxh as that contains most of the functions
    and helpers. Tried to keep it modular that way.
*/

#include "ReShade.fxh"

// =============================================================================
// TEXTURES & SAMPLERS
// =============================================================================

sampler2D sColor {
    Texture = ReShade::BackBufferTex;
    SRGBTexture = true;
    MinFilter = POINT;
    MagFilter = POINT;
};

// Raw gamma sampler for downsampling – avoids linearisation that crushes dark values. Used by the black pixel rescue to fill in scene color.
sampler2D sColorRaw {
    Texture = ReShade::BackBufferTex;
    SRGBTexture = false;   // read gamma‑encoded values
    MinFilter = POINT;
    MagFilter = POINT;
};

// Accumulates the average depth of the cone. Used by Depth-Aware Ambient, Dynamic Shadow Culling, and Beam Projection.
#define AIM_ACCUM_RES 256
#define AIM_ACCUM_MIPS 9
texture2D AimAccumTex { Width = AIM_ACCUM_RES; Height = AIM_ACCUM_RES; Format = RG32F; MipLevels = AIM_ACCUM_MIPS; };
sampler2D sAimAccum {
    Texture = AimAccumTex;
    MinFilter = POINT;
    MagFilter = POINT;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

// Custom downsampled scene colour – each 128x128 block is a saturation/luminance
// weighted average that favours vibrant, well-lit pixels over black/grey ones. The
// mip chain (auto-generated via GenerateMipMaps) then reduces that down to a single
// 1x1 texel, sampled by Flashlight_GetLocalAverageColor for a whole-frame average.
// Used by the pre-lift pass to give pure-black pixels a plausible colour baseline.
#define SCENE_DOWNSCALE_RES 128
#define SCENE_DOWNSCALE_MIPS 8 // Define the mipmap levels to reach 1x1

texture2D SceneColorDownsampled { Width = SCENE_DOWNSCALE_RES; Height = SCENE_DOWNSCALE_RES; Format = RGBA16F; MipLevels = SCENE_DOWNSCALE_MIPS; };
sampler2D sSceneColorDownsampled {
    Texture = SceneColorDownsampled;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = LINEAR; // <-- Added so ReShade knows to blend the mipmaps
    AddressU = CLAMP;
    AddressV = CLAMP;
};

// Shadow raymarch/blur resolution, as a multiplier of the game's actual
// render resolution (BUFFER_WIDTH/BUFFER_HEIGHT) - NOT a fixed absolute
// size. 1.0 = native (raymarch resolution always matches whatever the game
// is actually rendering at, whether that's 1080p, 1440p, or 4K). Raise it
// for a supersampled shadow buffer with crisper contact shadows, at a
// proportional (not fixed) extra cost. This is a compile-time value, so
// changing it triggers a shader recompile - edit it in ReShade's
// "Preprocessor definitions" panel, not a regular slider.
#ifndef FLASHLIGHT_SHADOW_RES_MULT
    #define FLASHLIGHT_SHADOW_RES_MULT 1.0
#endif

texture2D ShadowRawTex { Width = BUFFER_WIDTH * FLASHLIGHT_SHADOW_RES_MULT; Height = BUFFER_HEIGHT * FLASHLIGHT_SHADOW_RES_MULT; Format = RG16F; };
sampler2D sShadowRaw {
    Texture = ShadowRawTex;
    MinFilter = POINT;
    MagFilter = POINT;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

texture2D ShadowBlurTex { Width = BUFFER_WIDTH * FLASHLIGHT_SHADOW_RES_MULT; Height = BUFFER_HEIGHT * FLASHLIGHT_SHADOW_RES_MULT; Format = RG16F; };
sampler2D sShadowBlur {
    Texture = ShadowBlurTex;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

texture2D NormalRawTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D sNormalRaw {
    Texture = NormalRawTex;
    MinFilter = POINT;
    MagFilter = POINT;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

texture2D NormalSmoothTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D sNormalSmooth {
    Texture = NormalSmoothTex;
    MinFilter = POINT;
    MagFilter = POINT;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

// Grain texture for pure-black surfaces. Place a tileable, grayscale
// noise/grain image named "Flashlight_Grain.png" in ReShade's Textures
// folder (next to the Shaders folder). If your image isn't 512x512, change
// Width/Height below to match it so ReShade doesn't stretch it on load.
texture2D FlashlightGrainTex < source = "Flashlight_Grain.png"; > {
    Width = 512;
    Height = 512;
    Format = RGBA8;
};
sampler2D sFlashlightGrain {
    Texture = FlashlightGrainTex;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = LINEAR;
    AddressU = REPEAT;
    AddressV = REPEAT;
};

// Cone cookie/gobo texture: simulates reflector segments, filament shadow,
// dust on the lens, etc. Place a square grayscale image named
// "Flashlight_Cookie.png" in ReShade's Textures folder. It's sampled with
// beam-space coordinates (see GetNormalizedBeamDistance's beamUV output), so
// it stays fixed relative to the flashlight itself rather than the world or
// the screen, and it deforms with perspective/normal the same way
// the cone shape already does. Center of the image = center of the beam;
// the cone's edge lands on the image's inscribed circle.
texture2D FlashlightCookieTex < source = "Flashlight_Cookie.png"; > {
    Width = 512;
    Height = 512;
    Format = RGBA8;
};
sampler2D sFlashlightCookie {
    Texture = FlashlightCookieTex;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = LINEAR;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

// =============================================================================
// BASIC CONTROLS (UI)
// =============================================================================

uniform float Flashlight_Brightness <
    ui_category = "Basic Controls";
    ui_label = "Brightness";
    ui_type = "slider"; ui_min = 0.0; ui_max = 200.0; ui_step = 0.1;
    ui_tooltip = "Overall intensity of the flashlight beam.";
> = 100.000000;

uniform float Flashlight_LogIntensity <
    ui_category = "Basic Controls";
    ui_label = "Logarithmic Brightness Intensity";
    ui_type = "slider";
    ui_min = 0.01; ui_max = 2.0; ui_step = 0.01;
    ui_tooltip = "Low values brightens dark areas more than already bright surfaces.";
> = 0.06000;

uniform float Flashlight_Size <
    ui_category = "Basic Controls";
    ui_label = "Size";
    ui_type = "slider"; ui_min = 10.0; ui_max = 1000.0; ui_step = 1.0;
    ui_tooltip = "Base width of the light cone. Shadows become problematic when too big";
> = 200.000000;

uniform float Flashlight_EdgeFalloff <
    ui_category = "Basic Controls";
    ui_label = "Edge Sharpness";
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0; ui_step = 0.1;
    ui_tooltip = "Controls how soft or sharp the outer edge of the flashlight beam is.";
> = 1.500000;

uniform float3 Flashlight_Color <
    ui_category = "Basic Controls";
    ui_label = "Color";
    ui_type = "color";
    ui_tooltip = "Color of the light. Default is warm white.";
> = float3(1.000000, 0.971397, 0.757925);

uniform float Flashlight_ColorTintStrength <
    ui_category = "Basic Controls";
    ui_label = "Color Tint Strength (Hue Shift)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Shifts the colour of lit surfaces towards the flashlight's colour.\n"
                 "Use with highlight desaturation to cut through very saturated surfaces";
> = 0.050000;

uniform float Flashlight_ContrastMaster <
    ui_category = "Basic Controls";
    ui_label = "Contrast";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01;
> = 0.100000;

uniform float Flashlight_Distance <
    ui_category = "Basic Controls";
    ui_label = "Depth Fall-off (Preference)";
    ui_type = "slider"; ui_min = 0.001; ui_max = 5.0; ui_step = 0.001;
    ui_tooltip = "How far the light reaches.\n"
                 "The beam shape depth deformation depends on this value since\n"
                 "it's more useful to gauge the game's scale using this metric.\n"
                 "This means that if you shorten the flashlight's reach, it will\n"
                 "deform quicker.";
> = 0.1200000;

uniform float Flashlight_NearCutoff <
    ui_category = "Basic Controls";
    ui_label = "Near Depth Cut-off (Exclude Weapon)";
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.5; ui_step = 0.001;
    ui_tooltip = "Removes light and shadow casting from close weapons/arms geometry.";
> = 0.001;

uniform float Flashlight_WorldScale <
    ui_category = "Basic Controls";
    ui_label = "=== MASTER DEPTH CALIBRATION ===";
    ui_type = "slider"; ui_min = 0.1; ui_max = 50.0; ui_step = 0.01;
    ui_tooltip = "This calibration affects all depth calculations but can be useful to get properly aligned shadows.\n"
                 "Usage: Look at a close shadow and adjust this until its edges are crisp.";
> = 1.0;

// =============================================================================
// Ambient Bounce
// =============================================================================

uniform bool Flashlight_UseAmbient <
    ui_category = "Ambient Bounce";
    ui_label = "Ambient On/Off";
> = 1;

uniform float Flashlight_AmbientStrengthMaster <
    ui_category = "Ambient Bounce";
    ui_label = "Ambient Strength";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.250000;

uniform float Flashlight_AmbientDepthBoost <
    ui_category = "Ambient Bounce";
    ui_label = "Depth-Aware Ambient Boost";
    ui_type = "slider"; ui_min = 0.0; ui_max = 40.0; ui_step = 0.01;
    ui_tooltip = "Increases ambient lighting on surfaces near-depth to the main cone";
> = 12.5;

uniform float Flashlight_AmbientDistance <
    ui_category = "Ambient Bounce";
    ui_label = "Ambient Depth Fall-off";
    ui_type = "slider"; ui_min = 0.001; ui_max = 1.0; ui_step = 0.001;
> = 0.080000;

uniform float Flashlight_AmbientLogIntensity <
    ui_category = "Ambient Bounce";
    ui_label = "Ambient Log Intensity";
    ui_type = "slider"; ui_min = 0.001; ui_max = 2.0; ui_step = 0.001;
> = 0.002000;

// =============================================================================
// DIRECTIONAL SHADOWS
// =============================================================================

uniform bool Flashlight_UseShadows <
    ui_category = "Directional Shadows";
    ui_label = "Shadows On/Off";
    ui_tooltip = "Enables directional screen-space shadowing.\n"
                 "Warning! Usually needs to be tuned to look decent.\n"
                 "Best is to start with max Shadow Distance and then\n"
                 "lower it until shadows only appear near the camera.\n"
                 "Then change the FOV / Projectionscale until you see\n"
                 "exaggerated movements on shadows cast from occluders\n"
                 "near the flashlight. Then adjust World Scale until\n"
                 "shadow edges are crisp.";
> = 0;

uniform float Flashlight_ProjectionScale <
    ui_category = "Directional Shadows";
    ui_label = "FOV / Projection Scale (Shadow Sliding)";
    ui_type = "slider";
    ui_min = 0.1;
    ui_max = 5.0;
    ui_step = 0.01;
    ui_tooltip = "Calibrates perspective projection for shadow parallax.\n"
                 "Typically needs to be decreased a little.\n"
                 "Needs to be tuned per game.";
> = 0.90;

uniform float Flashlight_ShadowStrength <
    ui_category = "Directional Shadows";
    ui_label = "Shadow Strength";
    ui_type = "slider"; ui_min = 0.0; ui_max = 5.0; ui_step = 0.01;
> = 3.500000;

uniform float Flashlight_ShadowLogIntensity <
    ui_category = "Directional Shadows";
    ui_label = "Logarithmic Shadow Intensity";
    ui_type = "slider";
    ui_min = 0.01; ui_max = 4.0; ui_step = 0.01;
    ui_tooltip = "Low values let already dark pixels keep more of their light through a\n"
                 "shadow, and make already bright shadow pixels take closer to full shadow\n"
                 "strength. Same shape as Logarithmic Brightness Intensity, but tuned\n"
                 "independently for shadows.";
> = 2.00000;

uniform float Flashlight_ShadowMaxRange <
    ui_category = "Directional Shadows";
    ui_label = "Shadow Distance (Max Reach)";
    ui_type = "slider"; ui_min = 0.05; ui_max = 20.0; ui_step = 0.01;
    ui_tooltip = "Limits how far away from the camera shadows starts to appear.\n"
                 "Recommended to keep low to reduce dark glow around objects.\n"
                 "Needs to be tuned per game.";
> = 0.60000;

uniform float Flashlight_ShadowReachMultiplier <
    ui_category = "Directional Shadows";
    ui_label = "Shadow Length (Throw)";
    ui_type = "slider"; ui_min = 0.1; ui_max = 50.0; ui_step = 0.01;
    ui_tooltip = "The length between occluder and shadow surface we allow before fading out.\n"
                 "Needs to be tuned per game.";
> = 2.0;

uniform float Flashlight_ShadowThicknessLimit <
    ui_category = "Directional Shadows";
    ui_label = "Shadow Thickness Limit (px)";
    ui_type = "slider"; ui_min = 20.0; ui_max = 1500.0; ui_step = 10.0;
> = 700.0;

uniform float Flashlight_ShadowOffsetX <
    ui_category = "Directional Shadows";
    ui_label = "Shadow Offset X";
    ui_type = "slider"; ui_min = -0.5; ui_max = 0.5; ui_step = 0.001;
> = 0.000;

uniform float Flashlight_ShadowOffsetY <
    ui_category = "Directional Shadows";
    ui_label = "Shadow Offset Y";
    ui_type = "slider"; ui_min = -0.5; ui_max = 0.5; ui_step = 0.001;
> = 0.000;

uniform float Flashlight_ShadowOffsetZ <
    ui_category = "Directional Shadows";
    ui_label = "Shadow Offset Z";
    ui_type = "slider"; ui_min = -0.5; ui_max = 0.5; ui_step = 0.001;
> = 0.000;

uniform float Flashlight_ShadowMasterBlend <
    ui_category = "Directional Shadows";
    ui_label = "Master Shadow Blending";
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.01;
> = 1.000;

// =============================================================================
// ADVANCED SHADOW BLENDING
// =============================================================================

uniform float Flashlight_ShadowSoftness <
    ui_category = "Advanced Shadow Blending";
    ui_category_closed = true;
    ui_label = "Shadow Softness (Ray March)";
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.600;

uniform float Flashlight_ShadowSourceRadius <
    ui_category = "Advanced Shadow Blending";
    ui_category_closed = true;
    ui_label = "Shadow Source Radius (Penumbra)";
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.05; ui_step = 0.0001;
> = 0.0200;

uniform float Flashlight_ShadowBlurRadius <
    ui_category = "Advanced Shadow Blending";
    ui_category_closed = true;
    ui_label = "Shadow Denoise Blur";
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.01;
> = 1.00;

uniform float Flashlight_ShadowContactRange <
    ui_category = "Advanced Shadow Blending";
    ui_label = "Shadow Contact Range (px)";
    ui_type = "slider"; ui_min = 1.0; ui_max = 150.0; ui_step = 1.0;
> = 20.0;

// =============================================================================
// ADVANCED SETTINGS
// =============================================================================

uniform float Flashlight_OffsetX <
    ui_category = "Advanced Settings";
    ui_label = "Offset X (Left/Right)";
    ui_type = "slider"; ui_min = -0.500; ui_max = 0.500; ui_step = 0.0001;
> = 0.000000;

uniform float Flashlight_OffsetY <
    ui_category = "Advanced Settings";
    ui_label = "Offset Y (Up/Down)";
    ui_type = "slider"; ui_min = -0.500; ui_max = 0.500; ui_step = 0.0001;
> = 0.000500;

uniform float Flashlight_OffsetZ <
    ui_category = "Advanced Settings";
    ui_label = "Offset Z (Forward into Scene)";
    ui_type = "slider"; ui_min = 0.000; ui_max = 1.000; ui_step = 0.0001;
> = 0.000000;

uniform float Flashlight_TiltDeflection <
    ui_category = "Advanced Settings";
    ui_label = "Tilt Deflection";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.5; ui_step = 0.01;
    ui_tooltip = "How much the cone deflects toward the surface normal on tilted geometry. Higher = more exaggerated skew.";
> = 0.200000;

uniform float Flashlight_TiltWrap <
    ui_category = "Advanced Settings";
    ui_label = "Tilt Deflection Wrap";
    ui_type = "slider";
    ui_min = 0.05; ui_max = 2.0; ui_step = 0.01;
    ui_tooltip = "Width of the smooth transition zone deflection ramps in over. Higher = softer, more gradual onset, less prone to hard edges on angular geometry.";
> = 0.500000;

uniform float Flashlight_EdgeDampening <
    ui_category = "Advanced Settings";
    ui_label = "Edge Dampening (Reduce Deflection at Edges)";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "Reduces tilt deflection near geometric edges to prevent cel-shaded outlines. Higher = stronger reduction.";
> = 0.5;

uniform float Flashlight_HighlightDesatThreshold <
    ui_category = "Advanced Settings";
    ui_label = "Highlight Desaturation Threshold";
    ui_type = "slider"; ui_min = 0.001; ui_max = 1.00; ui_step = 0.01;
> = 0.00000;

uniform float Flashlight_HighlightDesatStrength <
    ui_category = "Advanced Settings";
    ui_label = "Highlight Desaturation Strength";
    ui_type = "slider"; ui_min = 0.00; ui_max = 1.00; ui_step = 0.01;
> = 0.200000;

uniform float Flashlight_HighlightDesatBoostSensitivity <
    ui_category = "Advanced Settings";
    ui_label = "Highlight Desaturation Boost Sensitivity";
    ui_type = "slider"; ui_min = 0.5; ui_max = 20.0; ui_step = 0.1;
> = 1.000000;

uniform float Flashlight_BeamDivergenceShape <
    ui_category = "Advanced Settings";
    ui_label = "Beam Divergence Amount";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "How much the beam narrows close to the flashlight and widens with distance. Higher = more pronounced divergence.\n"
                 "This depends on how far the flashlight reaches. Not really correct but I found that it more accurately represents\n"
                 "the depth range which a player typically operates in rather than the full range.";
> = 0.500000;

uniform float Flashlight_BeamDivergenceSoftness <
    ui_category = "Advanced Settings";
    ui_label = "Beam Divergence Softness";
    ui_type = "slider";
    ui_min = 0.1; ui_max = 5.0; ui_step = 0.05;
    ui_tooltip = "Softens the near-to-far size transition. Lower = sharper, more sudden size change over distance.";
> = 2.500000;

uniform float Flashlight_BeamDivergenceRange <
    ui_category = "Advanced Settings";
    ui_label = "Beam Divergence Range";
    ui_type = "slider";
    ui_min = 0.5; ui_max = 3.0; ui_step = 0.05;
    ui_tooltip = "Total spread between the near and far cone size. Higher = bigger difference between close-up and distant beam width.";
> = 1.400000;

uniform float Flashlight_ConeCA <
    ui_category = "Advanced Settings";
    ui_label = "Cone Chromatic Aberration";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.050;
    ui_step = 0.001;
    ui_tooltip = "Adds a subtle color fringe to the outer edge of the light cone.";
> = 0.015;

uniform bool Flashlight_UseArtifactRemoval <
    ui_category = "Advanced Settings";
    ui_label = "Artifact Removal On/Off";
    ui_tooltip = "Identifies near black pixels with lopsided colors and desaturates them before adding light.\n"
                 "Also uses a grain texture on black and near black pixels to fill it.";
> = 1;

uniform bool Flashlight_EnablePreLift <
    ui_category = "Advanced Settings";
    ui_label = "Enable Pre Lift";
    ui_tooltip = "Gives pure- and near-black pixels a plausible base color, borrowed from local\n"
                 "scene colour and a grain texture, so they have some hue to preserve once lit.\n";
> = 1;

uniform bool Flashlight_DebugPreLift <
    ui_category = "Advanced Settings";
    ui_label = "Debug Pre-Lift View";
    ui_tooltip = "Highlights rescued black pixels in blood red and disables main lighting.";
> = 0;

uniform float Flashlight_GrainScale <
    ui_category = "Advanced Settings";
    ui_label = "Artifact Removal Grain Tiling";
    ui_tooltip = "World-space size of one grain texture tile on pure-black surfaces. Lower values = larger, more visible grain.";
    ui_type = "slider"; ui_min = 0.001; ui_max = 0.5; ui_step = 0.001;
> = 0.005000;

uniform float Flashlight_GrainBrightness <
    ui_category = "Advanced Settings";
    ui_label = "Artifact Removal Grain Brightness";
    ui_tooltip = "Adjusts how bright the grain appears on pure black surfaces. Higher values make the grain variation more obvious.";
    ui_type = "slider"; ui_min = 0.01; ui_max = 100.0; ui_step = 0.1;
> = 20.0;

uniform float Flashlight_ChromaScaleLimit <
    ui_category = "Advanced Settings";
    ui_label = "Color Preservation Limit";
    ui_tooltip = "Caps how much a pixel's tint can be amplified while brightening it.\n"
                 "Near-black pixels have tiny (often noisy) RGB differences; without a cap,\n"
                 "preserving their color ratio exactly blows those differences up into fully\n"
                 "saturated color. Lower = safer/flatter in near-black areas. Higher = more\n"
                 "color preserved everywhere, more prone to color explosion in the dark.";
    ui_type = "slider"; ui_min = 1.0; ui_max = 30.0; ui_step = 0.1;
> = 8.0;

uniform float Flashlight_NearBlackRescueBrightness <
    ui_category = "Advanced Settings";
    ui_label = "Near-Black Rescue Brightness";
    ui_tooltip = "Independent brightness knob for the additive pure-black rescue path.\n"
                 "Gently lifts dark pixels without blowing them out to pure white.";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.001;
> = 0.070; // A sane default that gently lifts the black floor

uniform float Flashlight_NearBlackRescueRange <
    ui_category = "Advanced Settings";
    ui_label = "Near-Black Rescue Range";
    ui_tooltip = "Starting-luminance cutoff below which pixels use the additive, clamped-chroma\n"
                 "rescue instead of the normal multiplicative boost. Only pixels below this get\n"
                 "the rescue treatment while everything above it keeps its full original\n"
                 "colorfulness and the normal brightness curve untouched. Raise only if you still\n"
                 "see black areas that should be brighter, keep it low otherwise.";
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.2; ui_step = 0.001;
> = 0.003;

uniform bool Flashlight_UseCookie <
    ui_category = "Advanced Settings";
    ui_label = "Cone Cookie Texture On/Off";
    ui_tooltip = "Modulates the beam with a texture (Flashlight_Cookie.png in the Textures folder) to simulate reflector segments, lens dust, etc.";
> = 0;

uniform float Flashlight_CookieStrength <
    ui_category = "Advanced Settings";
    ui_label = "Cone Cookie Strength";
    ui_tooltip = "Blends between a clean cone (0) and the full cookie texture pattern (1).";
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.750000;

uniform float Flashlight_TextureDepthOffset <
    ui_category = "Advanced Settings";
    ui_label = "Texture Depth Offset (Parallax)";
    ui_type = "slider"; ui_min = -2.0; ui_max = 0.0; ui_step = 0.001;
    ui_tooltip = "Pulls the cookie and grain textures out to create a parallax effect.";
> = -0.005;

uniform float Flashlight_ParallaxCookieMinSize <
    ui_category = "Advanced Settings";
    ui_label = "Parallax Cookie Min Size";
    ui_type = "slider"; ui_min = 0.1; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "Prevents the cookie from shrinking too much when aiming at very close surfaces. 0.5 means it can't shrink smaller than half its normal size.";
> = 0.50;

uniform bool Flashlight_UseSmoothNormals <
    ui_category = "Advanced Settings";
    ui_label = "Smooth Normals";
    ui_tooltip = "Smooths out low-poly geometry.";
> = 0;

uniform float Flashlight_SmoothNormalsRadius <
    ui_category = "Advanced Settings";
    ui_label = "Smooth Normals Radius";
    ui_type = "slider"; ui_min = 1.0; ui_max = 8.0; ui_step = 0.5;
    ui_tooltip = "How aggressive and expensive the smoothing is.";
> = 3.0;

uniform bool Flashlight_DownsampleUseRaw <
    ui_category = "Advanced Settings";
    ui_label = "Downsample Use Raw Gamma (sRGB backbuffer)";
    ui_tooltip = "Enable if your game's backbuffer is in sRGB (gamma) space.\n"
                 "Disable if the backbuffer is already linear.\n"
                 "Helps the pre‑lift color average match the scene brightness correctly.";
> = true;

// =============================================================================
// INCLUDES
// =============================================================================

#include "Flashlight.fxh"

// =============================================================================
// PIXEL SHADERS
// =============================================================================

// Pass 1: derive a view-space normal from neighbouring depth samples and
// stash it alongside linear depth (in .w) for later passes to reuse.
float4 PS_ComputeNormals(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float3 normal = ReconstructNormal(uv);
    float depthVal = ReShade::GetLinearizedDepth(uv).r;
    return float4(normal, depthVal);
}

// Pass 2: 12-tap depth- and normal-weighted bilateral blur of the raw
// normals, used to hide low-poly faceting. Skipped (pass-through) when the
// Smooth Normals toggle is off.
float4 PS_SmoothNormals(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float4 center = tex2D(sNormalRaw, uv);
    if (!Flashlight_UseSmoothNormals) return center;
    return Flashlight_BlurNormals(uv, center, Flashlight_SmoothNormalsRadius);
}

// Pass 3: weight each pixel by how close it is to the beam centre and write
// (depth*weight, weight) so the mip chain's top level (sampled in
// GetAimDepth) resolves to a weighted-average "what is the beam aimed at"
// depth. Uses a flat, unshaped cone radius on purpose - see comment below.
float2 PS_AccumulateAimDepth(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float depthVal = ReShade::GetLinearizedDepth(uv).r;
    return Flashlight_ComputeAimAccumSample(uv, depthVal, Flashlight_Size, Flashlight_EdgeFalloff);
}

// Pass 4: box-downsample the scene into a small local-average colour buffer.
// Aggressively weights pixels with higher saturation and luminance so vibrant 
// colors aren't washed out by surrounding grey/dark geometry.
float4 PS_DownsampleSceneColor(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float2 blockSize = 1.0 / SCENE_DOWNSCALE_RES;
    float2 startUV = uv - blockSize * 0.5;
    float2 step = blockSize / 3.0;   // 4x4 grid (16 samples)

    float3 weightedSum = 0.0;
    float weightCount = 0.0;
    float3 fallbackSum = 0.0;

    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            float2 sampleUV = startUV + float2(x, y) * step;
            float3 sampleColor;
            
            if (Flashlight_DownsampleUseRaw) {
                sampleColor = tex2D(sColorRaw, sampleUV).rgb;   // gamma-encoded
            } else {
                sampleColor = tex2D(sColor, sampleUV).rgb;      // linearised
            }
            
            // Weight this sample by how vibrant/well-lit it is
            float weight = Flashlight_SceneColorWeight(sampleColor);

            weightedSum += sampleColor * weight;
            weightCount += weight;
            
            // Keep a raw sum just in case the entire block is legitimately grey/dark
            fallbackSum += sampleColor;
        }
    }

    float3 avg;
    // If we found colorful/bright pixels, use their weighted average.
    // Otherwise, fall back to the standard flat average so grey walls don't turn pitch black.
    if (weightCount > 0.001) {
        avg = weightedSum / weightCount;
    } else {
        avg = fallbackSum / 16.0;
    }

    float avgLum = dot(avg, float3(0.299, 0.587, 0.114));

    // If the entire block is still completely black, fallback to a tiny neutral grey
    if (avgLum < 0.0001) {
        return float4(0.01, 0.01, 0.01, 1.0);
    }
    
    return float4(avg, 1.0);
}

// Pass 5: cull pixels clearly outside the beam, then raymarch toward the
// (virtual) shadow-casting light position to find occluders. Outputs
// (shadowFactor, penumbraPixels) for the blur pass to consume.
float2 PS_ComputeShadow(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET { 
    float4 normalData = tex2D(sNormalRaw, uv);
    float depthC = normalData.w;

    if (depthC >= 0.999) return float2(1.0, 0.0);
    
    float3 normal = tex2D(sNormalSmooth, uv).xyz;
    float3 pixelPos = GetViewSpacePosition(uv);
    float2 depthGrad = GetDepthGradient(uv);

    // Now compute beam distance
    float3 visualLightPos = float3(Flashlight_OffsetX, Flashlight_OffsetY, Flashlight_OffsetZ);
    float2 unusedBeamUV;
    // Uses a flat (unshaped) size, not CalculateFlashlightSize - this is only a coarse "is this
    // pixel roughly within the beam" cull test for whether to bother raymarching a shadow, not
    // the final rendered shape. Feeding it the shaped size coupled the cull region to
    // Flashlight_Distance/WorldScale saturation the same way the aim-depth pass was, which
    // caused shadows to stop responding to WorldScale once that curve saturated.
    float distFromBeam = GetNormalizedBeamDistance(uv, pixelPos, visualLightPos, depthC, normal, Flashlight_Size, unusedBeamUV);

    float aimDepth = GetAimDepth();
    float dynamicCullLimit = Flashlight_ComputeShadowCullLimit(depthC, aimDepth, Flashlight_UseAmbient);

    if (distFromBeam > dynamicCullLimit) return float2(1.0, 0.0);
    
    float3 shadowLightPos = float3(
        Flashlight_ShadowOffsetX * Flashlight_ProjectionScale,
        Flashlight_ShadowOffsetY * Flashlight_ProjectionScale,
        Flashlight_ShadowOffsetZ
    );

    // Beam axis (view space)
    float3 targetPos = float3(0.0, 0.0, aimDepth);
    float3 beamAxis = normalize(targetPos - visualLightPos);

    // Smoothly fades shadow strength on surfaces nearly parallel to the beam
    // (grazing angles), using a proper view-space normal reconstructed from
    // the depth buffer.
    float grazingFade = Flashlight_ComputeGrazingFade(uv, beamAxis);
    
    // If the surface is almost exactly parallel, skip the raymarch entirely (performance)
    if (grazingFade < 0.001) {
        return float2(1.0, 0.0);
    }

    // -------------------------------------------------------------------------
    // Raymarch the shadow
    // -------------------------------------------------------------------------
    float penumbraPixels; 
    float shadow = CalculateDirectionalOcclusion(
        uv, 
        pixelPos, 
        normal, 
        depthGrad, 
        shadowLightPos,
        Flashlight_ShadowContactRange * SHADOW_SCALE,
        Flashlight_ShadowThicknessLimit * SHADOW_SCALE,
        Flashlight_ShadowReachMultiplier,
        penumbraPixels
    );

    // Apply the grazing fade (smoothly transitions from no shadow to full shadow)
    shadow = lerp(1.0, shadow, grazingFade);

    // Existing cull fade (based on beam distance)
    float cullFade = smoothstep(dynamicCullLimit, dynamicCullLimit * 0.85, distFromBeam);
    shadow = lerp(1.0, shadow, cullFade);
    
    return float2(shadow, penumbraPixels);
}

// Pass 6: depth-aware blur of the raw shadow buffer. Blur radius grows with
// the estimated penumbra size from the raymarch, so contact shadows stay
// crisp while softer/farther shadows get smoothed more.
float PS_BlurShadow(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    float2 centerSample = tex2D(sShadowRaw, uv).rg;
    float centerShadow = centerSample.r;
    float centerPenumbra = centerSample.g;
    
    float effectiveRadius = (Flashlight_ShadowBlurRadius + min(centerPenumbra, 8.0)) * SHADOW_SCALE * Flashlight_ShadowMasterBlend;
    if (effectiveRadius <= 0.0001) return centerShadow;
    
    float centerDepth = ReShade::GetLinearizedDepth(uv).r;
    float2 texelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT) * effectiveRadius;
    static const float2 offsets[8] = {
        float2( 1.0,  0.0), float2(-1.0,  0.0), float2( 0.0,  1.0), float2( 0.0, -1.0),
        float2( 0.7,  0.7), float2(-0.7,  0.7), float2( 0.7, -0.7), float2(-0.7, -0.7)
    };
    float totalShadow = centerShadow;
    float totalWeight = 1.0;
    
    [unroll]
    for (int i = 0; i < 8; i++) {
        float2 sampleUV = uv + offsets[i] * texelSize;
        float sampleDepth = ReShade::GetLinearizedDepth(sampleUV).r;
        float sampleShadow = tex2D(sShadowRaw, sampleUV).r;
        
        float depthDiff = abs(sampleDepth - centerDepth);
        float blurDepthEps = ViewSpaceExtentFromPixels(1.5, centerDepth * Flashlight_WorldScale);
        float depthWeight = exp(-(depthDiff * depthDiff) / max(blurDepthEps * blurDepthEps, 1e-10));
        totalShadow += sampleShadow * depthWeight;
        totalWeight += depthWeight;
    }
    
    return totalShadow / max(totalWeight, 0.0001);
}

// Pass 7: the main lighting pass. Projects the true 3D cone, shapes it
// (edge falloff, chromatic aberration, cookie, tilt deflection), combines it
// with ambient bounce and shadows, then applies artifact removal/pre-lift,
// colour tint, sharpening and contrast before writing the final pixel.
float4 PS_Flashlight(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {

    float depthVal = ReShade::GetLinearizedDepth(uv).r;
    if (depthVal >= 0.999) discard; 
    
    float3 normal = tex2D(sNormalSmooth, uv).xyz;
    float nearCutoffScaled = Flashlight_NearCutoff * Flashlight_WorldScale;
    float nearFade = step(nearCutoffScaled, depthVal * Flashlight_WorldScale);
    float3 pixelPos = GetViewSpacePosition(uv);
    float3 lightPos = float3(
        Flashlight_OffsetX * Flashlight_ProjectionScale,
        Flashlight_OffsetY * Flashlight_ProjectionScale,
        Flashlight_OffsetZ
    );

    float2 beamUV;
    float flashlightSizeVisual = CalculateFlashlightSize(depthVal, Flashlight_Size, Flashlight_BeamDivergenceShape, Flashlight_BeamDivergenceSoftness, Flashlight_BeamDivergenceRange, Flashlight_Distance, Flashlight_WorldScale);
    float normalizedDist = GetNormalizedBeamDistance(uv, pixelPos, lightPos, depthVal, normal, flashlightSizeVisual, beamUV);

    // =========================================================================
    // TEXTURE PARALLAX OFFSET
    // =========================================================================
    float3 texturePos;
    float2 cookieUV;
    Flashlight_ComputeParallaxOffset(
        pixelPos, normal, lightPos, beamUV, flashlightSizeVisual,
        Flashlight_TextureDepthOffset, Flashlight_WorldScale, Flashlight_ParallaxCookieMinSize,
        texturePos, cookieUV
    );

    // --- CHROMATIC ABERRATION ---
    float3 caScales = float3(1.0 - Flashlight_ConeCA, 1.0, 1.0 + Flashlight_ConeCA);
    float3 normalizedDistRGB = normalizedDist * caScales;
    float3 gaussianRGB = exp(-Flashlight_EdgeFalloff * normalizedDistRGB * normalizedDistRGB);
    float3 coneRaw = gaussianRGB * saturate(1.0 - normalizedDistRGB);
    // ----------------------------

    float worldDepthForFalloff = depthVal * max(Flashlight_WorldScale, 0.001);
    float depthFalloff = pow(max(1.0 - worldDepthForFalloff, 0.0), 1.0 / max(Flashlight_Distance, 0.001));
    
    float3 lightDir = normalize(lightPos - pixelPos);
    float facing = ComputeFacingTerm(normal, lightDir, depthVal);

    // ---- FETCH BASE COLOR EARLY (needed for shadowMix and pre‑lift) ----
    float3 color = tex2D(sColor, uv).rgb;
    float3 preLightColor = color; // keep for later

    float baseLuminance = dot(color, float3(0.299, 0.587, 0.114));
    float shadowTerm = Flashlight_UseShadows ? tex2D(sShadowBlur, uv).r : 1.0;
    float shadowLumFactor = 1.0 / (1.0 + (10.0 / max(Flashlight_ShadowLogIntensity, 0.001)) * (1.0 - baseLuminance));
    float shadowMix = lerp(1.0, shadowTerm, shadowLumFactor);

    // ---- AMBIENT SHAPE (now computed early) ----
    float ambientShape = 0.0;
    if (Flashlight_UseAmbient) {
        ambientShape = ComputeAmbientRing(depthVal, normalizedDist, depthFalloff, Flashlight_AmbientDistance * max(Flashlight_WorldScale, 0.001));
        ambientShape *= facing * lerp(0.3, 1.0, shadowMix);
    }

    // ---- CONE AND AMBIENT INTENSITY ----
    float aimDepth = GetAimDepth();
    float scattering = ComputeScatteringBoost(depthVal, normalizedDist, aimDepth, Flashlight_AmbientDepthBoost, coneRaw.g, depthFalloff);
    if (Flashlight_UseAngleScattering) {
        float rawFacing = dot(normal, lightDir);
        scattering *= ComputeAngleScattering(rawFacing);
    }

    float worldDepth = depthVal * Flashlight_WorldScale;
    float proximityAmp = 1.0 + 5.0 * exp(-25.0 * worldDepth / max(Flashlight_NearCutoff * Flashlight_WorldScale, 0.001));

    float cookieMask = 1.0;
    if (Flashlight_UseCookie) {
        // cookieUV is calculated in the parallax block above now
        float cookieSample = tex2D(sFlashlightCookie, cookieUV).r;
        cookieMask = lerp(1.0, cookieSample, Flashlight_CookieStrength);
    }

    float3 coneFinal = coneRaw * facing * shadowMix * depthFalloff * nearFade * cookieMask;
    float maxConeFinal = max(coneFinal.r, max(coneFinal.g, coneFinal.b));

    float ambientIntensity = 0.0;
    if (Flashlight_UseAmbient) {
        ambientIntensity = ambientShape * scattering * Flashlight_AmbientStrengthMaster * 500.0 * nearFade;
    }

    // ---- EARLY EXIT (no light at all) ----
    const float LIT_THRESHOLD = 0.00001;
    float litAmount = max(maxConeFinal, ambientIntensity);
    if (litAmount < LIT_THRESHOLD) {
        return float4(preLightColor, 1.0); // return original (untouched) colour
    }

    // ---- ARTIFACT REMOVAL (applied before pre-lift) ----
    float artifactAttenuation = 1.0;
    if (Flashlight_UseArtifactRemoval) {
        color = Flashlight_ApplyArtifactRemoval(color, 0.004, pixelPos, normal, artifactAttenuation);
    }

    // =========================================================================
    // PRE‑LIFT: GIVE PURE‑BLACK PIXELS A TINY BASELINE (using local scene colour)
    // =========================================================================
    if (Flashlight_UseArtifactRemoval && Flashlight_EnablePreLift) {
        
        // Actually call the pre-lift function from the helper library
        color = Flashlight_ApplyPreLift(
            color,
            uv,
            texturePos, // Passing texturePos to respect the parallax offset
            normal,
            normalizedDist,
            ambientShape,
            Flashlight_DebugPreLift
        );
        
        // --- DEBUG EARLY EXIT ---
        // The ApplyPreLift function has already painted the eligible pixels red
        if (Flashlight_DebugPreLift) {
            return float4(color, 1.0);
        }
    }


    // ---- CALCULATE GRAIN MODULATOR FOR ADDITIVE RESCUE ----
    // Flat addition destroys the micro-contrast of the pre-lift baseline. 
    // To restore the texture, we apply the grain pattern directly to the additive rescue knob.
    float finalRescueBrightness = Flashlight_NearBlackRescueBrightness;
    
    if (Flashlight_UseArtifactRemoval && Flashlight_EnablePreLift) {
        float grainSample = Flashlight_SampleGrain(pixelPos, normal, Flashlight_GrainScale);
        float grainStrength = saturate(Flashlight_GrainBrightness / 10.0);
        
        // Map the 0..1 grain sample to a multiplier centered at 1.0 
        // This ensures the average brightness stays identical to your slider setting
        float grainModulator = 1.0 + (grainSample - 0.5) * (grainStrength * 1.5);
        finalRescueBrightness *= grainModulator;
    }

// ---- APPLY LIGHTING ----
    float3 colored_cone = coneFinal * Flashlight_Color;
    float coneEdgeFactor = saturate(1.0 - normalizedDist);
    color = Flashlight_ApplyCombinedLight(
        color,
        colored_cone,
        (Flashlight_Brightness * proximityAmp) * artifactAttenuation,
        Flashlight_LogIntensity,
        0.05,
        Flashlight_Color,
        ambientIntensity * artifactAttenuation,
        Flashlight_AmbientLogIntensity,
        0.20,
        Flashlight_UseAmbient,
        coneEdgeFactor,
        finalRescueBrightness // <--- Pass the modulated grain variable here
    );

    // ---- COLOUR TINT ----
    float lightIntensity = length(colored_cone) / max(length(Flashlight_Color), 0.001);
    color = Flashlight_ApplyColorTint(
        color,
        Flashlight_Color,
        lightIntensity,
        Flashlight_ColorTintStrength
    );

    // ---- SHARPENING ----
    float sharpenWeight = saturate(coneFinal.g);
    color = ApplySharpening(color, uv, sharpenWeight, 0.30);

    // ---- CONTRAST ----
    color = ApplyContrast(color, normalizedDist, ambientShape, Flashlight_ContrastMaster, depthVal, Flashlight_Distance, lightIntensity);

    return float4(color, 1.0);
}

// =============================================================================
// TECHNIQUE
// =============================================================================

technique EasyFlashlight
{
    // 1. Reconstruct a per-pixel view-space normal from the depth buffer.
    pass ComputeNormals
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_ComputeNormals;
        RenderTarget = NormalRawTex;
    }
    // 2. Optional bilateral blur of the raw normals (Smooth Normals toggle),
    //    to hide low-poly faceting. Pass-through when the toggle is off.
    pass SmoothNormals
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_SmoothNormals;
        RenderTarget = NormalSmoothTex;
    }
    // 3. Accumulate a 1x1 (via mip chain) depth average of whatever the beam
    //    is roughly pointed at. Everything downstream that needs to know
    //    "how far away is the thing I'm lighting" reads this.
    pass AccumulateAimDepth
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_AccumulateAimDepth;
        RenderTarget = AimAccumTex;
        GenerateMipMaps = true;
    }
    // 4. Build a small blurred copy of the scene colour, used later to give
    //    pure-black pixels a plausible tinted baseline instead of staying flat 0.
    pass DownsampleSceneColor
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_DownsampleSceneColor;
        RenderTarget = SceneColorDownsampled;
        GenerateMipMaps = true; // <-- Tells ReShade to build the whole-frame average
    }
    // 5. Raymarch screen-space contact shadows from the beam toward each pixel.
    pass ComputeShadow
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_ComputeShadow;
        RenderTarget = ShadowRawTex;
    }
    // 6. Depth-aware bilateral blur of the raw shadow term to soften noise
    //    and raymarch stepping artifacts without bleeding across depth edges.
    pass BlurShadow
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_BlurShadow;
        RenderTarget = ShadowBlurTex;
    }
    // 7. Main lighting pass: builds the cone + ambient bounce, applies
    //    shadows, artifact removal, colour tint, sharpening and contrast,
    //    and writes the final composited image.
    pass FlashlightLighting
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Flashlight;
        SRGBWriteEnable = true;
    }
}