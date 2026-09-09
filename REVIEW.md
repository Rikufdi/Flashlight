# Flashlight — How it works & improvement review

Two files, one ReShade effect:

- **`EasyFlashlight.fx`** — the "recipe": UI sliders, render targets, the 7-pass technique, the per-pass pixel shaders, and the main lighting pass.
- **`Flashlight.fxh`** — helper library: constants, geometry/beam math, the shadow raymarch, lighting compositing, and colour processing.
- **Textures:** `Flashlight_Grain.png` (grain for pure-black surfaces), `Flashlight_Cookie.png` (cone gobo).

## Core ideas

- **Depth-buffer only.** There is no access to world/view matrices, so everything is done in *view space*, reconstructed from the linearized depth buffer. `Flashlight_WorldScale` is the master calibration that turns the game's depth scale into a common unit used across every calculation.
- **Beam aimed at a depth, not the screen centre.** A small accumulation buffer (pass 3) computes a weighted-average "what is the beam pointed at" depth (`GetAimDepth()`). The beam axis runs from a virtual light position (just behind the camera, `Offset*`) to that depth point on the view axis. Everything — cone shape, cookie, ambient, scattering, pre-lift, shadow culling — is defined relative to that axis.
- **Virtual 1080p canvas.** Beam-space math is normalized against a fixed 1080p-tall reference (`VIRTUAL_CANVAS_HEIGHT`) so the beam size is resolution-independent.
- **Hybrid lighting.** A pure-black pixel has no colour to brighten, so a *rescue* path seeds it with a whole-scene average colour + grain and adds light additively (with clamped chroma). Everything else uses a *logarithmic multiplicative* curve that lifts dark pixels more than bright ones while preserving hue, then a Reinhard-style soft shoulder prevents hard clipping. The rescue is also angle-shaded (`Flashlight_RescueAngleStrength`): `ComputeRescueFacing` uses the tangential (X/Y) surface-facing dot only — the shared Z component of visible surfaces dominates a full 3D dot and buried the cue — wraps it, and scales the additive term, so pure-black faces of the same geometry separate by orientation instead of reading as one flat grey patch. `Flashlight_RescueFacingTintStrength` additionally tints that rescue luma-neutrally by facing direction (right reddish, left greenish, up yellowish, down bluish), so faces also separate by hue; the tint is luma-normalised, so the scene-colour seed and rescue brightness are untouched.

## The 7 passes

| # | Pass | Buffer | Purpose |
|---|------|--------|---------|
| 1 | `ComputeNormals` | `NormalRaw` (RGBA16F, full-res) | Reconstruct a view-space normal per pixel from 3 depth samples; depth in `.w`. |
| 2 | `SmoothNormals` | `NormalSmooth` (RGBA16F, full-res) | Optional 12-tap bilateral blur (depth + normal weighted) to hide low-poly faceting. Pass-through when off. |
| 3 | `AccumulateAimDepth` | `AimAccum` (256² RG32F, 9 mips) | Writes `(depth·weight, weight)`; the mip chain reduces to a 1×1 beam-aimed depth. |
| 4 | `DownsampleSceneColor` | `SceneColor` (128² RGBA16F, 8 mips) | Saturation/luminance-weighted block average → whole-frame "vibrant" colour for the black-pixel rescue. |
| 5 | `ComputeShadow` | `ShadowRaw` (RG16F) | Screen-space raymarch from receiver toward the light to find occluders; outputs `(shadow, penumbra)`. |
| 6 | `BlurShadow` | `ShadowBlur` (RG16F) | Depth-aware 8-tap blur; radius grows with penumbra so contact shadows stay crisp. |
| 7 | `FlashlightLighting` | backbuffer | Builds cone + ambient, applies shadow, rescue/pre-lift, tint, sharpen, contrast. |

## Shadow subsystem (passes 5–6)

- `ShouldSkipShadow` bails early: shadows off, near-cutoff (weapon), too close to the light, or past max range.
- `CalculateDirectionalOcclusion` → `MarchShadowRay`: `FLASHLIGHT_SHADOW_STEPS` (default 8) steps biased toward the receiver (`pow(t, 1.6)`), jittered with interleaved noise. Each step projects into screen space, reads scene depth, and accumulates a weighted hit (contact blend × thickness limit × distance attenuation × blocker fade).
- `FinalizeShadow` normalizes hits by softness, blends a crisp/soft term, and estimates the penumbra (source radius × blocker geometry) — which drives the blur radius in pass 6.
- `PS_ComputeShadow` additionally culls by beam distance (a dynamic cull limit that widens when ambient is on and near the focal depth) and fades at grazing angles, where screen-space raymarching is unreliable.

## Lighting compositing (pass 7, `PS_Flashlight`)

1. Near-cutoff fade (excludes weapon/arms); reconstruct position + normal.
2. `CalculateFlashlightSize` — depth-dependent cone size (divergence narrows near / widens far).
3. `GetNormalizedBeamDistance` — projects the pixel into beam space, applies tilt deflection (cone bends toward the surface normal) with edge damping to avoid cel-shaded outlines; outputs `normalizedDist` + `beamUV` (cookie coords).
4. `Flashlight_ComputeParallaxOffset` — shifts the sample point along the normal and re-derives the cookie UV so the gobo keeps a consistent projected size.
5. Chromatic aberration (per-channel `normalizedDist` scale) → Gaussian cone × `saturate(1-d)`.
6. Depth falloff `pow(1-depth, 1/Distance)`, wrapped-Lambert facing term (floor 0.85, wrap 0.8, power 2), log-intensity-weighted shadow mix, ambient ring (Gaussian peaking just outside the cone), depth-coherent scattering boost, close-up proximity amp, cookie mask.
7. `Flashlight_ApplyCombinedLight` — the heart: log-scale multiplicative boost + near-black additive rescue (clamped chroma, angle-shaded via `ComputeRescueFacing`) + soft shoulder + highlight desat.
8. `Flashlight_ApplyColorTint` (shortest-path HSV hue shift, saturation-protected), `ApplySharpening` (4-neighbour, weighted by cone-centre), `ApplyContrast` (S-curve with darkness protection and an overbright-inversion guard).

## Improvement review

### High value, low risk

**1. Skip the shadow passes when shadows are off (the default).**
`Flashlight_UseShadows` defaults to **0**, but passes 5 and 6 still run every frame. `PS_ComputeShadow` does a full normal + depth reconstruction, a beam-space projection (including the 8-tap edge-damping read), and a grazing-fade normal reconstruction *before* `ShouldSkipShadow` — the function that actually checks the toggle — gets a chance to bail. And `PS_BlurShadow` runs a full-screen 8-tap depth-weighted blur over a buffer full of `1.0`.

Fix: put `if (!Flashlight_UseShadows) return float2(1.0, 0.0);` at the top of `PS_ComputeShadow`, and `if (!Flashlight_UseShadows) return 1.0;` at the top of `PS_BlurShadow`. These are uniform branches, so the cost is essentially free — this removes **two full-screen passes in the default configuration** with no visual change. It is the single biggest win available.

**2. Gate the edge-damping reads in `GetNormalizedBeamDistance`.**
The 8 extra texture reads (4 depth + 4 normal) only feed `edgeDamp`, which only scales the tilt deflection. If `Flashlight_TiltDeflection == 0` or `Flashlight_EdgeDampening == 0`, the whole block is wasted. Wrap it in `if (Flashlight_TiltDeflection > 0.0 && Flashlight_EdgeDampening > 0.0)` and skip the reads. Saves 8 reads per pixel on the main pass (and the shadow cull pass).

### Medium

**3. Unify the three near-black thresholds.**
Three independent constants each define "dark pixel" with different bands: artifact removal (`lum < 0.004`), pre-lift (`isDark` over `0–0.012`), and the rescue range (`Flashlight_NearBlackRescueRange = 0.003`). They interact across `ApplyCombinedLight` and the pre-lift path, so it is hard to reason about what a pixel at `lum = 0.005` is "supposed" to be. Either consolidate to one "darkness" definition with named roles, or add a comment block at the top of `ApplyCombinedLight` documenting the intended cascade and which constant owns which band.

**4. Light-position consistency between the shadow cull and the main beam.**
`PS_ComputeShadow` uses `visualLightPos = float3(OffsetX, OffsetY, OffsetZ)` (no `ProjectionScale`), while `PS_Flashlight` uses `Offset* * ProjectionScale`. With `ProjectionScale ≈ 0.9` and a non-zero offset, the shadow cull region and the rendered beam are slightly misaligned. Negligible today because the default offsets are near-zero, but it is a latent inconsistency — use the same scaled position in both.

### Low / trivial

**5. Hoist the repeated `GetAimDepth()` calls.** `PS_Flashlight` reaches `GetAimDepth()` through `GetNormalizedBeamDistance`, directly, and again inside `ApplyPreLift`. Each is a 1×1 mipmap read (L1-cached) so the cost is tiny, but computing it once into a local and passing it through would be cleaner and remove a hidden dependency.

### Known limits (not actionable inside ReShade)

- **Grain is view-space, not world-locked.** `Flashlight_SampleGrain` triplanes in view space because ReShade does not expose the view matrix. It holds up under camera translation but drifts slightly when you look around. This is a hard API limit; the current approach is the pragmatic best.
- **Shadows are screen-space only.** Reconstructed normals + depth raymarching cannot recover hidden detail, so per-game tuning is unavoidable (already documented in the README). Keep `Shadow Max Range` low and tune `ProjectionScale` / `WorldScale` per game.
- **Black-pixel rescue is a heuristic.** ReShade has no pre-light colour for a pure-black pixel, so borrowing a scene average + grain is the best possible. The `DownsampleUseRaw` toggle exists exactly because gamma vs linear matters here. Angle shading (`Near-Black Rescue Angle Shading`, `ComputeRescueFacing`) mitigates the flat-grey look by scaling the rescue with surface orientation relative to the beam.

### For the "simpler flashlight" goal (README §future)

You wrote that some features "are not contributing meaningfully to the overall feel." Ranked by lowest visual impact per line removed, what I would cut for an "easy" version:

1. **Chromatic aberration** — a subtle fringe; a few lines in the cone calc.
2. **Tilt deflection + edge damping** — the expensive 8-tap block in `GetNormalizedBeamDistance`; most beams look fine without the bend.
3. **Cone cookie + parallax** — a nice-to-have gobo; a plain cone reads fine.
4. **Highlight desat + sharpen** — polish passes; the log curve + soft shoulder already do the heavy lifting.

Keep: cone shape, log brightness, the ambient ring, rescue/pre-lift, and optional shadows — that is the core that "preserves colour best."
