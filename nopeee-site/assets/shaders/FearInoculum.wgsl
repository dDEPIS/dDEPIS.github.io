// Mirrors the 32-byte buffer written from JS. 
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
// Raymarch settings
// ---------------------------------------------------------------------------
//const CAM_POS        = vec3f(-0.3, 0.15, -0.68);
const CAM_LOOK_AT    = vec3f(-0.35, -0.2, 0.0);
//const CAM_FOV_ZOOM   = 1.7;

const STEP_SCALE = 0.2;      
const SURF_EPS   = 0.0002;
const MAX_DIST   = 50.0;
const NORMAL_EPS = 0.005;

const STEPS_LOW    : i32 = 750;
const STEPS_MEDIUM : i32 = 750;
const STEPS_HIGH   : i32 = 750; 

// ---------------------------------------------------------------------------
// Post-Processing & Global Motion
// ---------------------------------------------------------------------------
const ENABLE_CHROMATIC_ABERRATION = true;
const CA_STRENGTH = 0.008;   
const CA_SPREAD_R = -1.0;
const CA_SPREAD_G =  0.0;    
const CA_SPREAD_B =  1.5;    
const CA_INTENSITY_R = 1.0;
const CA_INTENSITY_G = 1.0;
const CA_INTENSITY_B = 1.2;  

const PATTERN_SPEED = 0.3;
const SPIRAL_DIR = -1.0;     
const COIL_PITCH = 1.6;      
const COIL_RADIUS = 1.0;     
const TUBE_THICKNESS = 0.6;  

// ---------------------------------------------------------------------------
// MACROS: Eye & Domain (Now in True Physical World Units)
// ---------------------------------------------------------------------------
const EYE_TRACKING   = 0.0; 
const EYE_LOOK_PITCH = -0.15; // Controls how high the eyes are looking (positive/negative for up/down)

const EYE_COLS      = 44.0;  
const EYE_ROWS      = 24.0;  

const EYE_DENSITY   = 1.05;   
const EYE_SPACING   = 0.95;  

const EYE_RADIUS    = 0.045;  
const EYE_HEIGHT    = 0.03;  

const SPIRAL_BRIGHTNESS = 0.85;  

// ---------------------------------------------------------------------------
// MACROS: Upper Disk (Top Lid)
// ---------------------------------------------------------------------------
const UP_DISK_RADIUS     = 0.085; 
const UP_DISK_THICKNESS  = 0.0001; 
const UP_DISK_POS_Y      = 0.04;   
const UP_DISK_POS_Z      = -0.02;  
const UP_DISK_SCALE_Z    = 0.3;    
const UP_DISK_FOLD_AMT   = -6.5;  
const UP_DISK_TILT       = -0.5;    // Rotates the disk over the eye (Radians)

// ---------------------------------------------------------------------------
// MACROS: Lower Disk (Bottom Lid)
// ---------------------------------------------------------------------------
const DN_DISK_RADIUS     = 0.085; 
const DN_DISK_THICKNESS  = 0.0001; 
const DN_DISK_POS_Y      = -0.044;  
const DN_DISK_POS_Z      = -0.014;  
const DN_DISK_SCALE_Z    = 0.4;    
const DN_DISK_FOLD_AMT   = 10.0;   // Flipped to 10.0 to perfectly mirror the top lid's curve!
const DN_DISK_TILT       = 0.5;    // Rotates the disk over the eye (Radians)

// ---------------------------------------------------------------------------
// Lighting & Palette
// ---------------------------------------------------------------------------
const LIGHT_POS   = vec3f(0.0, -1.2, 0.1);
const LIGHT_COLOR = vec3f(0.7, 0.7, 0.9); 
const LIGHT_POWER = 10.7; 
const AMBIENT_COLOR = vec3f(0.4, 0.4, 0.7); 

const COLOR_DISK       = vec3f(0.9, 0.9, 0.95);
const COLOR_SCLERA     = vec3f(0.8, 0.8, 0.8); 
const COLOR_IRIS_EDGE  = vec3f(0.02, 0.02, 0.02); 
const COLOR_IRIS_INNER = vec3f(0.95, 0.95, 1.0);  
const COLOR_PUPIL      = vec3f(0.0, 0.0, 0.0);    

const BAND_1_START = 0.30; 
const BAND_2_START = 0.4; 
const BAND_3_START = 0.55; 
const BAND_BLEND   = 0.40; 

@vertex
fn vs_main(@builtin(vertex_index) in_vertex_index: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f(3.0, -1.0),
    vec2f(-1.0, 3.0)
  );
  return vec4f(pos[in_vertex_index], 0.0, 1.0);
}

// ---------------------------------------------------------------------------
// SDF Core
// ---------------------------------------------------------------------------

// SDF for a solid disk (cylinder) aligned along the Y-axis
fn sd_disk_y(p: vec3f, radius: f32, thickness: f32, scale_z: f32, fold_amt: f32) -> f32 {
    var q = p;
    
    // 1. Parabolic fold along the X-axis (folds the sides inward/outward)
    q.y -= fold_amt * (q.x * q.x);
    
    // 2. Scale the Z-axis (squash/stretch)
    q.z /= scale_z;
    
    let d = vec2f(length(q.xz) - radius, abs(q.y) - thickness);
    let dist = min(max(d.x, d.y), 0.0) + length(max(d, vec2f(0.0)));
    
    // Distance correction for scaling
    return dist * min(1.0, scale_z);
}

// Returns vec4f(distance, iris_mask, is_eye_mask, is_disk_mask)
fn map(p_in: vec3f) -> vec4f {
    var p = p_in;
    
    let a = atan2(p.z, p.x); 
    let pitch_scaled = COIL_PITCH / 6.2831853;
    var p_y_local = p.y + (a * pitch_scaled * SPIRAL_DIR);
    let cell = round(p_y_local / COIL_PITCH);
    p_y_local = p_y_local - cell * COIL_PITCH;
    
    let r_xz = length(p.xz);
    let dist_to_tube_core = length(vec2f(r_xz - COIL_RADIUS, p_y_local));
    let unwrapped_angle = (p.y - p_y_local) / (pitch_scaled * SPIRAL_DIR);
    var u = (unwrapped_angle / 6.2831853) * EYE_COLS;
    
    u -= uniforms.time * PATTERN_SPEED;
    let angle_minor = atan2(p_y_local, r_xz - COIL_RADIUS);
    
    let v_repeat = EYE_ROWS * 2.0; 
    let v = (angle_minor / 6.2831853 + 0.5) * v_repeat;
    
    var uv = vec2f(u, v);
    
    uv *= EYE_DENSITY; 
    
    let c = 0.7071067; 
    let s = 0.7071067; 
    var uv_rot = vec2f(uv.x * c - uv.y * s, uv.x * s + uv.y * c);
    
    // --- STAGGER EXACTLY ON THE CELL BOUNDARIES ---
    let row_id = floor(uv_rot.y);
    let is_odd_row = step(0.5, fract(row_id * 0.5));
    uv_rot.x += is_odd_row * 0.5;
    // ----------------------------------------------
    
    var p_domain = fract(uv_rot) - 0.5;
    
    p_domain /= EYE_DENSITY; 
    p_domain *= (1.0 / EYE_SPACING); 
    
    // --- ASPECT RATIO CORRECTION ---
    // Compute true physical world lengths for the grid cells
    let path_len = length(vec2f(6.2831853 * COIL_RADIUS, COIL_PITCH));
    let tube_circ = 6.2831853 * TUBE_THICKNESS;
    let phys_cell_u = path_len / EYE_COLS;
    let phys_cell_v = tube_circ / (EYE_ROWS * 2.0);

    // 1. EXTRACT 3D LOCAL SPACE
    let p_unrot = vec2f(p_domain.x * c + p_domain.y * s, -p_domain.x * s + p_domain.y * c);
    
    // Convert unrotated grid axes into true physical units
    let p_local_xy = vec2f(p_unrot.x * phys_cell_u, p_unrot.y * phys_cell_v);
    let local_z = dist_to_tube_core - TUBE_THICKNESS; 
    
    // X, Y, and Z are now completely equal in scale!
    let p_local = vec3f(p_local_xy, local_z);
    
    // 2. COMPOSE 3D GEOMETRY
    var d_final = local_z; 
    var is_eye = 0.0;
    var is_disk = 0.0;
    
    // Eyeball
    var p_ball = p_local;
    let height_ratio = EYE_HEIGHT / EYE_RADIUS;
    p_ball.z /= height_ratio; 
    
    let d_ball = (length(p_ball) - EYE_RADIUS) * min(1.0, height_ratio);
    
    if (d_ball < d_final) {
        d_final = d_ball;
        is_eye = 1.0;
    }
    
    // ---------------------------------------------------
    // Upper Disk (Top Lid)
    // ---------------------------------------------------
    var p_up = p_local;
    
    let cu = cos(UP_DISK_TILT);
    let su = sin(UP_DISK_TILT);
    let up_y_rot = p_up.y * cu - p_up.z * su;
    let up_z_rot = p_up.y * su + p_up.z * cu;
    p_up.y = up_y_rot;
    p_up.z = up_z_rot;
    
    p_up.y -= UP_DISK_POS_Y;
    p_up.z -= UP_DISK_POS_Z;
    
    let d_up = sd_disk_y(p_up, UP_DISK_RADIUS, UP_DISK_THICKNESS, UP_DISK_SCALE_Z, UP_DISK_FOLD_AMT);
    
    if (d_up < d_final) {
        d_final = d_up;
        is_eye = 0.0;
        is_disk = 1.0;
    }

    // ---------------------------------------------------
    // Lower Disk (Bottom Lid)
    // ---------------------------------------------------
    var p_dn = p_local;
    
    let cd = cos(DN_DISK_TILT);
    let sd = sin(DN_DISK_TILT);
    let dn_y_rot = p_dn.y * cd - p_dn.z * sd;
    let dn_z_rot = p_dn.y * sd + p_dn.z * cd;
    p_dn.y = dn_y_rot;
    p_dn.z = dn_z_rot;
    
    p_dn.y -= DN_DISK_POS_Y;
    p_dn.z -= DN_DISK_POS_Z;
    
    let d_dn = sd_disk_y(p_dn, DN_DISK_RADIUS, DN_DISK_THICKNESS, DN_DISK_SCALE_Z, DN_DISK_FOLD_AMT);
    
    if (d_dn < d_final) {
        d_final = d_dn;
        is_eye = 0.0;
        is_disk = 1.0;
    }

    // 3. COLOR MAPPING
    let mouse_raw = vec2f(uniforms.yaw, uniforms.pitch) * EYE_TRACKING + vec2f(EYE_LOOK_PITCH, 0.0);
    let offset_rot = vec2f(mouse_raw.x * c + mouse_raw.y * s, -mouse_raw.x * s + mouse_raw.y * c);
    
    var p_col = fract(uv_rot + offset_rot) - 0.5;
    
    p_col /= EYE_DENSITY;
    p_col *= (1.0 / EYE_SPACING);
    
    let p_col_unrot = vec2f(p_col.x * c + p_col.y * s, -p_col.x * s + p_col.y * c);
    
    let p_col_eye = vec2f(p_col_unrot.x * phys_cell_u, p_col_unrot.y * phys_cell_v);
    
    let d_col = length(p_col_eye) / (EYE_RADIUS * 0.8);
    let iris_mask = clamp(1.0 - d_col, 0.0, 1.0);
    
    return vec4f(d_final * STEP_SCALE, iris_mask, is_eye, is_disk);
}

fn calc_normal(p: vec3f) -> vec3f {
    let e = NORMAL_EPS;
    let dx = map(p + vec3f(e, 0.0, 0.0)).x - map(p - vec3f(e, 0.0, 0.0)).x;
    let dy = map(p + vec3f(0.0, e, 0.0)).x - map(p - vec3f(0.0, e, 0.0)).x;
    let dz = map(p + vec3f(0.0, 0.0, e)).x - map(p - vec3f(0.0, 0.0, e)).x;
    return normalize(vec3f(dx, dy, dz));
}

// Fine-tuned Ambient Occlusion tailored for eye-cavity and lid crevice scale
fn calc_ao(pos: vec3f, nor: vec3f) -> f32 {
    var occ = 0.0;
    var sca = 1.0;
    for (var i = 0; i < 5; i++) {
        let h = 0.003 + 0.028 * f32(i) / 4.0;
        let d = map(pos + h * nor).x / STEP_SCALE;
        occ += (h - d) * sca;
        sca *= 0.72;
    }
    return clamp(1.0 - 4.5 * occ, 0.0, 1.0);
}

fn render_pixel(uv: vec2f, fragCoord: vec2f) -> vec3f {
    let uv_flipped = vec2f(uv.x, -uv.y);

    // --- RESPONSIVE CAMERA LOGIC ---
    let aspect = uniforms.resolution.x / uniforms.resolution.y;
    
    // Creates a blend factor: 0.0 for wide screens (desktop), 1.0 for tall screens (mobile)
    let portrait_t = smoothstep(1.3, 0.6, aspect);
    
    // Blend between Desktop Camera and Mobile Camera positions
    let desktop_ro = vec3f(-0.3, 0.15, -0.68);
    let mobile_ro  = vec3f(-0.3, 0.47, -0.75); // Pulled further back and slightly up
    let ro = mix(desktop_ro, mobile_ro, portrait_t);
    
    // Blend between Desktop FOV (1.7) and Mobile FOV (0.9 = wider)
    let fov_zoom = mix(1.7, 0.9, portrait_t);
    // -------------------------------

    let fwd = normalize(CAM_LOOK_AT - ro);
    let right = normalize(cross(vec3f(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    let rd = normalize(fwd * fov_zoom + right * uv_flipped.x + up * uv_flipped.y);

    var t = 0.0;
    var hit = false;
    var res = vec4f(0.0);

    var max_steps = STEPS_HIGH;
    if (uniforms.quality < 0.5) {
        max_steps = STEPS_LOW;
    } else if (uniforms.quality < 1.5) {
        max_steps = STEPS_MEDIUM;
    }

    for (var i = 0; i < max_steps; i++) {
        let p = ro + rd * t;
        let res_in = map(p);
        let d = res_in.x;

        if (d < SURF_EPS) { 
            hit = true; 
            res = res_in;
            break; 
        }
        if (t > MAX_DIST) { break; }
        t += d;
    }

    var final_color = vec3f(0.0);

    if (hit) {
        let p = ro + rd * t;
        let normal = calc_normal(p);
        let view_dir = normalize(ro - p);

        let light_vec = LIGHT_POS - p;
        let light_dist = length(light_vec);
        let light_dir = light_vec / max(light_dist, 0.001);
        let half_dir = normalize(light_dir + view_dir);

        let iris_mask = res.y; 
        let is_eye    = res.z;
        let is_disk   = res.w;
        
        var eye_albedo = COLOR_SCLERA;
        let edge_mix = smoothstep(BAND_1_START, BAND_1_START + BAND_BLEND, iris_mask);
        eye_albedo = mix(eye_albedo, COLOR_IRIS_EDGE, edge_mix);
        let inner_mix = smoothstep(BAND_2_START, BAND_2_START + BAND_BLEND, iris_mask);
        eye_albedo = mix(eye_albedo, COLOR_IRIS_INNER, inner_mix);
        let pupil_mix = smoothstep(BAND_3_START, BAND_3_START + BAND_BLEND, iris_mask);
        eye_albedo = mix(eye_albedo, COLOR_PUPIL, pupil_mix);

        var albedo = vec3f(SPIRAL_BRIGHTNESS);
        albedo = mix(albedo, eye_albedo, is_eye);
        albedo = mix(albedo, COLOR_DISK, is_disk);

        // Material shininess (Rough spiral vs Ultra-sharp pinpoint specular for the eye)
        var shininess = 16.0; 
        shininess = mix(shininess, 800.0, is_eye); 
        shininess = mix(shininess, 28.0, is_disk); 
        
        // Specular intensity
        var spec_power = 0.15;
        spec_power = mix(spec_power, 8.0, is_eye);
        spec_power = mix(spec_power, 0.18, is_disk);

        let attenuation = LIGHT_POWER / (1.0 + 0.5 * light_dist + 3.9 * (light_dist * light_dist));
        let diff = clamp(dot(normal, light_dir), 0.0, 1.0);
        
        // Pure Blinn-Phong specular highlight
        let spec_angle = max(dot(normal, half_dir), 0.0);
        let specular = pow(spec_angle, shininess) * spec_power;

        // Contact Ambient Occlusion
        let ao = calc_ao(p, normal)*0.7;

        let ambient_contrib = 0.2 * albedo * AMBIENT_COLOR * ao;
        let diffuse_contrib = albedo * diff * LIGHT_COLOR * attenuation * ao;
        let specular_contrib = LIGHT_COLOR * specular * attenuation;

        final_color = ambient_contrib+diffuse_contrib+ specular_contrib;
    }
    return final_color;
}

@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let resolution = uniforms.resolution;
    let uv = (pos.xy * 2.0 - resolution) / resolution.y;

    if (ENABLE_CHROMATIC_ABERRATION) {
        let ca_base_offset = uv * CA_STRENGTH;
        let col_r = render_pixel(uv + ca_base_offset * CA_SPREAD_R, pos.xy).r * CA_INTENSITY_R;
        let col_g = render_pixel(uv + ca_base_offset * CA_SPREAD_G, pos.xy).g * CA_INTENSITY_G;
        let col_b = render_pixel(uv + ca_base_offset * CA_SPREAD_B, pos.xy).b * CA_INTENSITY_B;
        return vec4f(col_r, col_g, col_b, 1.0);
    } else {
        return vec4f(render_pixel(uv, pos.xy), 1.0);
    }
}