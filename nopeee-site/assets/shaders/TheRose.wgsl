// Copyright (c) 2026 depis. All Rights Reserved.
// Unauthorized commercial use, redistribution, or reproduction is prohibited.

// Mirrors the 32-byte buffer written from JS. color_t is the red<->white
// crossfade; quality is a continuous float (0.0 low -> 2.0 high);
// click_time is the timestamp (in seconds) of the last left-click/tap.
struct Uniforms {
  resolution: vec2f,
  time: f32,
  color_t: f32,
  yaw: f32,
  pitch: f32,
  quality: f32,
  click_time: f32,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

// ---------------------------------------------------------------------------
// Compile-Time Performance & Feature Toggles (Dead-Code Eliminated when false)
// ---------------------------------------------------------------------------

// Major Scene Elements
const ENABLE_FLOWER            = true; // Rose head, stem, thorns, and leaves
const ENABLE_FALLING_PETALS    = true; // 3D falling petals in map()
const ENABLE_PETAL_FLOOR_FX    = true; // 2x2 petal shadows and glow on the ground
const ENABLE_HOLE_TENTACLES    = true; // Large writhing tentacles around the center hole
const ENABLE_CREVICE_TENTACLES = true; // Rising green tentacles sprouting from roots
const ENABLE_TENTACLE_THORNS   = true; // Rose thorns on the large center-hole tentacles
const ENABLE_CREVICE_THORNS    = true; // Mini thorns on the rising green root tentacles
const ENABLE_ROOT_NETWORK      = true; // Heightmap root arteries and web on the ground
const ENABLE_SHADOWS           = true; // Soft shadow raymarch pass
const ENABLE_VOLUMETRIC_GLOW   = true; // Per-step glow accumulation in the raymarch loop
const ENABLE_WILD_EVENT        = true; // Click-triggered monster tentacle, rose frenzy & brick-alignment event

// Ground & Brick Sub-Features
const ENABLE_TEXTURED_GROUND   = true; // Master switch for brick geometry & materials
const ENABLE_GROUND_BBOX_OPT   = true; // Skips brick/root heightmap math when ray is high in the air
const ENABLE_BRICK_WARP        = true; // 2x noise2D domain warping for irregular brick shapes
const ENABLE_BRICK_CHIPS       = true; // 2x noise2D inward edge chipping
const ENABLE_BRICK_HOLES       = true; // 2x noise2D surface pits/craters on brick tops
const ENABLE_GROUND_FBM_MAT    = true; // FBM noise for moss/dirt/rock color blending
const ENABLE_CREVICE_GLOW      = true; // Subtle emissive glow inside the crevices between bricks

// Smooth Quality Fade Ranges (uniforms.quality smoothly glides between 0.0 and 2.0)
const QUALITY_FADE_SHADOWS     = vec2f(0.15, 0.85); // Shadows fade in between 0.15 and 0.85
const QUALITY_FADE_PETAL_FX    = vec2f(0.15, 0.80); // Petal floor lights/shadows fade in between 0.15 and 0.80
const QUALITY_FADE_ROOTS       = vec2f(0.20, 0.90); // Ground roots grow & fade in between 0.20 and 0.90
const QUALITY_FADE_MAT_DETAIL  = vec2f(0.20, 1.10); // Dirt/moss FBM detail fades in between 0.20 and 1.10
const QUALITY_FADE_THORNS      = vec2f(0.65, 1.35); // Tentacle thorns sprout outward between 0.65 and 1.35
const QUALITY_FADE_BRICK_MICRO = vec2f(0.80, 1.55); // Brick chips & surface holes indent between 0.80 and 1.55
const QUALITY_FADE_TENTACLES   = vec2f(0.85, 1.65); // Small green tentacles sprout upward between 0.85 and 1.65

// ---------------------------------------------------------------------------
// Tunables. Anything worth poking at lives up here.
// ---------------------------------------------------------------------------

// Volumetric Glow, Flower Halo & Crevice Glow Tunables
const GLOW_GENERAL_STRENGTH       = 1.25; // Master multiplier for all volumetric glow (petals, thorns, tentacles)
const GLOW_ROSE_HALO_STRENGTH     = 1.85; // Extra multiplier specifically for the rose head bounding-sphere halo
const GLOW_RED_MODE_BOOST         = 2.60; // Boosts volumetric glow when red so red halos/dissolves pop like white
const CREVICE_GLOW_STRENGTH       = 0.38; // Emissive glow strength inside the mortar grooves between bricks
const PETAL_FLOOR_LIGHT_INTENSITY = 2.20; // Strength of the point lights cast by falling petals on the floor
const PETAL_FLOOR_RED_BOOST       = 2.80; // Extra intensity boost when the floor point light is red
const PETAL_FLOOR_LIGHT_RADIUS    = 0.36; // Radius of the point light glow on the bricks

// Tentacle Thorn Tunables
const TENTACLE_THORN_SCALE     = 0.055; // Size of thorns on the large center-hole tentacles
const CREVICE_THORN_SCALE      = 0.024; // Size of thorns on the smaller green root tentacles

// Click-Triggered Wild Event Tunables
const WILD_EVENT_DURATION      = 2.4;  // How many seconds the wild event lasts after left-clicking
const WILD_TENTACLE_THIN_MULT  = 0.70; // Slight thinning multiplier for tentacles during the event
const WILD_HOLE_WRITHE_MULT    = 2.2;  // Thrashing multiplier for the visible rose-hole tentacles
const WILD_CREVICE_SWAY_MULT   = 2.1;  // Thrashing multiplier for the visible green root tentacles
const WILD_ROSE_SPIN_STRENGTH  = 2.8;  // How far the rose head petals spin/whip around during the event
const WILD_ROSE_JITTER_AMOUNT  = 0.05; // How much the rose head petals shift outward during the event

// Camera. pitch/yaw come from the mouse; these set the resting pose.
const CAM_RADIUS     = 2.0;   // distance out from the flower
const CAM_HEIGHT     = 2.0;   // eye height, and what we look at
const CAM_PITCH      = 0.5;   // base tilt before the mouse offset
const CAM_PITCH_GAIN = 0.1;   // how much vertical mouse move tilts the view

// Raymarch. STEP_SCALE under-relaxes each step: below 1.0 is safer on the
// warped/gooey surfaces here but costs more steps.
const STEP_SCALE = 0.42;
const SURF_EPS   = 0.0012;  // distance that counts as a hit
const MAX_DIST   = 20.0;    // bail once a ray gets this far out
const NORMAL_EPS = 0.002;   // sample spread for the shading normal

// Per-tier step budgets (interpolated smoothly by uniforms.quality).
const STEPS_LOW    : i32 = 125;
const STEPS_HIGH   : i32 = 185;
const SHADOW_STEPS : i32 = 16;

// Key light.
const LIGHT_POS       = vec3f(1.0, 6.0, 0.0);
const LIGHT_INTENSITY = 11.0;

// Atmosphere.
const FOG_DENSITY      = 0.012;       // black distance fog on geometry
const GLOW_FOG_DENSITY = 0.002;       // weaker fog so bloom lingers in air
const GRAIN_STRENGTH   = 25.0 / 255.0;

// Palette. color_t crossfades between these at runtime.
const COLOR_RED   = vec3f(0.298, 0.078, 0.075) * 0.5;
const COLOR_WHITE = vec3f(0.8, 0.722, 0.722) * 0.5;

// Material ids, packed into the .y of every distance result.
const MAT_GROUND        = 0.0;
const MAT_STEM          = 1.0;
const MAT_ROSE          = 2.0;
const MAT_HOLE          = 3.0;
const MAT_DISSOLVE      = 4.0;
const MAT_THORNS        = 5.0;
const MAT_LEAVES        = 6.0;
const MAT_TENTACLE      = 7.0;
const MAT_FALLING_PETAL = 8.0;

// ---------------------------------------------------------------------------
// Ground Texture Macros
// ---------------------------------------------------------------------------
const BRICK_SHAPE           = 1; // 0 = Rectangular, 1 = Hexagonal
const BRICK_SIZE            = vec2f(0.5, 0.5);
const BRICK_HEIGHT          = 0.06;
const BRICK_MORTAR_WIDTH    = 0.04;
const BRICK_CORNER_RADIUS   = 0.025; // Rounds the 6 hex points or 4 box corners
const BRICK_BEVEL           = 0.02; 
const MORTAR_BLEND_SOFTNESS = 0.06;  // How softly rock/dirt/moss discolors the mortar edges
const CREVICE_AO_STRENGTH   = 0.45;  // Ambient occlusion darkening right along the brick-to-mortar crease
const CREVICE_AO_WIDTH      = 0.025; // Spread of the ambient occlusion shadow in the crevice

// Brick Deformities & Irregularities
const BRICK_WARP_FREQ       = 2.0;   // Frequency of organic shape bending
const BRICK_WARP_AMOUNT     = 0.35;  // How much bricks warp/bend into irregular polygons
const BRICK_CHIP_FREQ       = 16.0;  // Frequency of edge chips and notches
const BRICK_CHIP_AMOUNT     = 0.022; // How deep the chipped edges eat into the stone
const BRICK_HOLE_FREQ       = 11.0;  // Frequency of surface craters/pits
const BRICK_HOLE_DEPTH      = 0.45;  // Depth of surface pits (0.0 to 1.0)
const BRICK_HEIGHT_VAR      = 0.35;  // Per-brick height variation so stones sit unevenly

// Noise Patterns
const NOISE_MACRO_SCALE     = 8.5;
const NOISE_DETAIL_SCALE    = 31.0;

// Material Colors
const COLOR_ROCK            = vec3f(0.18, 0.18, 0.20);
const COLOR_STONE2          = vec3f(0.004, 0.005, 0.004);
const COLOR_DIRT            = vec3f(0.298, 0.078, 0.075);
const COLOR_MOSS            = vec3f(0.071, 0.216, 0.118) * 2.0;
const COLOR_MORTAR_2        = vec3f(0.298, 0.078, 0.075) * 2.5;
const COLOR_MORTAR          = vec3f(1.0, 1.0, 1.0) * 1.5;

// Material Properties: (Roughness, Specular Power)
const MAT_PROP_ROCK         = vec2f(60.0, 1.0);
const MAT_PROP_DIRT         = vec2f(2.0, 0.4);
const MAT_PROP_MOSS         = vec2f(5.0,  0.2);
const MAT_PROP_MORTAR       = vec2f(80.0, 0.02);

// Crevice Tentacles & Heightmap Root Network
const VINES_MAX_RADIUS         = 8.5;   // Large outer radius where ground vines/roots smoothly fade out
const ROOT_HEIGHT              = 0.015; // Heightmap elevation of the surface roots
const ROOT_THICKNESS           = 0.010; // Base width of the surface roots
const TENTACLE_ROOT_THICK_MULT = 2.0;   // 1.0 = tentacle base matches the exact root width it grows from
const CREVICE_DOMAIN_SIZE      = 0.4;   // Size of the repetition grid
const CREVICE_SHIFT_AMOUNT     = 0.8;   // How far they can wander from the cell center (0.0 to 1.0)
const CREVICE_MAX_HEIGHT       = 0.75;  // Base height they can grow to

// ---------------------------------------------------------------------------
// Smooth Quality Fade Helpers (0.0 -> 1.0)
// ---------------------------------------------------------------------------
fn getShadowFade() -> f32 {
    if (!ENABLE_SHADOWS) { return 0.0; }
    return smoothstep(QUALITY_FADE_SHADOWS.x, QUALITY_FADE_SHADOWS.y, uniforms.quality);
}

fn getPetalFxFade() -> f32 {
    if (!ENABLE_PETAL_FLOOR_FX) { return 0.0; }
    return smoothstep(QUALITY_FADE_PETAL_FX.x, QUALITY_FADE_PETAL_FX.y, uniforms.quality);
}

fn getRootFade() -> f32 {
    if (!ENABLE_ROOT_NETWORK) { return 0.0; }
    return smoothstep(QUALITY_FADE_ROOTS.x, QUALITY_FADE_ROOTS.y, uniforms.quality);
}

fn getMatDetailFade() -> f32 {
    return smoothstep(QUALITY_FADE_MAT_DETAIL.x, QUALITY_FADE_MAT_DETAIL.y, uniforms.quality);
}

fn getThornFade() -> f32 {
    if (!ENABLE_TENTACLE_THORNS && !ENABLE_CREVICE_THORNS) { return 0.0; }
    return smoothstep(QUALITY_FADE_THORNS.x, QUALITY_FADE_THORNS.y, uniforms.quality);
}

fn getBrickMicroFade() -> f32 {
    return smoothstep(QUALITY_FADE_BRICK_MICRO.x, QUALITY_FADE_BRICK_MICRO.y, uniforms.quality);
}

fn getCreviceTentacleFade() -> f32 {
    if (!ENABLE_CREVICE_TENTACLES || !ENABLE_ROOT_NETWORK) { return 0.0; }
    return smoothstep(QUALITY_FADE_TENTACLES.x, QUALITY_FADE_TENTACLES.y, uniforms.quality);
}

// Click-triggered 0.0 -> 1.0 -> 0.0 envelope for the wild event
fn getWildEventFactor(time: f32) -> f32 {
    if (!ENABLE_WILD_EVENT) { return 0.0; }
    let elapsed = time - uniforms.click_time;
    if (elapsed <= 0.0 || elapsed >= WILD_EVENT_DURATION) {
        return 0.0;
    }
    // Fast 0.22s attack on click, followed by a smooth ease-out over WILD_EVENT_DURATION
    let attack = smoothstep(0.0, 0.22, elapsed);
    let release = smoothstep(WILD_EVENT_DURATION, WILD_EVENT_DURATION * 0.28, elapsed);
    let raw = attack * release;
    return raw * raw * (3.0 - 2.0 * raw);
}

@vertex
fn vs_main(@builtin(vertex_index) in_vertex_index: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f(3.0, -1.0),
    vec2f(-1.0, 3.0)
  );
  return vec4f(pos[in_vertex_index], 0.0, 1.0);
}

fn hash12(p: vec2f) -> f32 {
    var p3  = fract(vec3f(p.xyx) * .1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn opRotateY(p: vec3f, angle: f32) -> vec3f {
    let c = cos(angle);
    let s = sin(angle);
    return vec3f(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}

fn opRotateX(p: vec3f, angle: f32) -> vec3f {
    let c = cos(angle);
    let s = sin(angle);
    return vec3f(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

fn opRotateZ(p: vec3f, angle: f32) -> vec3f {
    let s = sin(angle);
    let c = cos(angle);
    return vec3f(c * p.x - s * p.y, s * p.x + c * p.y, p.z);
}

fn sdCone(p: vec3f, c: vec2f, h: f32) -> f32 {
    let q = length(p.xz);
    return max(dot(c, vec2f(q, p.y)), -h - p.y);
}

// Shared thorn SDF (used by the rose stem, center tentacles, and root tentacles)
fn sdSpine(p: vec3f) -> f32 {
    var q = p - vec3f(0.0, 0.7, 0.0);

    q.z *= 7.0;
    q.x /= abs(q.y) * 0.7;
    q.x -= (1.0 + q.y) * 1.5;

    let h = 1.0;
    let r = 0.15;

    return sdCone(q, vec2f(r, r), h);
}

fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

fn noise2D(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash12(i);
    let b = hash12(i + vec2f(1.0, 0.0));
    let c = hash12(i + vec2f(0.0, 1.0));
    let d = hash12(i + vec2f(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn sdRoundedBox2D(p: vec2f, b: vec2f, r: f32) -> f32 {
    let q = abs(p) - b + vec2f(r);
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Exact 2D distance to a pointy-topped hexagon (branchless)
fn sdHexagon(p_in: vec2f, r: f32) -> f32 {
    let k = vec3f(-0.866025404, 0.5, 0.577350269);
    
    // Swap X and Y to orient the hexagon points vertically
    var p = abs(vec2f(p_in.y, p_in.x)); 
    
    p -= 2.0 * min(dot(k.xy, p), 0.0) * k.xy;
    p -= vec2f(clamp(p.x, -k.z * r, k.z * r), r);
    return length(p) * sign(p.y);
}

// Returns vec3f(signed_distance, cell_id.x, cell_id.y)
// Handles organic domain warping, unclipped Voronoi hex tiling, and smooth-fading edge chipping
fn getBrickData(p_xz: vec2f) -> vec3f {
    var warped_xz = p_xz;
    let wild = getWildEventFactor(uniforms.time);

    // 1. Low-frequency domain warp: goes to 0.0 during the wild event so stones align into a perfect shape, then comes back
    if (ENABLE_BRICK_WARP) {
        let warp = vec2f(
            noise2D(p_xz * BRICK_WARP_FREQ),
            noise2D(p_xz * BRICK_WARP_FREQ + vec2f(17.3, 29.1))
        ) - 0.5;
        let current_warp_amount = BRICK_WARP_AMOUNT * (1.0 - wild);
        warped_xz += warp * current_warp_amount;
    }

    var d = 0.0;
    var cell_id = vec2f(0.0);

    if (BRICK_SHAPE == 0) {
        var uv = warped_xz;
        let row = floor(uv.y / BRICK_SIZE.y);
        if (fract(row * 0.5) > 0.0) { uv.x += BRICK_SIZE.x * 0.5; }

        cell_id = floor(uv / BRICK_SIZE);
        let local_p = (fract(uv / BRICK_SIZE) - 0.5) * BRICK_SIZE;
        let brick_half_size = (BRICK_SIZE * 0.5) - vec2f(BRICK_MORTAR_WIDTH * 0.5);
        d = sdRoundedBox2D(local_p, brick_half_size, BRICK_CORNER_RADIUS);
    } else {
        // True 2-grid Hexagonal Voronoi tiling (prevents clipped tips and domain seams)
        let s = vec2f(BRICK_SIZE.x, BRICK_SIZE.y * 1.73205081);
        let h = s * 0.5;

        let a_id = floor(warped_xz / s);
        let b_id = floor((warped_xz - h) / s);

        let a = warped_xz - (a_id + 0.5) * s;
        let b = warped_xz - h - (b_id + 0.5) * s;

        let use_a = dot(a, a) < dot(b, b);
        let local_p = select(b, a, use_a);
        cell_id = select(b_id + vec2f(13.7, 27.3), a_id, use_a);

        // Subtract corner radius before sdHexagon so outer bounds stay inside the Voronoi cell
        let r = (min(BRICK_SIZE.x, BRICK_SIZE.y) * 0.5) - (BRICK_MORTAR_WIDTH * 0.5) - BRICK_CORNER_RADIUS;
        d = sdHexagon(local_p, r) - BRICK_CORNER_RADIUS;
    }

    // 2. High-frequency inward edge chipping: smoothly indents as quality rises
    let micro_fade = getBrickMicroFade();
    if (ENABLE_BRICK_CHIPS && micro_fade > 0.001 && abs(d) < 0.09) {
        let n1 = noise2D(p_xz * BRICK_CHIP_FREQ);
        let n2 = noise2D(p_xz * BRICK_CHIP_FREQ * 2.17 + vec2f(31.4, 15.9));
        let chip_noise = smoothstep(0.25, 0.85, n1 * 0.65 + n2 * 0.35);
        d += chip_noise * BRICK_CHIP_AMOUNT * micro_fade;
    }

    return vec3f(d, cell_id.x, cell_id.y);
}

fn getBrickDistance(p_xz: vec2f) -> f32 {
    return getBrickData(p_xz).x;
}

// Continuity-preserving FBM: higher octaves smoothly blend in from the noise mean (0.48)
// so moss/dirt patches never jump or shift position when quality changes.
fn fbm(p: vec2f) -> f32 {
    var f = 0.0;
    var uv = p;
    var amp = 0.5;
    let q = uniforms.quality;

    for (var i = 0; i < 4; i++) {
        // Octave 0 is always active; octaves 1..3 smoothly fade in as quality increases
        let octave_start = f32(i - 1) * 0.45 + 0.1;
        let w = select(smoothstep(octave_start, octave_start + 0.5, q), 1.0, i == 0);

        if (w > 0.001) {
            f += amp * mix(0.48, noise2D(uv), w);
        } else {
            f += amp * 0.48;
        }
        uv *= 2.0;
        amp *= 0.5;
    }
    return f;
}

// Shared 2D distance to the root network (used by both the heightmap and tentacle spawning)
fn getRootDistance2D(p_xz: vec2f, r: f32, a: f32, time: f32) -> f32 {
    // 1. Primary radial arteries spiraling out from the center hole
    let wave1 = sin(r * 3.5 - time * 0.05 + sin(a * 3.0) * 1.2) * 0.45;
    let d_radial1 = abs(sin((a + wave1) * 3.0)) * (r / 5.0);

    // 2. Secondary counter-spiraling roots that cross and branch with the primary ones
    let wave2 = cos(r * 4.5 + time * 0.05 + cos(a * 4.0) * 1.2) * 0.45;
    let d_radial2 = abs(sin((a + wave2) * 4.0)) * (r / 7.0);

    // 3. Domain-warped 2D gyroid web to link the roots across the bricks
    let gp = p_xz * 1.5 + vec2f(sin(p_xz.y * 1.5), cos(p_xz.x * 1.5)) * 0.7;
    let d_web = abs(sin(gp.x) * cos(gp.y) + sin(gp.y * 1.2) * cos(gp.x * 1.2)) * 0.16;

    // Smoothly weld the radial arteries and the surface web together in 2D
    return smin(smin(d_radial1, d_radial2, 0.03), d_web, 0.035);
}

// Returns the local half-width of the root network at distance r from the center
fn getRootLocalWidth(r: f32) -> f32 {
    let inner_fade = smoothstep(4.5, 4.0, r);
    let outer_fade = smoothstep(VINES_MAX_RADIUS, VINES_MAX_RADIUS - 2.0, r);
    let root_fade = getRootFade();
    return ROOT_THICKNESS * (0.5 + 0.5 * inner_fade) * outer_fade * smoothstep(0.0, 0.6, root_fade);
}

// Continuous, loop-free heightmap root network radiating from the center rose
fn getRootHeight(p_xz: vec2f, r: f32, a: f32, time: f32, root_fade: f32) -> f32 {
    if (r >= VINES_MAX_RADIUS || root_fade <= 0.001) { return 0.0; }
    let d_roots = getRootDistance2D(p_xz, r, a, time);
    let width = getRootLocalWidth(r);

    // Parabolic cylindrical profile for the heightmap
    let norm_d = clamp(d_roots / max(width, 0.0005), 0.0, 1.0);
    let profile = (1.0 - norm_d * norm_d);
    let outer_fade = smoothstep(VINES_MAX_RADIUS, VINES_MAX_RADIUS - 2.0, r);

    return profile * profile * ROOT_HEIGHT * outer_fade * root_fade;
}

// Small, chaotic tentacles that sprout directly from the root network and smoothly grow with quality
fn sdCreviceTentacles(p: vec3f, time: f32, best_d: f32, crevice_fade: f32) -> vec2f {
    let current_max_h = CREVICE_MAX_HEIGHT * crevice_fade;

    // Fast bounding plane: skip the 2x2 loop completely when the ray is above the current tentacle height
    let max_y = -0.5 + current_max_h + 0.15;
    if (p.y > max_y) {
        return vec2f(p.y - max_y + 0.1, MAT_LEAVES);
    }

    let wild = getWildEventFactor(time);
    let thorn_fade = getThornFade() * smoothstep(0.2, 0.7, crevice_fade);
    let spacing = CREVICE_DOMAIN_SIZE;
    let cell = floor(p.xz / spacing);
    let local_p = fract(p.xz / spacing) - 0.5;
    let sign_p = sign(local_p);

    var d_min = 100.0;
    var mat_id = MAT_LEAVES;
    let PI = 3.14159265;
    let relax = mix(0.75, 0.62, wild);
    let cutoff_dist = best_d / relax;

    // 2x2 neighbor check to prevent ray tearing when shifting objects across cells
    for (var i: f32 = 0.0; i <= 1.0; i += 1.0) {
        for (var j: f32 = 0.0; j <= 1.0; j += 1.0) {
            let neighbor_offset = vec2f(i, j) * sign_p;
            let current_cell = cell + neighbor_offset;
            let cell_center = (current_cell + 0.5) * spacing;

            // If this neighbor cell is already further away than our closest hit (best_d or d_min), skip it!
            let cell_min_dist = length(p.xz - cell_center) - spacing * 0.85;
            if (cell_min_dist > min(d_min, cutoff_dist)) {
                continue;
            }

            // Generate two distinct random seeds based on the cell coordinate
            let seed1 = hash12(current_cell);
            let seed2 = hash12(current_cell + vec2f(13.3, 41.5));

            let offset = (vec2f(seed1, seed2) - 0.5) * (spacing * CREVICE_SHIFT_AMOUNT);
            let raw_xz = cell_center + offset;

            let r_raw = max(length(raw_xz), 0.001);
            if (r_raw >= VINES_MAX_RADIUS) { continue; }

            // Analytically pull the candidate point onto the nearest radial root artery
            let a_raw = atan2(raw_xz.y, raw_xz.x);
            let wave1 = sin(r_raw * 3.5 - time * 0.05 + sin(a_raw * 3.0) * 1.2) * 0.45;
            let wave2 = cos(r_raw * 4.5 + time * 0.05 + cos(a_raw * 4.0) * 1.2) * 0.45;

            let theta1 = (a_raw + wave1) * 3.0;
            let err1 = (theta1 - round(theta1 / PI) * PI) / 3.0;
            let theta2 = (a_raw + wave2) * 4.0;
            let err2 = (theta2 - round(theta2 / PI) * PI) / 4.0;

            let best_err = select(err2, err1, abs(err1) < abs(err2));
            let snapped_a = a_raw - best_err;
            let snapped_xz = vec2f(cos(snapped_a), sin(snapped_a)) * r_raw;

            // Clamp within the cell's safe radius so tentacles never clip across cell boundaries
            let max_shift = spacing * 0.42;
            let root_xz = cell_center + clamp(snapped_xz - cell_center, vec2f(-max_shift), vec2f(max_shift));

            // Evaluate the exact root distance and local root width at this spawn point
            let r = length(root_xz);
            let a = atan2(root_xz.y, root_xz.x);
            let root_d = getRootDistance2D(root_xz, r, a, time);
            let local_root_width = getRootLocalWidth(r);

            // How centered the sprout is on the root section (1.0 at center of root, 0.0 at edge)
            let root_norm = clamp(root_d / max(local_root_width, 0.0005), 0.0, 1.0);
            let root_section_factor = sqrt(max(0.0, 1.0 - root_norm * root_norm));

            if (root_section_factor > 0.05) {
                // Fade them out near the center dirt hole and at the outer VINES_MAX_RADIUS circle
                let hole_size = 0.5 + sin(time * 0.3) * 0.2;
                let hole_mask = smoothstep(hole_size * 0.7, hole_size * 1.0, r);
                let outer_fade = smoothstep(VINES_MAX_RADIUS, VINES_MAX_RADIUS - 2.0, r);
                let final_growth = root_section_factor * hole_mask * outer_fade;

                if (final_growth > 0.01) {
                    // Anchor base at y = -0.5 so it merges cleanly out of the root ridges
                    var q = vec3f(p.x - root_xz.x, p.y - (-0.5), p.z - root_xz.y);

                    // Height scales smoothly with crevice_fade so tentacles sprout upward instead of popping in
                    let max_h = current_max_h * final_growth * (0.4 + seed1 * 0.6);
                    let h = clamp(q.y, 0.0, max_h);

                    // Calm sway vs. frenzied high-frequency thrashing on existing tentacles
                    let calm_x = sin(time * 6.0 + seed1 * 700.0 + h * 12.0 * seed2) * 0.2 * h * seed1;
                    let calm_z = cos(time * 5.1 + seed2 * 500.0 + h * 11.0 * seed1) * 0.2 * h * seed2;

                    let wild_x = (sin(time * 16.0 + seed1 * 700.0 + h * 18.0) + 0.4 * cos(time * 22.0 - h * 14.0 + seed2 * 300.0)) * 0.16 * WILD_CREVICE_SWAY_MULT * h * (0.4 + 0.6 * seed1);
                    let wild_z = (cos(time * 14.5 + seed2 * 500.0 + h * 16.0) + 0.4 * sin(time * 20.0 - h * 13.0 + seed1 * 400.0)) * 0.16 * WILD_CREVICE_SWAY_MULT * h * (0.4 + 0.6 * seed2);

                    let sway_x = mix(calm_x, wild_x, wild);
                    let sway_z = mix(calm_z, wild_z, wild);

                    let core = vec3f(sway_x, h, sway_z);
                    
                    // Inherit root thickness, tapering in smoothly with crevice_fade
                    let thick_fade = smoothstep(0.0, 0.4, crevice_fade);
                    let inherited_base_r = local_root_width * root_section_factor * TENTACLE_ROOT_THICK_MULT * mix(1.0, WILD_TENTACLE_THIN_MULT, wild) * thick_fade;
                    let taper_c = 1.0 - (h / max(max_h, 0.0001));
                    let thickness = inherited_base_r * taper_c;
                    var d = length(q - core) - thickness;
                    var local_mat = MAT_LEAVES;

                    // Fast bounded mini-thorns on the green root tentacles (only evaluated within 3.5cm of the tentacle)
                    if (ENABLE_CREVICE_THORNS && thorn_fade > 0.001 && d < 0.035 && h > 0.04 && h < max_h * 0.88) {
                        let c_spacing = 0.055;
                        let c_id = floor(h / c_spacing);
                        let local_y = (fract(h / c_spacing) - 0.5) * c_spacing;

                        let t_angle = c_id * 2.4 + seed1 * 6.28318;
                        let ca = cos(t_angle);
                        let sa = sin(t_angle);
                        let cross_xz = vec2f(q.x - core.x, q.z - core.z);
                        let radial = cross_xz.x * ca + cross_xz.y * sa;
                        let lateral = -cross_xz.x * sa + cross_xz.y * ca;

                        let spine_scale = CREVICE_THORN_SCALE * (0.35 + 0.65 * taper_c) * thorn_fade;
                        let p_s = vec3f(-local_y, radial - thickness, lateral);
                        let d_spine = sdSpine(p_s / max(spine_scale, 0.0005)) * spine_scale;

                        if (d_spine < d) {
                            local_mat = MAT_THORNS;
                        }
                        d = smin(d, d_spine, 0.0025 * thorn_fade);
                    }

                    if (d < d_min) {
                        d_min = d;
                        mat_id = local_mat;
                    }
                }
            }
        }
    }
    
    // Under-relax slightly more during the wild event to handle steep bends safely
    return vec2f(d_min * relax, mat_id); 
}

fn getGroundHeight(p_xz: vec2f) -> f32 {
    if (!ENABLE_TEXTURED_GROUND) { return 0.0; }

    let brick_data = getBrickData(p_xz);
    let d = brick_data.x;
    let brick_id = brick_data.yz;

    var height_mask = smoothstep(0.0, -BRICK_BEVEL, d);

    // 1. Per-brick height variation so stones sit slightly unevenly
    let brick_var = 1.0 + (hash12(brick_id + vec2f(7.1, 19.3)) - 0.5) * BRICK_HEIGHT_VAR;
    height_mask *= brick_var;

    // 2. Surface craters and pits etched into the top of the bricks: depth scales smoothly with micro_fade
    let micro_fade = getBrickMicroFade();
    if (ENABLE_BRICK_HOLES && micro_fade > 0.001 && height_mask > 0.001) {
        let pit_n1 = noise2D(p_xz * BRICK_HOLE_FREQ + vec2f(12.3, 45.6));
        if (pit_n1 > 0.38) {
            let pit_n2 = noise2D(p_xz * BRICK_HOLE_FREQ * 2.3 + vec2f(67.8, 23.4));
            let holes = smoothstep(0.58, 0.88, pit_n1 * 0.7 + pit_n2 * 0.3);
            let hole_mask = holes * smoothstep(0.0, 0.4, height_mask);
            height_mask = max(0.0, height_mask - hole_mask * BRICK_HOLE_DEPTH * micro_fade);
        }
    }

    return height_mask * BRICK_HEIGHT;
}

fn sdVerticalVesicaSegment(p: vec3f, h_in: f32, w_in: f32) -> f32 {
    var h = h_in * 0.5;
    var w = w_in * 0.5;

    let d = 0.5 * (h * h - w * w) / w;
    let q = vec2f(length(p.xz), abs(p.y - h));
    let condition = (h * q.x < d * (q.y - h));

    let t = select(
        vec3f(-d, 0.0, d + w),
        vec3f(0.0, h, 0.0),
        condition
    );

    return length(q - t.xy) - t.z;
}

fn dot2(v: vec3f) -> f32 {
    return dot(v, v);
}

fn udTriangle(p: vec3f, a: vec3f, b: vec3f, c: vec3f) -> f32 {
    let ba = b - a;
    let pa = p - a;
    let cb = c - b;
    let pb = p - b;
    let ac = a - c;
    let pc = p - c;

    let nor = cross(ba, ac);

    let cond_val = sign(dot(cross(ba, nor), pa)) +
                   sign(dot(cross(cb, nor), pb)) +
                   sign(dot(cross(ac, nor), pc));

    let d_edge_a = dot2(ba * clamp(dot(ba, pa) / dot2(ba), 0.0, 1.0) - pa);
    let d_edge_b = dot2(cb * clamp(dot(cb, pb) / dot2(cb), 0.0, 1.0) - pb);
    let d_edge_c = dot2(ac * clamp(dot(ac, pc) / dot2(ac), 0.0, 1.0) - pc);

    let dist_edge = min(min(d_edge_a, d_edge_b), d_edge_c);
    let dist_face = dot(nor, pa) * dot(nor, pa) / dot2(nor);

    let result_sq = select(
        dist_face,
        dist_edge,
        cond_val < 2.0
    );

    return sqrt(result_sq);
}

fn opPolarRep(p: vec3f, repetitions: f32, offset_radius: f32) -> vec3f {
    let PI = 3.14159265;
    let angle_step = 2.0 * PI / repetitions;

    let current_angle = atan2(p.z, p.x);
    let dist = length(p.xz);

    let sector = round(current_angle / angle_step);
    let new_angle = current_angle - sector * angle_step;

    let q_xz = vec2f(
        cos(new_angle) * dist,
        sin(new_angle) * dist
    );

    return vec3f(q_xz.x - offset_radius, p.y, q_xz.y);
}

fn smax(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
    return mix(a, b, h) + k * h * (1.0 - h);
}

// ring of writhing tentacles around the hole (with adaptive rose thorns)
fn sdTentacles(p: vec3f, time: f32, hole_radius: f32, include_thorns: bool) -> vec2f {
    let wild = getWildEventFactor(time);
    let repetitions = 11.0;
    let angle_step = 6.28318 / repetitions;

    let a = atan2(p.z, p.x);
    let sector = round(a / angle_step);
    let new_angle = a - sector * angle_step;

    let dist = length(p.xz);
    let root_y = -0.75;

    var q = vec3f(
        cos(new_angle) * dist,
        p.y - root_y,
        sin(new_angle) * dist
    );

    let cycle_angle = time * 0.4 + sector * 3.7;
    let advanced_angle = cycle_angle + 0.007;
    let retract_blend = smoothstep(0.05, -0.05, cos(advanced_angle));

    // Keep the exact original spawn_phase & growth_factor so no extra tentacles appear
    let spawn_phase = sin(cycle_angle);
    let growth_factor = smoothstep(-0.2, 0.6, spawn_phase);

    if (growth_factor < 0.01) {
        return vec2f(100.0, MAT_HOLE);
    }

    let max_length = 2.2 * growth_factor;
    let h = clamp(q.x, 0.0, max_length);

    let base_arch = h * 1.2 - (h * h * 0.35);
    let tip_mask = smoothstep(max_length * 0.6, max_length, h);
    let tip_lift = pow(tip_mask, 2.0) * 0.7;

    let arch_y = base_arch + tip_lift;
    let phase = sector * 13.5;

    let move_mask = smoothstep(0.2, max_length, h);
    let calm_wy = sin(time * 4.0 + h * 6.0 + phase) * 0.15;
    let calm_wz = cos(time * 3.1 + h * 5.0 + phase) * 0.15;

    // Fast, chaotic monster thrashing on the already-visible tentacles
    let wild_wy = (sin(time * 13.5 + h * 9.0 + phase) + 0.45 * cos(time * 19.0 - h * 11.0 + phase)) * 0.12 * WILD_HOLE_WRITHE_MULT;
    let wild_wz = (cos(time * 12.0 + h * 8.0 + phase) + 0.45 * sin(time * 17.5 - h * 10.0 + phase)) * 0.12 * WILD_HOLE_WRITHE_MULT;

    let writhe_y = mix(calm_wy, wild_wy, wild) * move_mask;
    let writhe_z = mix(calm_wz, wild_wz, wild) * move_mask;

    let core_line = vec3f(h, arch_y + writhe_y, writhe_z);

    let cross_section = vec2f(q.y - core_line.y, q.z - core_line.z);
    let angle_around = atan2(cross_section.y, cross_section.x);
    let twist = h * 12.0 - time * 3.0;

    let total_angle = (angle_around * 3.0) + twist;
    let muscle_lobes = cos(total_angle);
    let bumps = sin(h * 30.0 - time * 5.0) * cos(angle_around * 5.0);

    let taper = 1.0 - (h / max_length);
    // Make the tentacles slightly thinner during the wild event
    let thin_scale = mix(1.0, WILD_TENTACLE_THIN_MULT, wild);
    let base_thickness = 0.06 * thin_scale * growth_factor * taper;
    let gooey_thickness = base_thickness + (muscle_lobes * 0.02 * thin_scale * taper) + (bumps * 0.005 * taper);

    var d = length(q - core_line) - gooey_thickness;

    let single_wrap = (angle_around + (twist / 3.0)) / 6.2831853;
    let lobe_id = floor(fract(single_wrap + 100.1666) * 3.0);

    var lobe_mat = MAT_HOLE;

    if (lobe_id == 1.0) {
        lobe_mat = MAT_STEM;
    } else if (lobe_id == 2.0) {
        lobe_mat = MAT_TENTACLE + clamp(retract_blend, 0.0, 0.99);
    }

    // Fast bounded thorns on the tentacles: only evaluated when quality > 0.65 and ray is within 9cm of the skin
    let thorn_fade = getThornFade();
    if (ENABLE_TENTACLE_THORNS && include_thorns && thorn_fade > 0.001 && d < 0.09 && h > 0.12 && h < max_length * 0.92) {
        let thorn_spacing = 0.11 * growth_factor;
        let thorn_id = floor(h / max(thorn_spacing, 0.001));
        let local_h = (fract(h / max(thorn_spacing, 0.001)) - 0.5) * thorn_spacing;

        // Evaluate twist at the thorn's center so each thorn sits rigidly on the twisting skin
        let h_center = (thorn_id + 0.5) * thorn_spacing;
        let twist_center = h_center * 12.0 - time * 3.0;
        let thorn_angle = thorn_id * 2.4 + sector * 1.7 - (twist_center / 3.0);

        let ca = cos(thorn_angle);
        let sa = sin(thorn_angle);
        let radial = cross_section.x * ca + cross_section.y * sa;
        let lateral = -cross_section.x * sa + cross_section.y * ca;

        let lobe_at_thorn = cos(thorn_angle * 3.0 + twist_center);
        let surface_r = base_thickness + (lobe_at_thorn * 0.02 * thin_scale * taper);

        let spine_scale = TENTACLE_THORN_SCALE * growth_factor * (0.3 + 0.7 * taper) * thorn_fade;
        let p_s = vec3f(-local_h, radial - surface_r, lateral);
        let d_spine = sdSpine(p_s / max(spine_scale, 0.0005)) * spine_scale;

        if (d_spine < d) {
            lobe_mat = MAT_THORNS;
        }
        d = smin(d, d_spine, 0.006 * thorn_fade);
    }

    return vec2f(d * mix(0.45, 0.38, wild), lobe_mat);
}

// one rose petal
fn sdPetal(p: vec3f, s: f32) -> f32 {
    var pos = p;

    let t = smoothstep(0.2, 0.35, s);
    let width_factor = mix(0.3, 1.0, t);

    let cup_strength = mix(1.9, 0.05, t);
    let cup_strength_y = mix(0.2, 0.5, t);
    pos.z += pos.x * pos.x * cup_strength;
    pos.z += pos.y * pos.y * cup_strength_y;

    let curl_factor = mix(0.9, 3.2, t);

    let tip_height = max(pos.y - 0.3, 0.0);
    let tip_side = max(abs(pos.x) / curl_factor - 0.1, 0.0);

    let curl_amount = pow(tip_height, 2.0) * 2.0 * t + pow(tip_side, 2.0) * 0.8;
    pos.z -= curl_amount;

    let bulge_domain = vec2f(pos.x, pos.y * 0.7);
    let dist_sq = dot(bulge_domain, bulge_domain);
    let gaussian = exp(-4.0 * dist_sq);
    let bulge_strength = 0.25;

    pos.z -= gaussian * bulge_strength;

    let taper_strength = mix(0.3, 0.5, t);
    let taper = 1.0 + taper_strength * pos.y;

    let p_x = (pos.x) / (clamp(taper, 0.1, 2.0) * width_factor);
    let d_2d = length(vec2f(p_x, pos.y)) - 0.8;
    
    let thickness = 0.01;
    let d_z = abs(pos.z) - thickness;

    let w = vec2f(d_2d, d_z);
    return min(max(w.x, w.y), 0.0) + length(max(w, vec2f(0.0)));
}

// petals drifting down and dissolving everywhere across the ground
fn sdFallingPetals(p: vec3f, time: f32, best_d: f32) -> vec2f {
    let spacing = 2.0;
    let cell = floor(p.xz / spacing);
    let local_p = fract(p.xz / spacing) - 0.5;
    let sign_p = sign(local_p);

    var d_min: f32 = 100.0;
    var final_mat: f32 = MAT_FALLING_PETAL;

    for (var i: f32 = 0.0; i <= 1.0; i += 1.0) {
        for (var j: f32 = 0.0; j <= 1.0; j += 1.0) {
            let neighbor_offset = vec2f(i, j) * sign_p;
            let current_cell = cell + neighbor_offset;

            let seed = hash12(current_cell);
            let seed2 = hash12(current_cell + vec2f(13.3, 41.5));

            let speed = 0.55 + seed * 0.25;
            let start_h = 7.0 + seed2 * 1.0;
            let cycle_duration = 19.0;

            let local_time = (time + seed * 20.0) % cycle_duration;

            let virtual_drop_y = start_h - (local_time * speed);
            let ground_y = -0.40; // Raised from -0.45 so petals land slightly higher above the bricks
            let ground_dist = virtual_drop_y - ground_y;

            let size = 0.1 + seed * 0.04;

            var actual_y: f32 = virtual_drop_y;
            let landing_zone = 0.5;

            if (ground_dist < landing_zone && ground_dist > 0.0) {
                let t = ground_dist / landing_zone;
                actual_y = ground_y + landing_zone * (t * t);
            } else if (ground_dist <= 0.0) {
                actual_y = ground_y;
            }

            let cell_center_xz = (current_cell + 0.5) * spacing;
            var q = vec3f(p.x - cell_center_xz.x, p.y - actual_y, p.z - cell_center_xz.y);

            let wind_damp = smoothstep(-0.1, 0.5, ground_dist);
            q.x += sin(time * 1.5 + seed * 10.0) * 0.25 * wind_damp;
            q.z += cos(time * 1.2 + seed2 * 10.0) * 0.25 * wind_damp;

            // Fast per-petal sphere bound: skip 3D rotations, exp(), and noise when ray is far from this petal
            let d_sphere = (length(q) - size * 1.05) * 0.6;
            if (d_sphere >= min(d_min, best_d)) {
                continue;
            }
            if (d_sphere > 0.16) {
                d_min = d_sphere;
                final_mat = MAT_FALLING_PETAL;
                continue;
            }

            let dissolve_progress = smoothstep(12.0, 19.0, local_time);
            let resting_dist = max(0.0, actual_y - ground_y);

            let target_rot_x = 1.570796;
            let target_rot_z = 0.0;

            let rot_x = target_rot_x - (resting_dist * (2.5 + seed));
            let rot_z = target_rot_z - (resting_dist * (1.0 + seed * 5.0));

            let fall_progress = start_h - actual_y;
            let rot_y = fall_progress * 1.5 + seed * 20.0;

            // 1. Rotate around World Y first (horizontal spin)
            q = opRotateY(q, rot_y);
            // 2. Pitch and Roll in the air; as resting_dist -> 0, rot_x -> 90 deg and rot_z -> 0 (lands flat)
            q = opRotateX(q, rot_x);
            q = opRotateZ(q, rot_z);

            let local_q = q / size;
            let d_base = sdPetal(local_q, 0.32) * size;

            let noise = (sin(local_q.x * 6.0) * sin(local_q.y * 9.0) * sin(local_q.z * 2.0)) * 0.5 + 0.5;

            // Start hole_size at -rim_thickness so opposite-color noise spots first appear and grow on the intact petal,
            // then cross d_holes = 0.0 to eat away the center of the glowing spots without ever flipping back to petal color.
            let rim_thickness = 0.12;
            let hole_size = mix(-rim_thickness, 1.25, dissolve_progress);
            let d_holes = (1.0 - noise) - hole_size;

            let d = select(
                d_base * 0.6,
                max(d_base, -d_holes * size * 0.45) * 0.6,
                dissolve_progress > 0.0
            );

            if (d < d_min) {
                d_min = d;

                if (dissolve_progress > 0.0 && d_holes < rim_thickness) {
                    // max(d_holes, 0.0) keeps the eating edge locked at 1.0 (opposite color) instead of reverting to petal color
                    let edge_ramp = smoothstep(rim_thickness, 0.0, max(d_holes, 0.0));
                    let air_fade = smoothstep(-0.30, -0.05, d_holes);
                    let glow_intensity = edge_ramp * air_fade;
                    final_mat = MAT_DISSOLVE + clamp(glow_intensity, 0.001, 0.99);
                } else {
                    let dist_from_root = max(length(q + vec3f(0.0, 0.13, 0.0)) - 0.02, 0.0);
                    let gradient = clamp(dist_from_root * 8.0, 0.0, 0.99);
                    final_mat = MAT_FALLING_PETAL + gradient;
                }
            }
        }
    }
    return vec2f(d_min, final_mat);
}

// rose head: petals on a golden-angle spiral (spins and flutters rapidly during the wild event)
fn sdRose(p: vec3f) -> vec2f {
    let raw_time = uniforms.time;
    let wild = getWildEventFactor(raw_time);

    // Expand bounding sphere slightly during the wild event so fluttering petals aren't clipped
    let bound_r = mix(0.3, 0.44, wild);
    let d_sphere = length(p - vec3f(0.0, 0.1, 0.0)) - bound_r;

    if (d_sphere > 0.05) {
        return vec2f(d_sphere, MAT_ROSE);
    }

    var d_min = 100.0;
    let petal_count = 15.0;
    let golden_angle = 2.39996;
    let time = raw_time * 2.0;

    for (var i: f32 = 1.0; i < 15.0; i += 1.0) {
        let r = (0.01) * sqrt(i) + wild * WILD_ROSE_JITTER_AMOUNT * (0.5 + 0.5 * sin(raw_time * 14.0 + i * 2.1));

        // Fast chaotic petal rotation & swirling around the rose core during the wild event
        let wild_spin = (sin(raw_time * 9.0 + i * 0.6) + 0.5 * cos(raw_time * 15.0 - i * 1.1)) * WILD_ROSE_SPIN_STRENGTH * wild;
        let theta = i * golden_angle + wild_spin;

        let wild_y_jitter = cos(raw_time * 12.0 + i * 1.7) * (WILD_ROSE_JITTER_AMOUNT * 0.7) * wild;
        let petal_center = vec3f(r * cos(theta), -r * 0.2 + wild_y_jitter, r * sin(theta));
        let scale = 0.1 + (i / petal_count) * 0.25;

        var q = p - petal_center;
        q = opRotateY(q, -theta + 1.57);

        let calm_tilt = -0.3 + (i / petal_count) * (0.9 + sin(time) * 0.15);
        let wild_tilt = calm_tilt + sin(raw_time * 16.0 + i * 2.3) * 0.55 * wild;
        q = opRotateX(q, -wild_tilt);
        q = opRotateZ(q, cos(raw_time * 13.0 + i * 1.5) * 0.35 * wild);
        q = q / 0.2;

        let pivot_offset = vec3f(0.0, 0.7, 0.0);
        let d = sdPetal(q - pivot_offset, scale) * scale;

        d_min = min(d_min, d);
    }

    let dist_from_center = max(length(p + vec3f(0.0, 0.1, 0.0)) - 0.05, 0.0);
    let gradient = clamp(dist_from_center * 3.5, 0.0, 0.99);

    return vec2f(d_min * mix(1.0, 0.75, wild), MAT_ROSE + gradient);
}

// leaf blade on a short bent petiole
fn sdLeaf(p: vec3f) -> f32 {
    let petiole_length = 0.12;
    let p_start = vec3f(0.0, 0.0, 0.0);
    let p_end = vec3f(petiole_length, 0.03, 0.0);

    let pa = p - p_start;
    let ba = p_end - p_start;
    let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    let d_petiole = length(pa - ba * h) - 0.008;

    var q = p - p_end;

    q.y += q.x * q.x * 0.5;
    q.y -= abs(q.z) * 0.2;

    let blade_len = 0.25;
    q.x -= blade_len;

    let normalized_x = (q.x + blade_len) / (blade_len * 2.0);
    let leaf_width = 0.15 * sin(normalized_x * 3.14159);

    let vein_pattern = cos(q.x * 120.0 - abs(q.z) * 80.0) * 0.5 + 0.5;
    let vein_mask = smoothstep(0.0, 0.02, abs(q.z)) * (1.0 - normalized_x * 0.5);

    q.y += vein_pattern * vein_mask * 0.0015;

    let scale = vec3f(blade_len, 0.005, max(leaf_width, 0.01));

    let k0 = length(q / scale);
    let k1 = length(q / (scale * scale));
    let d_blade = k0 * (k0 - 1.0) / k1;

    return smin(d_petiole, d_blade, 0.015) * 0.75;
}

// stem, thorns and leaves in a single pass
fn sdStemWithSpines(p: vec3f, a: vec3f, b: vec3f, bend: f32, r: f32) -> vec2f {
    let pa = p - a;
    let ba = b - a;
    let ba_length = length(ba);
    let time = uniforms.time;
    let wild = getWildEventFactor(time);

    let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    let wiggle = sin(h * 10.28318) * 0.5;
    let straightness_mask = pow((1.0 - h), 0.8);
    let offset_dir = vec3f(bend, 0.0, bend * 0.2);

    // Subtle stem shudder during the wild event
    let wild_stem_wave = vec3f(
        sin(time * 12.0 + h * 14.0) * 0.04,
        0.0,
        cos(time * 11.0 + h * 12.0) * 0.04
    ) * h * (1.0 - h) * 4.0 * wild;

    let current_offset = offset_dir * wiggle * straightness_mask + wild_stem_wave;

    let pos_on_line = a + ba * h + current_offset;
    let stem_radius = r * (1.0 - h * 0.4);
    let dist_to_stem = length(p - pos_on_line);

    let d_stem = (dist_to_stem - stem_radius) * 0.6;

    var d_spine = 100.0;

    if (dist_to_stem < 0.2 && h > 0.1 && h < 0.9) {
        let density = 15.0;
        let id = floor(h * density);
        let local_y = (fract(h * density) - 0.5) * (ba_length / density);

        var p_s = p - pos_on_line;
        p_s = opRotateY(p_s, id * 2.4);
        p_s.y = local_y;
        p_s.x -= stem_radius;
        p_s = opRotateZ(p_s, 1.57);

        let scale = 0.08;
        d_spine = sdSpine(p_s / scale) * scale;
    }

    var d_leaf = 100.0;

    // Full 0.85 radius so leaf tips are never cut off
    if (dist_to_stem < 0.85) {
        let leaf_density = 4.5;
        let id = floor(h * leaf_density);

        if (id > 0.0 && id < 4.0) {
            let local_y = (fract(h * leaf_density) - 0.5) * (ba_length / leaf_density);

            var p_l = p - pos_on_line;
            p_l = opRotateY(p_l, id * 2.4 + 1.0);
            p_l.y = local_y;

            p_l.x -= (stem_radius - 0.01);

            let wind_sway = mix(sin(time * 3.5 + id * 1.2) * 0.07, sin(time * 14.0 + id * 1.2) * 0.18, wild);
            let wind_twist = mix(cos(time * 2.8 + id * 1.5) * 0.05, cos(time * 12.0 + id * 1.5) * 0.15, wild);

            let droop_angle = 0.3 - (id * 0.2) + wind_sway;
            p_l = opRotateZ(p_l, droop_angle);
            p_l = opRotateX(p_l, wind_twist);

            d_leaf = sdLeaf(p_l);
        }
    }

    let d_stem_d_leaf = smin(d_stem, d_leaf, 0.003);
    var fin = smin(d_stem_d_leaf, d_spine, 0.01);

    var material = MAT_STEM;

    if (d_leaf < d_stem) {
        material = MAT_LEAVES;
    }

    if (d_spine < d_stem_d_leaf) {
        material = MAT_THORNS;
    }

    return vec2f(fin, material);
}

// assembles the flower: stem, sepals, bud and rose head
fn flower(p: vec3f, location: vec3f) -> vec2f {
    let d_sphere = length(p - vec3f(0.0, 1.0, 0.0)) - 0.45;

    if (d_sphere > 1.3) {
        return vec2f(d_sphere, 0.0);
    }

    let time = uniforms.time;

    let center = vec3f(sin(time) * 0.05, (1.0 - abs(sin(time))) * 0.03, sin(time) * 0.03);
    let pos = p - (center + location);
    let pos_all = p - location;

    let wind_bend = 0.3 + sin(1.5) * 0.01;
    let stem_start = vec3f(0.0, -location.y - 0.5, 0.0);
    let stem_end = center;

    let d_stem = sdStemWithSpines(pos_all, stem_start, stem_end, wind_bend, 0.04);

    var q = opPolarRep(pos, 5.0, 0.1);

    let curve = q.x * q.x * 8.0;
    let wave = sin(time + q.x * 50.0) * 0.005 + sin(time + q.z * 50.0) * 0.005 + sin(time + q.x * 80.0) * 0.003 + sin(time + q.z * 80.0) * 0.003;

    q.y += curve + wave;

    let size = 0.1;
    let v1 = vec3f(0.0, 0.0, -1.0 * size * 0.5);
    let v2 = vec3f(0.0, 0.0,  1.0 * size * 0.5);
    let v3 = vec3f(1.5 * size, 0.0, 0.0);

    let d_flat = udTriangle(q, v1, v2, v3);
    let d_sepals = d_flat - 0.01;

    var d_bud = sdVerticalVesicaSegment(pos - vec3f(0.0, -0.13, 0.0), 0.4, 0.20);
    let cutoff_height = 0.1;
    d_bud = max(d_bud, pos.y - cutoff_height);

    let rose_data = sdRose(pos + vec3f(0.0, -0.03, 0.0));
    let rose_dist = rose_data.x;

    let d_bulb_and_sepals = smin(d_sepals, d_bud, 0.02);
    let d_all_greenery = smin(d_stem.x, d_bulb_and_sepals, 0.02);
    let flower_final = min(rose_dist, d_all_greenery);

    var material = d_stem.y;

    if (d_bulb_and_sepals < d_stem.x) {
        material = MAT_LEAVES;
    }

    if (rose_dist < d_all_greenery) {
        material = rose_data.y;
    }

    return vec2f(flower_final, material);
}

// soft shadow + glow the fallen petals cast on the floor
fn getPetalFloorEffects(p: vec3f, time: f32) -> vec3f {
    let spacing = 2.0;
    let cell = floor(p.xz / spacing);
    let local_p = fract(p.xz / spacing) - 0.5;
    let sign_p = sign(local_p);

    var total_shadow = 0.0;
    var total_light = 0.0;
    var max_dissolve = 0.0;

    for (var i: f32 = 0.0; i <= 1.0; i += 1.0) {
        for (var j: f32 = 0.0; j <= 1.0; j += 1.0) {
            let neighbor_offset = vec2f(i, j) * sign_p;
            let current_cell = cell + neighbor_offset;

            let seed = hash12(current_cell);
            let seed2 = hash12(current_cell + vec2f(13.3, 41.5));

            let speed = 0.55 + seed * 0.25;
            let start_h = 7.0 + seed2 * 1.0;
            let cycle_duration = 19.0;

            let local_time = (time + seed * 20.0) % cycle_duration;
            let virtual_drop_y = start_h - (local_time * speed);
            let ground_y = -0.40;
            let ground_dist = virtual_drop_y - ground_y;

            if (ground_dist > -10.0 && ground_dist < 1.5) {
                var actual_y = virtual_drop_y;
                let landing_zone = 0.5;

                if (ground_dist < landing_zone && ground_dist > 0.0) {
                    let t = ground_dist / landing_zone;
                    actual_y = ground_y + landing_zone * (t * t);
                } else if (ground_dist <= 0.0) {
                    actual_y = ground_y;
                }

                var petal_xz = (current_cell + 0.5) * spacing;
                let wind_damp = smoothstep(-0.1, 0.5, ground_dist);
                petal_xz.x -= sin(time * 1.5 + seed * 10.0) * 0.25 * wind_damp;
                petal_xz.y -= cos(time * 1.2 + seed2 * 10.0) * 0.25 * wind_damp;

                let dist_to_petal_2d = length(p.xz - petal_xz);
                let height_above_floor = max(0.0, actual_y - p.y);

                let dissolve_progress = smoothstep(12.0, 19.0, local_time);
                let dissolve_fade = 1.0 - dissolve_progress;

                let shadow_radius = 0.12 + height_above_floor * 0.3;
                let shadow_softness = smoothstep(shadow_radius, 0.0, dist_to_petal_2d);
                let shadow_opacity = smoothstep(1.5, 0.0, height_above_floor) * 0.8;
                total_shadow += shadow_softness * shadow_opacity * dissolve_fade;

                let light_radius = PETAL_FLOOR_LIGHT_RADIUS;
                let light_softness = smoothstep(light_radius, 0.0, dist_to_petal_2d);
                let light_opacity = smoothstep(1.5, 0.0, height_above_floor);

                let current_light = light_softness * light_opacity * dissolve_fade;
                total_light += current_light;

                if (current_light > 0.0) {
                    max_dissolve = max(max_dissolve, dissolve_progress);
                }
            }
        }
    }

    return vec3f(clamp(total_shadow, 0.0, 1.0), clamp(total_light, 0.0, 1.0), max_dissolve);
}

// the whole scene as one signed-distance field
fn map(p_in: vec3f) -> vec2f {
    var p = p_in;

    let time = uniforms.time;

    let a = atan2(p.z, p.x);
    let r = length(p.xz);

    let hole_size = 0.5 + sin(time * 0.3) * 0.2;
    let dirt_radius = hole_size + sin(sin(time * 0.1) * a * 7.0 + time * 0.8) * 0.1 * hole_size + cos(a * 3.14 - time * 0.2) * 0.08 * hole_size;
    let hole_mask = smoothstep(dirt_radius, dirt_radius * 0.7, r);

    let hole_depth = 0.2;
    var ground_height = -0.5 - (hole_mask * hole_depth);

    var mat = MAT_GROUND;

    // When ENABLE_GROUND_BBOX_OPT is true, skip expensive brick/root heightmap noise when ray is high above the floor
    let evaluate_ground_detail = !ENABLE_GROUND_BBOX_OPT || (p.y < -0.35);
    let root_fade = getRootFade();

    if (ENABLE_TEXTURED_GROUND && evaluate_ground_detail) {
        // Add brick height, fading it out smoothly as it enters the center hole
        ground_height += getGroundHeight(p.xz) * (1.0 - hole_mask);

        // Add the continuous heightmap root network directly onto the ground height, fading in smoothly with quality
        if (root_fade > 0.001 && r < VINES_MAX_RADIUS) {
            let root_h = getRootHeight(p.xz, r, a, time, root_fade) * (1.0 - hole_mask * 0.5);
            ground_height += root_h;
            // Pack smooth root color blend into the fractional part of MAT_GROUND so roots fade in without hard edges
            let root_color_blend = clamp(smoothstep(0.0005, 0.005, root_h) * root_fade, 0.0, 0.99);
            mat = MAT_GROUND + root_color_blend;
        }
    }

    if (r < dirt_radius && evaluate_ground_detail) {
        mat = MAT_HOLE;

        let noise = sin(time + p.x * 10.0) * 0.03 + sin(time * 3.0 + p.z * 13.0) * 0.03 +
                    sin(2.5 * time + p.x * 15.0) * 0.05 + sin(2.0 * time + p.z * 18.0) * 0.01 +
                    sin(8.0 * time + 30.0 + p.x * 110.0) * 0.002 + sin(time + 35.0 + p.z * 115.0) * 0.002 +
                    sin(6.0 * time + 10.0 + p.x * 127.0) * 0.001 + sin(4.0 * time + 5.0 + p.z * 143.0) * 0.001;

        ground_height += noise * hole_mask;
    }

    var res = vec2f((p.y - ground_height) * 0.7, mat);

    let core_center = vec3f(0.0, -0.65, 0.0);
    let core_radius = hole_size * 0.55;

    var d_core = length(p - core_center) - core_radius;
    if (d_core < 0.25) {
        let core_noise = sin(p.x * 40.0 + time * 4.0) * sin(p.y * 40.0 - time * 2.0) * sin(p.z * 40.0 + time * 3.5) * 0.04;
        d_core = (d_core + core_noise) * 0.5;
    }

    if (d_core < res.x) {
        res = vec2f(d_core, MAT_HOLE);
    }

    if (ENABLE_HOLE_TENTACLES) {
        let tentacles = sdTentacles(p, time, hole_size, true);
        if (tentacles.x < res.x) {
            res = tentacles;
        }
    }

    // Upward tentacles connected to the root network: sprout smoothly upward as quality rises
    let crevice_fade = getCreviceTentacleFade();
    if (ENABLE_TEXTURED_GROUND && crevice_fade > 0.001 && r < VINES_MAX_RADIUS + 0.5) {
        let mini_tentacles = sdCreviceTentacles(p, time, res.x, crevice_fade);
        if (mini_tentacles.x < res.x) {
            res = mini_tentacles;
        }
    }

    if (ENABLE_FLOWER) {
        let flower_pos = vec3f(0.0, 2.0, 0.0);
        let d_t = flower(p, flower_pos);

        if (d_t.x < res.x) {
            res = vec2f(d_t.x, d_t.y);
        }
    }

    if (ENABLE_FALLING_PETALS) {
        let res_petals = sdFallingPetals(p, time, res.x);
        if (res_petals.x < res.x) {
            res = res_petals;
        }
    }

    return res;
}

// 4-sample Tetrahedral Normal (33% fewer map() calls than 6-sample central differences)
fn calc_normal(p: vec3f) -> vec3f {
    let e = vec2f(1.0, -1.0) * 0.57735027 * NORMAL_EPS;
    return normalize(
        e.xyy * map(p + e.xyy).x +
        e.yyx * map(p + e.yyx).x +
        e.yxy * map(p + e.yxy).x +
        e.xxx * map(p + e.xxx).x
    );
}

// stripped-down scene for shadow rays (middle hole tentacles without micro-thorns)
fn map_shadow(p: vec3f) -> f32 {
    if (!ENABLE_HOLE_TENTACLES) {
        return 100.0;
    }
    let time = uniforms.time;
    let d_tentacles = sdTentacles(p, time, 0.5 + sin(time * 0.3) * 0.2, false).x;
    return d_tentacles;
}

// penumbra shadows, marched against map_shadow and faded smoothly by quality
fn softshadow(ro: vec3f, rd: vec3f, mint: f32, tmax: f32, k: f32) -> f32 {
    let shadow_fade = getShadowFade();
    if (shadow_fade <= 0.001) {
        return 1.0;
    }
    var res = 1.0;
    var t = mint;
    var ph = 1e20;
    for (var i = 0; i < SHADOW_STEPS; i++) {
        let sample_p = ro + rd * t;
        // Once the shadow ray climbs above the middle tentacles (y > 1.65), it has clear sky to the light
        if (sample_p.y > 1.65) { break; }

        let h = map_shadow(sample_p);

        let y = h * h / (2.0 * ph);
        let d = sqrt(max(0.0, h * h - y * y));
        res = min(res, k * d / max(0.0, t - y));

        ph = h;
        t += h;

        if (res < 0.001 || t > tmax) { break; }
    }
    res = clamp(res, 0.0, 1.0);
    let raw_shadow = res * res * (3.0 - 2.0 * res);
    return mix(1.0, raw_shadow, shadow_fade);
}

@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let resolution = uniforms.resolution;
    let uv = (pos.xy * 2.0 - resolution) / resolution.y;
    let uv_flipped = vec2f(uv.x, -uv.y);

    let time = uniforms.time * 2.0;
    let wild = getWildEventFactor(uniforms.time);

    let yaw = uniforms.yaw;
    let pitch = CAM_PITCH + clamp(uniforms.pitch, -1.0, 1.0) * CAM_PITCH_GAIN;
    let ro = vec3f(
        CAM_RADIUS * cos(pitch) * sin(yaw),
        CAM_RADIUS * sin(pitch) + CAM_HEIGHT,
        CAM_RADIUS * cos(pitch) * cos(yaw)
    );

    let lookAt = vec3f(0.0, CAM_HEIGHT, 0.0);

    let fwd = normalize(lookAt - ro);
    let right = normalize(cross(vec3f(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    let rd = normalize(fwd + right * uv_flipped.x + up * uv_flipped.y);

    var t = 0.0;
    var hit = false;
    var mat_id = -1.0;

    let current_rose_color = mix(COLOR_RED, COLOR_WHITE, uniforms.color_t);
    let current_dissolve_color = mix(COLOR_WHITE, COLOR_RED, uniforms.color_t);

    // Boost red glow luminance whenever either color is red so both red halos and red dissolves pop
    let rose_red_boost = mix(GLOW_RED_MODE_BOOST, 1.0, uniforms.color_t);
    let dissolve_red_boost = mix(1.0, GLOW_RED_MODE_BOOST, uniforms.color_t);
    let glow_rose_color = current_rose_color * rose_red_boost * GLOW_GENERAL_STRENGTH;
    let glow_dissolve_color = current_dissolve_color * dissolve_red_boost * GLOW_GENERAL_STRENGTH;

    var accumulated_glow = vec3f(0.0, 0.0, 0.0);

    // Smoothly interpolate step budget between STEPS_LOW and STEPS_HIGH
    let quality_01 = clamp(uniforms.quality * 0.5, 0.0, 1.0);
    let max_steps = i32(mix(f32(STEPS_LOW), f32(STEPS_HIGH), quality_01));

    for (var i = 0; i < max_steps; i++) {
        let p = ro + rd * t;
        let res = map(p);
        let d = res.x;
        mat_id = res.y;

        if (ENABLE_VOLUMETRIC_GLOW) {
            let mat_base = floor(mat_id);
            let mat_frac = fract(mat_id);

            if (mat_base == MAT_ROSE) {
                // Flower head & bounding-sphere halo (boosted by GLOW_ROSE_HALO_STRENGTH)
                let is_halo_shell = select(1.0, GLOW_ROSE_HALO_STRENGTH, mat_frac < 0.001);
                accumulated_glow += glow_rose_color * is_halo_shell * (0.0008 / (0.01 + d * d * 10.0));
            } else if (mat_base == MAT_THORNS) {
                accumulated_glow += glow_rose_color * (0.0008 / (0.01 + d * d * 10.0));
            } else if (mat_base == MAT_FALLING_PETAL) {
                // Falling petals lose their volumetric glow as they turn black during the wild event
                accumulated_glow += glow_rose_color * (0.0008 / (0.01 + d * d * 10.0)) * (1.0 - wild);
            } else if (mat_base == MAT_TENTACLE) {
                let strand_color = mix(glow_rose_color, glow_dissolve_color, mat_frac);
                accumulated_glow += strand_color * (0.0008 / (0.01 + d * d * 20.0));
            } else if (mat_base == MAT_DISSOLVE) {
                accumulated_glow += glow_dissolve_color * (0.0008 / (0.01 + d * d * 5.0)) * mat_frac * (1.0 - wild);
            } else if (mat_base == MAT_LEAVES && mat_frac > 0.0) {
                accumulated_glow += glow_rose_color * (0.0008 / (0.01 + d * d * 14.0)) * mat_frac;
            }
        }

        if (d < SURF_EPS) { hit = true; break; }
        if (t > MAX_DIST) { break; }
        t = t + d * STEP_SCALE;
    }

    var final_color = vec3f(0.0, 0.0, 0.0);

    if (hit) {
        let p = ro + rd * t;
        let normal = calc_normal(p);
        let view_dir = normalize(ro - p);

        let light_pos = LIGHT_POS;
        let light_vec = light_pos - p;
        let light_dist = length(light_vec);
        let light_dir = light_vec / light_dist;

        let half_dir = normalize(light_dir + view_dir);

        let light_intensity = LIGHT_INTENSITY;
        let attenuation = light_intensity / (1.0 + 0.1 * light_dist + 0.15 * (light_dist * light_dist));

        let diff = clamp(dot(normal, light_dir), 0.1, 1.0);
        let shadow = softshadow(p + normal * 0.01, light_dir, 0.02, light_dist, 16.0);

        var albedo = vec3f(0.0);
        var roughness = 1.0;
        var spec_power = 0.0;
        var rim_light = 0.0;
        var emission = vec3f(0.0);

        let mat_base = floor(mat_id);
        let mat_frac = fract(mat_id);

        if (abs(mat_base - MAT_GROUND) < 0.1) {
            if (!ENABLE_TEXTURED_GROUND) {
                albedo = vec3f(0.2, 0.2, 0.2);
                roughness = 10.0;
                spec_power = 0.3;
            } else {
                // Fetch both distance and exact Voronoi cell ID from our unified function
                let brick_data = getBrickData(p.xz);
                let d = brick_data.x;
                let brick_id = brick_data.yz;

                // Fade out the discontinuous per-brick hash before reaching the Voronoi cell boundary
                // so the continuous rock/dirt/moss colors can bleed into the mortar with zero seams
                let cell_interior_mask = smoothstep(BRICK_MORTAR_WIDTH * 0.4, -0.005, d);
                let is_stone2 = smoothstep(0.3, 0.6, hash12(brick_id)) * cell_interior_mask;

                var block_albedo = mix(COLOR_ROCK, COLOR_STONE2, is_stone2);
                var block_roughness = MAT_PROP_ROCK.x;
                var block_spec = MAT_PROP_ROCK.y;
                var n_detail = 0.48;

                if (ENABLE_GROUND_FBM_MAT) {
                    // Macro FBM smoothly fades in its higher octaves via fbm()
                    let n = fbm(p.xz * NOISE_MACRO_SCALE);
                    let detail_fade = getMatDetailFade();
                    var n_detail_2 = 0.48;

                    // High-frequency detail FBM only runs once detail_fade > 0, and crossfades from neutral 0.48
                    if (detail_fade > 0.001) {
                        n_detail = mix(0.48, fbm(p.xz * NOISE_DETAIL_SCALE), detail_fade);
                        n_detail_2 = mix(0.48, fbm((p.xz + vec2f(53.5, 46.2)) * NOISE_DETAIL_SCALE), detail_fade);
                    }

                    let moss_mask = smoothstep(0.5, 1.0, n + n_detail * 0.2);
                    let dirt_mask = smoothstep(0.45, 0.8, n * 3.0 - n_detail_2 * 1.9);

                    if (dirt_mask > 0.0) {
                        block_albedo = mix(block_albedo, COLOR_DIRT, dirt_mask);
                        block_roughness = mix(block_roughness, MAT_PROP_DIRT.x, dirt_mask);
                        block_spec = mix(block_spec, MAT_PROP_DIRT.y, dirt_mask);
                    }

                    if (moss_mask > 0.0) {
                        block_albedo = mix(block_albedo, COLOR_MOSS * 0.7, moss_mask);
                        block_roughness = mix(block_roughness, MAT_PROP_MOSS.x, moss_mask); 
                        block_spec = mix(block_spec, MAT_PROP_MOSS.y, moss_mask);
                    }
                }

                // Crossfade mortar color: 0.0 (red rose) -> COLOR_MORTAR (white), 1.0 (white rose) -> COLOR_MORTAR_2 (red)
                let current_mortar_color = mix(COLOR_MORTAR, COLOR_MORTAR_2, uniforms.color_t);
                
                // Wide, soft blend so rock/dirt/moss discolors the edges of the mortar crevices seamlessly
                let mortar_mask = smoothstep(-MORTAR_BLEND_SOFTNESS, MORTAR_BLEND_SOFTNESS, d);

                albedo = mix(block_albedo, current_mortar_color, mortar_mask);
                roughness = mix(block_roughness, MAT_PROP_MORTAR.x, mortar_mask);
                spec_power = mix(block_spec, MAT_PROP_MORTAR.y, mortar_mask);

                // Crevice edge ambient occlusion / discoloration along the base of the brick bevel (d ~= 0.0)
                let edge_ao = smoothstep(-BRICK_BEVEL, 0.0, d) * smoothstep(CREVICE_AO_WIDTH, 0.0, d);
                albedo *= (1.0 - edge_ao * CREVICE_AO_STRENGTH);

                albedo *= (0.7 + 0.3 * n_detail); // Apply high-frequency noise variation

                // Subtle emissive glow inside the brick mortar crevices
                if (ENABLE_CREVICE_GLOW) {
                    let crevice_core = smoothstep(-0.005, BRICK_MORTAR_WIDTH * 0.45, d);
                    emission += current_mortar_color * crevice_core * CREVICE_GLOW_STRENGTH;
                }

                // Smoothly blend in the green surface roots (packed into mat_frac of MAT_GROUND)
                if (mat_frac > 0.001) {
                    let green_root_color = vec3f(0.071, 0.216, 0.118) * 0.2;
                    albedo = mix(albedo, green_root_color, mat_frac);
                    roughness = mix(roughness, 180.0, mat_frac);
                    spec_power = mix(spec_power, 1.2, mat_frac);
                    emission *= (1.0 - mat_frac);
                }
            }

            let petal_fx_fade = getPetalFxFade();
            if (petal_fx_fade > 0.001) {
                let floor_effects = getPetalFloorEffects(p, uniforms.time);
                let shadow_amt = floor_effects.x * petal_fx_fade;
                let light_amt = floor_effects.y * petal_fx_fade;
                let color_shift = floor_effects.z;

                albedo = albedo * (1.0 - shadow_amt);

                // Boost red point lights via PETAL_FLOOR_RED_BOOST so red floor glow stands out strongly
                let boosted_red_light = COLOR_RED * PETAL_FLOOR_RED_BOOST;
                let base_light = mix(boosted_red_light, COLOR_WHITE, uniforms.color_t);
                let dissolve_light = mix(COLOR_WHITE, boosted_red_light, uniforms.color_t);
                let final_glow_color = mix(base_light, dissolve_light, color_shift);

                // Boosted falling petal point lights on the ground via PETAL_FLOOR_LIGHT_INTENSITY
                emission += final_glow_color * light_amt * PETAL_FLOOR_LIGHT_INTENSITY * (1.0 - wild);
            }

        } else if (abs(mat_base - MAT_STEM) < 0.1) {
            albedo = vec3f(0.071, 0.216, 0.118) * 0.7;
            roughness = 180.0;
            spec_power = 1.2;

        } else if (abs(mat_base - MAT_ROSE) < 0.1) {
            let base_color = current_dissolve_color * 0.6;
            let tip_color = current_rose_color * 0.8;

            albedo = mix(base_color, tip_color, smoothstep(0.0, 0.55, mat_frac));

            roughness = 180.0;
            spec_power = 1.2;
            rim_light = pow(1.0 - max(dot(normal, view_dir), 0.0), 3.0) * 0.95;
            emission = albedo * 0.2;

        } else if (abs(mat_base - MAT_FALLING_PETAL) < 0.1) {
            let base_color = current_dissolve_color * 0.6;
            let tip_color = current_rose_color * 0.8;
            let normal_albedo = mix(base_color, tip_color, smoothstep(0.0, 0.55, mat_frac));

            // Drain the falling petals to black during the wild event, then restore original color
            albedo = mix(normal_albedo, vec3f(0.005, 0.005, 0.005), wild);
            roughness = 180.0;
            spec_power = mix(1.2, 0.25, wild);
            rim_light = pow(1.0 - max(dot(normal, view_dir), 0.0), 3.0) * 0.95 * (1.0 - wild);
            emission = normal_albedo * 0.2 * (1.0 - wild);

        } else if (abs(mat_base - MAT_HOLE) < 0.1) {
            albedo = vec3f(0.0, 0.0, 0.0);
            roughness = 35.0;
            spec_power = 1.2;

        } else if (abs(mat_base - MAT_DISSOLVE) < 0.1) {
            let glow_intensity = mat_frac;
            let tip_color = current_rose_color * 0.8;
            let glow_color = current_dissolve_color * dissolve_red_boost * 1.5;

            let normal_albedo = mix(tip_color, glow_color, glow_intensity);
            albedo = mix(normal_albedo, vec3f(0.005, 0.005, 0.005), wild);

            roughness = 6.0;
            spec_power = 0.1;
            emission = glow_color * glow_intensity * 2.5 * (1.0 - wild);

        } else if (abs(mat_base - MAT_THORNS) < 0.1) {
            albedo = current_rose_color;
            roughness = 60.0;
            spec_power = 0.5;

        } else if (abs(mat_base - MAT_LEAVES) < 0.1) {
            let green_leaf = vec3f(0.071, 0.216, 0.118) * 0.2;
            albedo = mix(green_leaf, current_rose_color, mat_frac * 0.85);
            roughness = 180.0;
            spec_power = 1.2;
            emission = current_rose_color * mat_frac * 1.8;

        } else if (abs(mat_base - MAT_TENTACLE) < 0.1) {
            let strand_color = mix(current_rose_color, current_dissolve_color, mat_frac);

            albedo = strand_color * 0.8;
            roughness = 180.0;
            spec_power = 1.2;
            rim_light = pow(1.0 - max(dot(normal, view_dir), 0.0), 3.0) * 0.95;
            emission = albedo * 0.2;
        }

        let ambient = vec3f(0.45) * albedo;
        let diffuse_color = albedo * diff * vec3f(1.0, 0.95, 0.8);
        let diffuse = diffuse_color * attenuation * shadow;
        let spec_angle = max(dot(normal, half_dir), 0.0);
        let specular = pow(spec_angle, roughness) * spec_power * attenuation;

        final_color = ambient + diffuse + (vec3f(1.0, 0.9, 0.8) * specular) + (albedo * rim_light * attenuation) + emission;
    }

    if (hit) {
        let hit_mat = floor(mat_id);

        if (hit_mat == MAT_ROSE || hit_mat == MAT_FALLING_PETAL || hit_mat == MAT_DISSOLVE || hit_mat == MAT_TENTACLE) {
            accumulated_glow *= 0.1;
        }
    }
 
    let fog_density = FOG_DENSITY;
    let fog_factor = 1.0 - exp(-fog_density * t * t);
    final_color = mix(final_color, vec3f(0.0, 0.0, 0.0), clamp(fog_factor, 0.0, 1.0));

    let glow_fog_density = GLOW_FOG_DENSITY;
    let glow_fog = exp(-glow_fog_density * t * t);

    final_color += accumulated_glow * glow_fog;

    if (hit) {
        let p = ro + rd * t;
        let mist_thickness = smoothstep(0.7, -0.5, p.y);
        let mist_intensity = mist_thickness * 0.6 * (1.0 - fog_factor);
        let mist_color = current_dissolve_color;
        final_color = mix(final_color, mist_color, mist_intensity);
    }

    let noise = hash12(pos.xy + uniforms.time);
    final_color += (noise - 0.5) * GRAIN_STRENGTH;

    return vec4f(final_color, 1.0);
}