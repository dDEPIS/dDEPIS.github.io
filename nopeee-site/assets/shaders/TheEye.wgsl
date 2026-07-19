// Mirrors the 32-byte buffer written from JS.[cite: 2]
struct Uniforms {
  resolution: vec2f,
  time: f32,
  color_t: f32,
  yaw: f32,
  pitch: f32,
  quality: f32,
  _pad: f32,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

const CAM_RADIUS     = 3.0;   
const CAM_HEIGHT     = 0.0;   
const CAM_PITCH      = 0.0;   
const CAM_PITCH_GAIN = 0.1;   

const STEP_SCALE = 0.5;
const SURF_EPS   = 0.002;   
const MAX_DIST   = 25.0;    
const NORMAL_EPS = 0.002;   

const STEPS_LOW    : i32 = 150;
const STEPS_MEDIUM : i32 = 200;
const STEPS_HIGH   : i32 = 250;

const GRAIN_STRENGTH = 15.0 / 255.0;

// Material IDs
const MAT_FABRIC = 0.0;
const MAT_SCLERA = 1.0;
const MAT_IRIS   = 2.0;

@vertex
fn vs_main(@builtin(vertex_index) in_vertex_index: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f(3.0, -1.0),
    vec2f(-1.0, 3.0)
  );
  return vec4f(pos[in_vertex_index], 0.0, 1.0);
}

// Reuse rotation utilities
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

// Pseudo-random hash for eye darting
fn hash1(n: f32) -> f32 { 
    return fract(sin(n) * 43758.5453123); 
}

// Generates sharp, snappy rotations for the eye
fn get_creepy_look(time: f32) -> vec2f {
    let speed = 3.5;
    let t = time * speed;
    let step_val = floor(t);
    let frac_val = fract(t);
    
    // The tight smoothstep creates the sudden "snapping" motion
    let ease = smoothstep(0.0, 0.15, frac_val); 
    
    let pitch1 = (hash1(step_val) - 0.5) * 1.5;
    let yaw1   = (hash1(step_val + 10.0) - 0.5) * 2.0;
    
    let pitch2 = (hash1(step_val + 1.0) - 0.5) * 1.5;
    let yaw2   = (hash1(step_val + 11.0) - 0.5) * 2.0;
    
    return vec2f(mix(pitch1, pitch2, ease), mix(yaw1, yaw2, ease));
}

fn map(p_in: vec3f) -> vec2f {
    let time = uniforms.time;
    var res = vec2f(100.0, -1.0);

    // 1. The Fabric of the Universe (Gravity Well)
    // A distorted cylindrical space that expands outward
    let space_warp = sin(p_in.z * 1.5 - time * 2.0) * 0.2 + cos(p_in.x * 2.0 + time) * 0.1;
    let d_fabric = -(length(p_in.xy) - (2.5 + p_in.z * p_in.z * 0.05 + space_warp));
    res = vec2f(d_fabric, MAT_FABRIC);

    // 2. The Creepy Eye
    var p_eye = p_in;
    let look_angles = get_creepy_look(time);
    p_eye = opRotateY(p_eye, look_angles.y);
    p_eye = opRotateX(p_eye, look_angles.x);

    let d_sclera = length(p_eye) - 1.0;
    
    // Carve out a crater for the pupil to make it look unnatural and deep
    let d_pupil_cut = length(p_eye - vec3f(0.0, 0.0, -0.85)) - 0.45;
    let d_eye_final = max(d_sclera, -d_pupil_cut);

    if (d_eye_final < res.x) {
        // Check if we are inside the pupil crater
        let is_iris = step(d_pupil_cut, 0.05);
        res = vec2f(d_eye_final, mix(MAT_SCLERA, MAT_IRIS, is_iris));
    }

    return res;
}

fn calc_normal(p: vec3f) -> vec3f {
    let e = NORMAL_EPS;
    let dx = map(p + vec3f(e, 0.0, 0.0)).x - map(p - vec3f(e, 0.0, 0.0)).x;
    let dy = map(p + vec3f(0.0, e, 0.0)).x - map(p - vec3f(0.0, e, 0.0)).x;
    let dz = map(p + vec3f(0.0, 0.0, e)).x - map(p - vec3f(0.0, 0.0, e)).x;
    return normalize(vec3f(dx, dy, dz));
}

@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let resolution = uniforms.resolution;
    let uv = (pos.xy * 2.0 - resolution) / resolution.y;
    let uv_flipped = vec2f(uv.x, -uv.y);
    let time = uniforms.time;
    
    // 1. Locked the camera to sit perfectly still on the negative Z-axis, 
    // staring directly at the origin where the eye rests.
    let ro = vec3f(0.0, CAM_HEIGHT, -CAM_RADIUS);
    let lookAt = vec3f(0.0, CAM_HEIGHT, 0.0);
    
    let fwd = normalize(lookAt - ro);
    let right = normalize(cross(vec3f(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    let rd = normalize(fwd + right * uv_flipped.x + up * uv_flipped.y);

    var t = 0.0;
    var hit = false;
    var mat_id = -1.0;
    
    var accumulated_glow = vec3f(0.0);
    
    // Strict typing for the loop to satisfy WebGPU
    var max_steps: i32 = STEPS_HIGH;

    for (var i: i32 = 0; i < max_steps; i++) {
        let p = ro + rd * t;
        let res = map(p);
        let d = res.x;
        mat_id = res.y;

        // 2. Black Hole Accretion Disk Glow
        // Shifted the math to the XY plane so it forms a ring facing the camera
        let disk_dist = length(vec2f(length(p.xy) - 1.5, p.z + sin(p.x * 2.0 + time) * 0.1));
        let glow_color = vec3f(1.0, 0.4, 0.05); // Fiery orange/gold
        accumulated_glow += glow_color * (0.003 / (0.01 + disk_dist * disk_dist * 8.0));

        if (d < SURF_EPS) { hit = true; break; }
        if (t > MAX_DIST) { break; }
        t = t + d * STEP_SCALE;
    }

    var final_color = vec3f(0.0);

    if (hit) {
        let p = ro + rd * t;
        let normal = calc_normal(p);
        let view_dir = normalize(ro - p);
        
        let mat_base = floor(mat_id);
        
        var albedo = vec3f(0.0);
        var emission = vec3f(0.0);

        if (abs(mat_base - MAT_FABRIC) < 0.1) {
            // Dark, rippling cosmic space
            albedo = vec3f(0.02, 0.01, 0.05);
        } else if (abs(mat_base - MAT_SCLERA) < 0.1) {
            // Sickly, dark sclera
            albedo = vec3f(0.6, 0.5, 0.5);
            let rim = pow(1.0 - max(dot(normal, view_dir), 0.0), 3.0);
            emission = vec3f(0.1, 0.0, 0.0) * rim;
        } else if (abs(mat_base - MAT_IRIS) < 0.1) {
            // The black hole pupil / deep void
            albedo = vec3f(0.0);
            emission = vec3f(0.0); // Pure darkness inside the pupil
        }

        // Basic lighting
        let light_dir = normalize(vec3f(1.0, 2.0, -1.0));
        let diff = max(dot(normal, light_dir), 0.0);
        final_color = albedo * (diff * 0.8 + 0.2) + emission;
    }

    // Add the black hole glow over the scene
    final_color += accumulated_glow;

    // Fog to hide the edges of the universe fabric
    let fog_factor = 1.0 - exp(-0.02 * t * t);
    final_color = mix(final_color, vec3f(0.0), clamp(fog_factor, 0.0, 1.0));

    // Film grain 
    let hash_noise = fract(sin(dot(pos.xy + uniforms.time, vec2f(12.9898, 78.233))) * 43758.5453);
    let grain = (hash_noise - 0.5) * GRAIN_STRENGTH;
    
    // Strict vector addition for WebGPU
    final_color += vec3f(grain, grain, grain);

    return vec4f(final_color, 1.0);
}