struct Uniforms {
  resolution: vec2f,
  time: f32,
  color_t: f32, // Replaces padding: 0.0 = Red, 1.0 = White
  yaw: f32, 
  pitch: f32,
  padding2: vec2f // Keeps the buffer aligned to 32 bytes
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

// Constants for materials
const MAT_GROUND = 0.0;
const MAT_STEM = 1.0;
const MAT_ROSE = 2.0;
const MAT_DIRT = 3.0;
const MAT_DISSOLVE = 4.0;
const MAT_THORNS = 5.0;
const MAT_LEAVES = 6.0;
const MAT_TENTACLE = 7.0;

// Define our two extreme colors
const COLOR_RED = vec3f(0.15, 0.02, 0.05);
const COLOR_WHITE = vec3f(0.8, 0.75, 0.7)*0.5;


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
fn bayer4x4(p: vec2f) -> f32 {
    let x = u32(p.x) % 4;
    let y = u32(p.y) % 4;
    let index = x + y * 4;
    
    
    var m = array<f32, 16>(
         0.0, 12.0,  3.0, 15.0,
         8.0,  4.0, 11.0,  7.0,
         2.0, 14.0,  1.0, 13.0,
        10.0,  6.0,  9.0,  5.0
    );
    
  
    return m[index] * 0.0625; 
}

// --- SDF Primitive Helpers ---
fn opRotateY(p: vec3f, angle: f32) -> vec3f {
    let c = cos(angle);
    let s = sin(angle);
    return vec3f(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}

// Rotates around the X axis (Pitch - tilting forward/back)
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

fn sdSphere(p: vec3f, s: f32) -> f32 {
  return length(p) - s;
}

fn sdCappedCylinder(p: vec3f, h: f32, r: f32) -> f32 {
  let d = abs(vec2f(length(p.xz),p.y)) - vec2f(r,h);
  // FIXED: max(d, vec2f(0.0)) instead of max(d, 0.0)
  return min(max(d.x,d.y),0.0) + length(max(d, vec2f(0.0)));
}

fn sdEllipsoid(p: vec3f, r: vec3f) -> f32 {
    let k0 = length(p/r);
    let k1 = length(p/(r*r));
    return k0*(k0-1.0)/k1;
}

// --- SDF Combination Helpers ---

fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}



fn sdVerticalVesicaSegment(p: vec3f, h_in: f32, w_in: f32) -> f32 {
    // 1. Create mutable local copies of the inputs
    var h = h_in * 0.5;
    var w = w_in * 0.5;

    // 2. Shape constants
    let d = 0.5 * (h * h - w * w) / w;
    
    // 3. Project to 2D
    let q = vec2f(length(p.xz), abs(p.y - h));
    
    // 4. Feature selection
    // GLSL: (condition) ? true : false
    // WGSL: select(false, true, condition) <-- IMPORTANT!
    let condition = (h * q.x < d * (q.y - h));
    
    let t = select(
        vec3f(-d, 0.0, d + w), // The "False" case
        vec3f(0.0, h, 0.0),    // The "True" case
        condition
    );
    
    // 5. Distance
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

    // Calculate the 3 Barycentric/projection conditions
    let cond_val = sign(dot(cross(ba, nor), pa)) +
                   sign(dot(cross(cb, nor), pb)) +
                   sign(dot(cross(ac, nor), pc));

    // EDGE DISTANCE MATH
    // Calculates distance to the 3 distinct line segments
    let d_edge_a = dot2(ba * clamp(dot(ba, pa) / dot2(ba), 0.0, 1.0) - pa);
    let d_edge_b = dot2(cb * clamp(dot(cb, pb) / dot2(cb), 0.0, 1.0) - pb);
    let d_edge_c = dot2(ac * clamp(dot(ac, pc) / dot2(ac), 0.0, 1.0) - pc);
    
    let dist_edge = min(min(d_edge_a, d_edge_b), d_edge_c);

    // FACE DISTANCE MATH
    // Calculates distance to the plane
    let dist_face = dot(nor, pa) * dot(nor, pa) / dot2(nor);

    // SELECT
    // If cond_val < 2.0, we are "outside" the projection, use edge distance.
    // Otherwise, use face distance.
    let result_sq = select(
        dist_face,   // False case (cond >= 2.0) -> Face
        dist_edge,   // True case  (cond < 2.0)  -> Edge
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
fn sdVesica(p: vec2f, r: f32, d: f32) -> f32 {
    let p_abs = abs(p);
    let b = sqrt(r * r - d * d);
    
    let condition = (p_abs.y - b) * d > p_abs.x * b;
    
    let d1 = length(p_abs - vec2f(0.0, b));
    let d2 = length(p_abs - vec2f(-d, 0.0)) - r;
    
    return select(d2, d1, condition);
}
fn smax(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
    return mix(a, b, h) + k * h * (1.0 - h);
}

fn sdTentacles(p: vec3f, time: f32, hole_radius: f32) -> vec2f {
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
    
    // --- THE 0.5s ADVANCED COLOR MATH ---
    let cycle_angle = time * 0.4 + sector * 3.7;
    
    // Lowered from 0.2 down to 0.05. It now looks only a fraction of a second into the future!
    let advanced_angle = cycle_angle + 0.007; 
    
    // Tightened the smoothstep from (0.1, -0.1) to (0.05, -0.05).
    // This makes the fade from Red to White happen much faster instead of a long, slow bleed.
    let retract_blend = smoothstep(0.05, -0.05, cos(advanced_angle));
    
    let spawn_phase = sin(cycle_angle);
    let growth_factor = smoothstep(-0.2, 0.6, spawn_phase);
    
    if (growth_factor < 0.01) {
        return vec2f(100.0, MAT_DIRT);
    }
    
    let max_length = 2.2 * growth_factor;
    let h = clamp(q.x, 0.0, max_length); 
    
    let arch_y = h * 1.0 - (h * h * 0.4);
    let phase = sector * 13.5;
    
    let move_mask = smoothstep(0.2, max_length, h);
    let writhe_y = sin(time * 4.0 + h * 6.0 + phase) * 0.15 * move_mask;
    let writhe_z = cos(time * 3.1 + h * 5.0 + phase) * 0.15 * move_mask;
    
    let core_line = vec3f(h, arch_y + writhe_y, writhe_z);
    
    let cross_section = vec2f(q.y - core_line.y, q.z - core_line.z);
    let angle_around = atan2(cross_section.y, cross_section.x);
    let twist = h * 12.0 - time * 3.0; 
    
    // THE 3-STRIPE & TEXTURE MATH
    let total_angle = (angle_around * 3.0) + twist;
    let muscle_lobes = cos(total_angle);
    let bumps = sin(h * 30.0 - time * 5.0) * cos(angle_around * 5.0);
    
    let taper = 1.0 - (h / max_length); 
    let base_thickness = 0.06 * growth_factor * taper;
    let gooey_thickness = base_thickness + (muscle_lobes * 0.02 * taper) + (bumps * 0.005 * taper);
    
    let d = length(q - core_line) - gooey_thickness;
    
   // --- MATERIAL CHOPPER ---
    let single_wrap = (angle_around + (twist / 3.0)) / 6.2831853;
    let lobe_id = floor(fract(single_wrap + 100.1666) * 3.0);
    
    var lobe_mat = MAT_DIRT; 
    
    if (lobe_id == 1.0) {
        lobe_mat = MAT_STEM; 
    } else if (lobe_id == 2.0) {
        // Pass the Retraction state safely into our new custom ID
        lobe_mat = MAT_TENTACLE + clamp(retract_blend, 0.0, 0.99); 
    }
    
    return vec2f(d * 0.45, lobe_mat);
}


fn sdPetal(p: vec3f, s: f32) -> f32 {
    var pos = p;

    // Normalize 's' for blending
    // s is now between 0.2 and 0.35
    let t = smoothstep(0.2, 0.35, s);

    let width_factor = mix(0.3, 1.0, t);

    // --- BENDING ---
    
    //SIDE CUPPING (Spoon shape)
    // Stronger on inside (2.0), weaker on outside (1.0)
    let cup_strength = mix(1.9, 0.05, t);
    let cup_strength_y = mix(0.2, 0.5, t);
    pos.z += pos.x * pos.x * cup_strength;
    pos.z += pos.y * pos.y * cup_strength_y;

   // pos.x /= pos.z*0.5; 
  
  //  pos.y /= pos.z*0.5;

    let curl_factor = mix(0.9, 3.2, t);

  let tip_height = max(pos.y - 0.3, 0.0);
    let tip_side = max(abs(pos.x)/curl_factor - 0.1, 0.0);
    // We calculate a curve strength based on height
    // We use a square curve (pow 2.0) for a smooth bend
    let curl_amount = pow(tip_height, 2.0) * 2.0 * t +  pow(tip_side, 2.0)*0.8; // Active mainly on outer petals
    
    // Curl BACK (Negative Z)
    pos.z -= curl_amount;
    


let bulge_domain = vec2f(pos.x, pos.y * 0.7); 
    let dist_sq = dot(bulge_domain, bulge_domain);
    
    
    let gaussian = exp(-4.0 * dist_sq);
    
    //  Apply bulge
 
    let bulge_strength = 0.25; 
    
    // Subtract from Z to push it "Out" 
    pos.z -= gaussian * bulge_strength;
  
  //  let z_taper_strength = 0.8; 
   // let z_scale = clamp(1.0 + pos.z * z_taper_strength, 0.1, 2.0);



    // --- SHAPE ---
    let taper_strength = mix(0.3, 0.5, t);
    let taper = 1.0 + taper_strength * pos.y;
    

let pointiness = 1+ max(pos.y - 0.6, 0.0) * 2;

    // Clamp taper to be safe
    let p_x =(pos.x) / (clamp(taper, 0.1, 2.0)* width_factor);// 
    
    // Base Circle
    let d_2d = length(vec2f(p_x, pos.y)) - 0.8; 

    // Cut Top
    let d_flat_top = smax(d_2d, pos.y - 0.35, 0.05);

    // Thickness
    // Scale distance by 0.6 to avoid artifacts
    let d_final_2d = d_flat_top * 0.6; 

    let thickness = 0.01; 
    let d_z = abs(pos.z) - thickness;

    let w = vec2f(d_2d, d_z);
    return min(max(w.x, w.y), 0.0) + length(max(w, vec2f(0.0)));


 
}





fn sdFallingPetals(p: vec3f, time: f32) -> vec2f {
    let spacing = 2.0; 
    let cell = floor(p.xz / spacing);
    let local_p = fract(p.xz / spacing) - 0.5;
    let sign_p = sign(local_p);
    
    var d_min: f32 = 100.0;
    var final_mat: f32 = MAT_ROSE; 
    
    for (var i: f32 = 0.0; i <=1.0; i += 1.0) {
        for (var j: f32 = 0.0; j <= 1.0; j += 1.0) {
            let neighbor_offset = vec2f(i, j) * sign_p;
            let current_cell = cell + neighbor_offset;
            
            let seed = hash12(current_cell);
            let seed2 = hash12(current_cell + vec2f(13.3, 41.5));
            
            let speed = 0.55 + seed * 0.25; 
            let start_h = 7.0 + seed2 * 1.0;
            let cycle_duration = 19.0;// + seed * 3.0; 
            
            let local_time = (time + seed * 20.0) % cycle_duration;
            
            // "Virtual" drop Y is where it WOULD be if it never slowed down
            let virtual_drop_y = start_h - (local_time * speed);
            let ground_y = -0.45;// + seed * 0.06;
            let ground_dist = virtual_drop_y - ground_y;
            
            // --- 1. DISSOLVE EARLIER ---
            
            var dissolve_progress = smoothstep(12,19, local_time);
            
           // if (dissolve_progress > 0.99) { continue; }
            
            let size = 0.1 + seed * 0.04;
            
            // --- 2. THE SOFT LANDING ---
            var actual_y: f32 = virtual_drop_y;
            let landing_zone = 0.5; // Starts slowing down 0.5 units above ground
            
            if (ground_dist < landing_zone && ground_dist > 0.0) {
                // Map the distance to a 0.0 - 1.0 range, then apply a quadratic curve (t * t)
                // This naturally decelerates the fall and easing it perfectly into ground_y
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
            
            // --- 3. PERFECT HORIZONTAL LANDING ---
            // Calculate how far the petal is from its final resting place
            let resting_dist = max(0.0, actual_y - ground_y);
            
            // -1.57 radians is -90 degrees. This rotates the petal's face to lie perfectly flat on the ground.
            let target_rot_x = 1.57;  //-1.57; 
            let target_rot_z = 0.0; // Roll should be 0 so it doesn't clip into the dirt sideways
            
            // We rotate backwards from the flat target based on how high up in the air it is.
            // As resting_dist smoothly shrinks to 0.0, the rotation smoothly locks into the target!
            let rot_x = target_rot_x - (resting_dist * (2.5 + seed));
            let rot_z = target_rot_z - (resting_dist * (1.0 + seed * 5.0));
            
            // Yaw (Y-axis) can spin normally so the petals land facing random directions
            let fall_progress = start_h - actual_y;
            let rot_y = fall_progress * 1.5 + seed * 20.0;
            
            q = opRotateX(q, rot_x);
            q = opRotateY(q, rot_y);
            q = opRotateZ(q, rot_z);
            
      // --- 4. SWISS CHEESE EROSION & NOISE PROJECTION ---
            let local_q = q / size; 
            let d_base = sdPetal(local_q, 0.32) * size;
            
            let noise = (sin(local_q.x * 6.0) * sin(local_q.y * 9.0)* sin(local_q.z * 2.0)) * 0.5 + 0.5;

            // THE FIX 1: Increased from 1.5 to 2.5 so the holes expand enough to aggressively eat 100% of the petal
            let hole_size = dissolve_progress * 1.4; 
            let d_holes = (1.0 - noise) - hole_size; 
            
            let d = max(d_base, -d_holes * size * 0.15) * 0.6;
            
            if (d < d_min) 
            {
                d_min = d;
                
                if (dissolve_progress > 0.0) {
                    let rim_thickness = 0.05;
                    
                    if (d_holes < rim_thickness) {
                        // THE FIX 2: Replaced max(0.0, d_holes) with abs(d_holes).
                        // This forces the glow to ONLY exist on the razor-thin physical edge.
                        // The empty air inside the hole drops to 0.0, completely removing the "washed out blob" effect!
                        let glow_intensity = smoothstep(rim_thickness, 0.0, abs(d_holes));
                        
                        // THE FIX 3: Removed 'final_fade' entirely.
                        // The material will burn fiercely until the expanding holes completely erase the geometry.
                        final_mat = MAT_DISSOLVE + clamp(glow_intensity, 0.0, 0.99);
                    } 
                    else {
                        let dist_from_root = max(length(q + vec3f(0.0, 0.13, 0.0)) - 0.02, 0.0);
                        let gradient = clamp(dist_from_root * 8.0, 0.0, 0.99);
                        final_mat = MAT_ROSE + gradient;
                    }
                } else {
                    let dist_from_root = max(length(q + vec3f(0.0, 0.13, 0.0)) - 0.02, 0.0);
                    let gradient = clamp(dist_from_root * 8.0, 0.0, 0.99);
                    final_mat = MAT_ROSE + gradient;
                }
            }
        }
    }
    return vec2f(d_min, final_mat);
}

fn sdRose(p: vec3f) -> vec2f {
    let d_sphere = length(p - vec3f(0.0, 0.1, 0.0)) - 0.3;

    if (d_sphere > 0.05) {
        // Safe early exit, returning a dummy material
        return vec2f(d_sphere, MAT_ROSE);
    }

    var d_min = 100.0;
    let petal_count = 15.0; 
    let golden_angle = 2.39996; 
    let time = uniforms.time * 2.0;
    
    // Explicit f32 for the loop to prevent WGSL type errors
    for (var i: f32 = 1.0; i < 15.0; i += 1.0) { 
        let r = (0.01) * sqrt(i); 
        let theta = i * golden_angle;
         
        let petal_center = vec3f(r * cos(theta), -r * 0.2, r * sin(theta));
        let scale = 0.1 + (i / petal_count) * 0.25;

        var q = p - petal_center;
        q = opRotateY(q, -theta + 1.57);
      
        let tilt = -0.3 + (i / petal_count)* (0.9 + sin(time) * 0.15); 
        q = opRotateX(q, -tilt);
        q = q / 0.2;

        let pivot_offset = vec3f(0.0, 0.7, 0.0);
        let d = sdPetal(q - pivot_offset, scale) * scale;
        
        d_min = min(d_min, d);
    }
    
    // The closer the local point 'p' is to 0,0,0, the closer it is to the root.
    // Map this distance to a 0.0 - 0.99 gradient.
    let dist_from_center = max(length(p + vec3f(0.0, 0.1, 0.0)) - 0.05, 0.0);
    let gradient = clamp(dist_from_center * 3.5, 0.0, 0.99);
    
    return vec2f(d_min, MAT_ROSE + gradient);
}


fn sdLeaf(p: vec3f) -> f32 {
    // 1. THE PETIOLE (Leaf Stem)
    let petiole_length = 0.12;
    let p_start = vec3f(0.0, 0.0, 0.0);
    let p_end = vec3f(petiole_length, 0.03, 0.0); 
    
    let pa = p - p_start;
    let ba = p_end - p_start;
    let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    let d_petiole = length(pa - ba * h) - 0.008; 

    // 2. THE LEAF BLADE
    var q = p - p_end; 
    
    q.y += q.x * q.x * 0.5;   // Gravity bend
    q.y -= abs(q.z) * 0.2;    // V-shape fold
    
    let blade_len = 0.25;
    q.x -= blade_len; 
    
    let normalized_x = (q.x + blade_len) / (blade_len * 2.0);
    let leaf_width = 0.15 * sin(normalized_x * 3.14159);
    
    // --- THE CHEAP VEINS ---
    // A high-frequency cosine wave generating V-shaped diagonal ridges
    let vein_pattern = cos(q.x * 120.0 - abs(q.z) * 80.0) * 0.5 + 0.5;
    
    // Fade the veins out near the very edge and base so they don't look jagged
    let vein_mask = smoothstep(0.0, 0.02, abs(q.z)) * (1.0 - normalized_x * 0.5);
    
    // Displace the physical surface by 1.5 millimeters
    q.y += vein_pattern * vein_mask * 0.0015;
    // -----------------------
    
    let scale = vec3f(blade_len, 0.005, max(leaf_width, 0.01));
    
    let k0 = length(q / scale);
    let k1 = length(q / (scale * scale));
    let d_blade = k0 * (k0 - 1.0) / k1;
    
    return smin(d_petiole, d_blade, 0.015) * 0.75;
}

fn sdStem(p: vec3f, a: vec3f, b: vec3f, bend: f32, r: f32) -> f32 {
    let pa = p - a;
    let ba = b - a;
    
    // Find progress along the stem (0.0 = bottom, 1.0 = top)
    let h = clamp( dot(pa, ba) / dot(ba, ba), 0.0, 1.0 );
    
    // S-CURVE
    
    let wiggle = sin(h * 10.28318)*0.5;
    
    //THE STRAIGHTENER
   
    let straightness_mask = pow((1.0 - h), 0.8); 
    
 
    // We assume the bend is along X and Z to give it volume
    let offset_dir = vec3f(bend, 0.0, bend * 0.2);
    let current_offset = offset_dir * wiggle * straightness_mask;
    
    //Position on the curve
    let pos_on_line = a + ba * h + current_offset;
    
    // Taper Radius
    let radius = r * (1.0 - h * 0.4);
    
    //Distance with correction

    return (length(p - pos_on_line) - radius) * 0.6; 
}

fn sdStemWithSpines(p: vec3f, a: vec3f, b: vec3f, bend: f32, r: f32) -> vec2f {
    let pa = p - a;
    let ba = b - a;
    let ba_length = length(ba);
    
    //-------------------------STEM CURVE 
    let h = clamp( dot(pa, ba) / dot(ba, ba), 0.0, 1.0 );
    let wiggle = sin(h * 10.28318) * 0.5;
    let straightness_mask = pow((1.0 - h), 0.8); 
    let offset_dir = vec3f(bend, 0.0, bend * 0.2);
    let current_offset = offset_dir * wiggle * straightness_mask;
    
    let pos_on_line = a + ba * h + current_offset;
    let stem_radius = r * (1.0 - h * 0.4); 
    
    let d_stem = (length(p - pos_on_line) - stem_radius) * 0.6;
    
    // ----------------------SPINES
    var d_spine = 100.0;
  
    if (length(p - pos_on_line) < 0.2 && h > 0.1 && h < 0.9) {
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

    // --------------------- LEAF
    var d_leaf = 100.0;
    
    if (length(p - pos_on_line) < 0.9) {
        let leaf_density = 4.5; 
        let id = floor(h * leaf_density);
        
        if (id > 0.0 && id < 4.0) {
            let local_y = (fract(h * leaf_density) - 0.5) * (ba_length / leaf_density);
            
            var p_l = p - pos_on_line;
            p_l = opRotateY(p_l, id * 2.4 + 1.0); 
            p_l.y = local_y; 
            
            p_l.x -= (stem_radius - 0.01); 
            
            // --- THE SWAY MATH ---
            let time = uniforms.time;
            
            // Phase-shifted sine waves so each leaf moves independently
            let wind_sway = sin(time * 3.5 + id * 1.2) * 0.07; 
            let wind_twist = cos(time * 2.8 + id * 1.5) * 0.05;
            
            // Apply bounce (Z axis) and twist (X axis)
            let droop_angle = 0.3 - (id * 0.2) + wind_sway; 
            p_l = opRotateZ(p_l, droop_angle); 
            p_l = opRotateX(p_l, wind_twist); 
            // ---------------------
            
            d_leaf = sdLeaf(p_l);
        }
    }

    let d_stem_d_leaf = smin(d_stem, d_leaf, 0.003);
    var fin = smin(d_stem_d_leaf, d_spine, 0.01);
    
    // 1. Default the base geometry to the Stem material
    var material = MAT_STEM;
    
    // 2. If the ray is physically closer to a leaf than the stem, switch it!
    if (d_leaf < d_stem) {
        material = MAT_LEAVES;
    }
    
    // 3. If the ray is hitting a thorn, override everything else
    if (d_spine < d_stem_d_leaf) {
        material = MAT_THORNS; 
    }
    
    return vec2f(fin, material);
}


fn sdSpine(p: vec3f) -> f32 {
    var q = p-vec3f(0.0,0.7,0.0);

    q.z *=7.0; 

    q.x /= abs(q.y)*0.7; 
    q.x -= (1+q.y) * 1.5;


    let h = 1.0;
    let r = 0.15;

return sdCone(q, vec2f(r,r), h);
 
}

fn flower(p: vec3f, location: vec3f) -> vec2f {

  let d_sphere = length(p - vec3f(0.0, 1.0, 0.0)) - 0.4;

    if (d_sphere > 1.3) {
        return vec2f(d_sphere,0);
    }

  let time =uniforms.time;

    let center = vec3f(sin(time)*0.05,(1-abs(sin(time)))*0.03, sin(time)*0.03);

    let pos = p - (center + location);

   let pos_all =  p - location;
    
   let wind_bend = 0.3 + sin( 1.5 ) * 0.01; //0.2 + sin(time * 1.5) * 0.1; 
    
    let stem_start = vec3f(0.0, -location.y - 0.5, 0.0);
let stem_end = center; 


//let d_stem = sdStem(pos_all, stem_start, stem_end, wind_bend, 0.04);
let d_stem = sdStemWithSpines(pos_all, stem_start, stem_end, wind_bend, 0.04);

    var q = opPolarRep(pos, 5.0, 0.1);

    let curve = q.x * q.x*8 ; 
    
    let wave = sin(time + q.x * 50.0) * 0.005 + sin(time + q.z * 50.0) * 0.005 +sin(time + q.x * 80.0) * 0.003 + sin(time +     q.z * 80.0) * 0.003 ;
    
    q.y += curve + wave; 

    let size = 0.1;
    let v1 = vec3f(0.0, 0.0, -1.0 * size * 0.5);
    let v2 = vec3f(0.0, 0.0,  1.0 * size * 0.5); 
    let v3 = vec3f(1.5 * size, 0.0, 0.0);       

   
    let d_flat = udTriangle(q, v1, v2, v3);
    let d_sepals = d_flat - 0.01; 

   

    // ... inside flower(p, location) ...
    var d_bud = sdVerticalVesicaSegment( pos - vec3f(0.0, -0.13, 0.0), 0.4, 0.20);
    let cutoff_height = 0.1; 
    d_bud = max(d_bud, pos.y - cutoff_height);

   let rose_data = sdRose(pos + vec3f(0.0, -0.03, 0.0)); 
    let rose_dist = rose_data.x;
    
    // 1. Group the sepals and the bulb together
    let d_bulb_and_sepals = smin(d_sepals, d_bud, 0.02);

    // 2. Group all the greenery (stem + bulb/sepals)
    let d_all_greenery = smin(d_stem.x, d_bulb_and_sepals, 0.02);

    // 3. Final distance check against the rose petals
    let flower_final = min(rose_dist, d_all_greenery); 
    
    // --- MATERIAL ASSIGNMENT LOGIC ---
    
    // Default to the stem's material (which could be MAT_STEM, MAT_LEAVES, or MAT_THORNS)
    var material = d_stem.y;

    // If the ray is hitting the bulb or the sepals, force it to MAT_LEAVES
    if (d_bulb_and_sepals < d_stem.x) {
        material = MAT_LEAVES;
    }

    // If the ray is hitting the rose petals, override everything else
    if(rose_dist < d_all_greenery) {
        material = rose_data.y; // This passes the MAT_ROSE + gradient forward!
    } 
    
    return vec2f(flower_final, material);
}

fn getPetalFloorEffects(p: vec3f, time: f32) -> vec3f { // RETURN CHANGED TO vec3f
    let spacing = 2.0; 
    let cell = floor(p.xz / spacing);
    let local_p = fract(p.xz / spacing) - 0.5;
    let sign_p = sign(local_p);
    
    var total_shadow = 0.0;
    var total_light = 0.0;
    var max_dissolve = 0.0; // NEW: Tracks how far the petal has dissolved
    
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
            let ground_y = -0.45;
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
                
                // Matches your exact 3D petal dissolve timing
                let dissolve_progress = smoothstep(12.0, 19.0, local_time);
                let dissolve_fade = 1.0 - dissolve_progress;
                
                let shadow_radius = 0.12 + height_above_floor * 0.3;
                let shadow_softness = smoothstep(shadow_radius, 0.0, dist_to_petal_2d);
                let shadow_opacity = smoothstep(1.5, 0.0, height_above_floor) * 0.8; 
                total_shadow += shadow_softness * shadow_opacity * dissolve_fade;
                
                let light_radius = 0.35;
                let light_softness = smoothstep(light_radius, 0.0, dist_to_petal_2d);
                let light_opacity = smoothstep(1.5, 0.0, height_above_floor);
                
                let current_light = light_softness * light_opacity * dissolve_fade;
                total_light += current_light;
                
                // NEW: Grab the dissolve state only if the light is physically hitting this pixel
                if (current_light > 0.0) {
                    max_dissolve = max(max_dissolve, dissolve_progress);
                }
            }
        }
    }
    // RETURN ALL THREE
    return vec3f(clamp(total_shadow, 0.0, 1.0), clamp(total_light, 0.0, 1.0), max_dissolve);
}

// --- The Main Scene Description ---

fn map(p_in: vec3f) -> vec2f {
    var p = p_in;
    
    let time = uniforms.time ;

    let a = atan2(p.z, p.x);
    let r = length(p.xz);
    
    let hole_size = 0.5 + sin(time *0.3) * 0.2; // Base size of the hole, oscillates over time

    let dirt_radius = hole_size + sin(sin(time * 0.1) * a * 7.0 + time * 0.8) * 0.1*hole_size + cos(a * 3.14 - time * 0.2) * 0.08*hole_size;

    // 1. Create a sloped mask. 
    // It is 0.0 at the outer edge (dirt_radius) and ramps to 1.0 inside (70% of the radius).
    let hole_mask = smoothstep(dirt_radius, dirt_radius * 0.7, r);
    
    // 2. Push the ground down based on the mask
    let hole_depth = 0.2; // Adjust this to make the crater deeper or shallower
    var ground_height = -0.5 - (hole_mask * hole_depth);
    
    var mat = MAT_GROUND;

    if (r < dirt_radius) {
        mat = MAT_DIRT;
        
        // Calculate the squirming dirt noise
        let noise = sin(time + p.x*10.0)*0.03 + sin(time*3.0+p.z*13.0)*0.03 + 
                    sin(2.5*time + p.x*15.0)*0.05 + sin(2.0*time + p.z*18.0)*0.01 + 
                    sin(8.0*time+30.0 + p.x*110.0)*0.002 + sin(time+35.0+p.z*115.0)*0.002 + 
                    sin(6.0*time+10.0 + p.x*127.0)*0.001 + sin(4.0*time+5.0+p.z*143.0)*0.001;
        
        // Apply noise, but multiply it by the mask so the edge of the hole 
        // stays perfectly flush with the outer ground, preventing seams.
        ground_height += noise * hole_mask;
    }

   
   // 3. Distance field evaluation. 
    var res = vec2f((p.y - ground_height) * 0.7, mat);

    // --- THE WRITHING BLACK CORE ---
    // Anchor it to the exact same depth as the tentacle roots
    let core_center = vec3f(0.0, -0.65, 0.0); 
    
    // Size it to perfectly fill the 'abyss' gap we left in the middle of the tentacles
    let core_radius = hole_size * 0.55; 
    
    // Base sphere
    var d_core = length(p - core_center) - core_radius;
    
    // High-frequency 3D noise to crush the sphere into a tangled ball of tendrils
    let core_noise = sin(p.x * 40.0 + time * 4.0) * sin(p.y * 40.0 - time * 2.0) * sin(p.z * 40.0 + time * 3.5) * 0.04;
                     
    // Add the noise, and apply a 0.5 safety brake so the raymarcher doesn't 
    // tear through the heavy displacement!
    d_core = (d_core + core_noise) * 0.5; 
    
    if (d_core < res.x) {
        // MAT_DIRT is your pitch-black, matte material. 
        // It perfectly matches the black lobes of the tentacles!
        res = vec2f(d_core, MAT_DIRT); 
    }


// --- NEW: THE WRITHING TENTACLES ---
    // Pass in your breathing hole_size so the roots track the edge perfectly!
    let tentacles = sdTentacles(p, time, hole_size);
    if (tentacles.x < res.x) {
        res = tentacles;
    }

    let flower_pos = vec3f(0.0, 2.0, 0.0);

    let d_t =  flower(p, flower_pos);

    if (d_t.x < res.x) { 

        res = vec2f(d_t.x, d_t.y); 
    }

 

    // New Petal Integration
    let res_petals = sdFallingPetals(p, time);
    if (res_petals.x < res.x) {
        res = res_petals; 
    }

    return res; 
}

fn calc_normal(p: vec3f) -> vec3f {
    let e = 0.002;
  
    let dx = map(p + vec3f(e, 0.0, 0.0)).x - map(p - vec3f(e, 0.0, 0.0)).x;
    let dy = map(p + vec3f(0.0, e, 0.0)).x - map(p - vec3f(0.0, e, 0.0)).x;
    let dz = map(p + vec3f(0.0, 0.0, e)).x - map(p - vec3f(0.0, 0.0, e)).x;
    
    return normalize(vec3f(dx, dy, dz));
}

// fn softshadow(ro: vec3f, rd: vec3f, mint: f32, tmax: f32) -> f32 {
// 	var res = 1.0;
//     var t = mint;
//     for(var i=0; i<16; i++) {
// 		let h = map(ro + rd*t).x;
//         res = min( res, 8.0*h/t );
//         t += clamp( h, 0.01, 0.10 );
//         if( h<0.001 || t>tmax ) { break; }
//     }
//     return clamp( res, 0.0, 1.0 );
// }
fn map_shadow(p: vec3f) -> f32 {
    let time = uniforms.time;
    // Only evaluate the things we want casting shadows!
    let d_tentacles = sdTentacles(p, time, 0.5 + sin(time *0.3) * 0.2).x;
   // let d_petals = sdFallingPetals(p, time).x;
    
    return d_tentacles;
}

fn softshadow(ro: vec3f, rd: vec3f, mint: f32, tmax: f32, k: f32) -> f32 {
    var res = 1.0;
    var t = mint;
    var ph = 1e20; // "Previous h" - start with a huge number

    for(var i = 0; i < 16; i++) { // Increased iterations for accuracy
        //let h = map(ro + rd * t).x;
        let h = map_shadow(ro + rd * t);
        // --- The Accuracy Fix ---
        // Instead of just min(res, k*h/t), we calculate the 
        // distance from the ray SEGMENT to the object.
        // This effectively removes banding/striations in the shadow.
        
        let y = h * h / (2.0 * ph); 
        let d = sqrt(h * h - y * y);
        res = min(res, k * d / max(0.0, t - y));
        
        // ------------------------

        ph = h;
        
        // Note: For your Rose Leaf, because of domain warping, 
        // the SDF is not exact. Multiply h by ~0.8 to prevent artifacts.
        t += h; 
        
        if(res < 0.001 || t > tmax) { break; }
    }
    
    // Smoothstep creates a cleaner falloff from light to dark
    res = clamp(res, 0.0, 1.0);
    return res * res * (3.0 - 2.0 * res); 
}

@fragment

fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {

   

   let resolution = uniforms.resolution;
    let uv = (pos.xy * 2.0 - resolution) / resolution.y;
    let uv_flipped = vec2f(uv.x, -uv.y);

    let time = uniforms.time * 2.0 ;

    let yaw =  uniforms.yaw ;   //uniforms.camera.x;
    let pitch =0.5 +   clamp(uniforms.pitch,-1,1)*0.1; //uniforms.camera.y;
    let radius = 2.0;
   let ro = vec3f(
        radius * cos(pitch) * sin(yaw),
        radius * sin(pitch) + 2.0, 
        radius * cos(pitch) * cos(yaw)
    ) + vec3f(0.0, 0.0, 0.0);

    let lookAt = vec3f(0.0, 2, 0.0);
    
    let fwd = normalize(lookAt - ro);
    let right = normalize(cross(vec3f(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    let rd = normalize(fwd + right * uv_flipped.x + up * uv_flipped.y);
    
   var t = 0.0;        
    var hit = false;    
    var mat_id = -1.0;
    
    let current_rose_color = mix(COLOR_RED, COLOR_WHITE, uniforms.color_t);
    let current_dissolve_color = mix(COLOR_WHITE, COLOR_RED, uniforms.color_t); // The exact opposite!

    // Create an accumulator for our volumetric bloom
    var accumulated_glow = vec3f(0.0, 0.0, 0.0);

    for(var i = 0; i < 250; i++) { 
        let p = ro + rd * t;
        let res = map(p); 
        let d = res.x;
        mat_id = res.y;

        let mat_base = floor(mat_id);
        let mat_frac = fract(mat_id); // EXTRACT IT HERE!

        if ( mat_base == MAT_ROSE || mat_base == MAT_THORNS) {
            accumulated_glow += current_rose_color * (0.0008 / (0.01 + d * d * 10.0));
        }
        else if (mat_base == MAT_TENTACLE) { 
            // Mix between the actual rose color and the dissolve color
            let strand_color = mix(current_rose_color, current_dissolve_color, mat_frac);
            // Tight falloff (500.0) so the glow stays sharply on its own strand!
            accumulated_glow += strand_color * (0.0008 / (0.01 + d * d * 20.0)); 
        }
        else if (mat_base == MAT_DISSOLVE) { 
            accumulated_glow += current_dissolve_color * (0.0008 / (0.01 + d * d * 5.0)) * mat_frac; 
        }

        if (d < 0.001) { hit = true; break; }
        if (t > 20.0) { break; }
        t = t + d * 0.3; 
    }
    var final_color =vec3f(0.0, 0.0, 0.0);     

   if (hit) {
        let p = ro + rd * t;       
        let normal = calc_normal(p); 
        let view_dir = normalize(ro - p); // Needed for specular shine
        
        let light_pos = vec3f(1.0,6.0, 0.0);
        
        // 1. Calculate Distance for Falloff
        let light_vec = light_pos - p;
        let light_dist = length(light_vec);
        let light_dir = light_vec / light_dist; // Normalized direction
        
        let half_dir = normalize(light_dir + view_dir); 
        
        // 2. The Attenuation Math (Inverse Square Law with a softening factor)
        let light_intensity = 11.0; // Boost the bulb power to compensate for falloff
        let attenuation = light_intensity / (1.0 + 0.1 * light_dist + 0.15 * (light_dist * light_dist));
        
        let diff = clamp(dot(normal, light_dir), 0.1, 1.0);
        let shadow = softshadow(p + normal * 0.01, light_dir, 0.02, light_dist, 16.0);

       var albedo = vec3f(0.0);
        var roughness = 1.0;
        var spec_power = 0.0;
        var rim_light = 0.0;
        var emission = vec3f(0.0); // 1. Add this new emission variable
        
        let mat_base = floor(mat_id);
        let mat_frac = fract(mat_id);
        
        if (abs(mat_base - MAT_GROUND) < 0.1) {
            albedo = vec3f(0.2, 0.2, 0.2);  
            roughness = 10.0;   
            spec_power = 0.3;

           let floor_effects = getPetalFloorEffects(p, uniforms.time);
            let shadow_amt = floor_effects.x;
            let light_amt = floor_effects.y;
            let color_shift = floor_effects.z; // NEW: The dissolve progress (0.0 to 1.0)
            
            albedo = albedo * (1.0 - shadow_amt);
            
            let base_light = mix(COLOR_RED, COLOR_WHITE, uniforms.color_t);
            let dissolve_light = mix(COLOR_WHITE, COLOR_RED, uniforms.color_t); // The opposite color
            
            // Crossfade the final light on the floor as the petal burns
            let final_glow_color = mix(base_light, dissolve_light, color_shift);
            
            emission += final_glow_color * light_amt * 1.5;
            
        } else if (abs(mat_base - MAT_STEM) < 0.1) {
            albedo = vec3f(0.05, 0.1, 0.02) * 1.5;
            roughness = 180.0;   
            spec_power = 1.2;
             
        } else if (abs(mat_base - MAT_ROSE) < 0.1) {
            let base_color = current_dissolve_color*0.6 ; 
            let tip_color = current_rose_color * 0.8; // Uses dynamic color
            
            albedo = mix(base_color, tip_color, smoothstep(0.0, 0.55, mat_frac));
            
            roughness = 180.0;    
            spec_power = 1.2;
            rim_light = pow(1.0 - max(dot(normal, view_dir), 0.0), 3.0) * 0.95;
            emission = albedo * 0.2;
            
        } else if (abs(mat_base - MAT_DIRT) < 0.1) { 
            albedo = vec3f(0.0, 0.0, 0.0);  
            roughness = 35.0;  
            spec_power = 1.2;

        } else if (abs(mat_base - MAT_DISSOLVE) < 0.1) {
            let glow_intensity = mat_frac;
            let tip_color = current_rose_color * 0.8; 
            let glow_color = current_dissolve_color * 1.5; // Uses the opposite color
            
            albedo = mix(tip_color, glow_color, glow_intensity);
            
            roughness = 6.0;
            spec_power = 0.1;
            emission = glow_color * glow_intensity * 2.5;

        } else if (abs(mat_base - MAT_THORNS) < 0.1) {
            albedo = current_rose_color; // Uses dynamic color
            roughness = 60.0;    
            spec_power = 0.5;
        }
      else if (abs(mat_base - MAT_LEAVES) < 0.1) {
            albedo = vec3f(0.05, 0.1, 0.02) * 0.8;
            roughness = 180.0;   
            spec_power = 1.2;
            
        } else if (abs(mat_base - MAT_TENTACLE) < 0.1) {
            let strand_color = mix(current_rose_color, current_dissolve_color, mat_frac);
            
            albedo = strand_color * 0.8; // Exactly matches the rose tip_color multiplier
            roughness = 180.0;    
            spec_power = 1.2;
            rim_light = pow(1.0 - max(dot(normal, view_dir), 0.0), 3.0) * 0.95;
            emission = albedo * 0.2; // Perfectly matches the rose emission
        }

        let ambient = vec3f(0.45) * albedo; 
        let diffuse_color = albedo * diff * vec3f(1.0, 0.95, 0.8);
        let diffuse = diffuse_color * attenuation* shadow ;// 
        let spec_angle = max(dot(normal, half_dir), 0.0);
        let specular = pow(spec_angle, roughness) * spec_power * attenuation; 
        
        // Add emission directly to the end. It ignores shadows and attenuation!
        final_color = ambient + diffuse + (vec3f(1.0, 0.9, 0.8) * specular) + (albedo * rim_light * attenuation) + emission;
    }

   if (hit) {
        let hit_mat = floor(mat_id);
        // Add MAT_TENTACLE here:
        if (hit_mat == MAT_ROSE || hit_mat == MAT_DISSOLVE || hit_mat == MAT_TENTACLE) {
            accumulated_glow *= 0.1; 
        }
    }

    // 2. Exponential Distance Fog (Your existing code)
    let fog_density = 0.012; 
    let fog_factor = 1.0 - exp(-fog_density * t * t);
    final_color = mix(final_color, vec3f(0.0, 0.0, 0.0), clamp(fog_factor, 0.0, 1.0));

    

   // --- 3. Additive Volumetric Bloom ---
    // A very light depth fog strictly for the glow. 
    // We use 0.003 (much weaker than the 0.012 geometry fog) so the light 
    // lingers in the air longer than the solid objects before softly fading out!
    let glow_fog_density = 0.002; 
    let glow_fog = exp(-glow_fog_density * t * t);
    
    // Multiply the accumulated glow by the light fog before adding it to the scene
    final_color += accumulated_glow * glow_fog;

    // --- NEW: GROUND HEIGHT MIST ---
    if (hit) {
        let p = ro + rd * t;
        // Mist is thickest at -0.5 (ground) and fades out completely by 0.2 (mid-air)
        let mist_thickness = smoothstep(0.7, -0.5, p.y);
        
        // We multiply by (1.0 - fog_factor) so the mist fades into the black void in the distance
        let mist_intensity = mist_thickness * 0.6* (1.0 - fog_factor); 
        
        let mist_color = current_dissolve_color;  // current_rose_color; 
        final_color = mix(final_color, mist_color, mist_intensity);
    }


    // 4. Film Grain Noise
    let noise = hash12(pos.xy + uniforms.time);
    final_color += (noise - 0.5) * (25.0 / 255.0);

    return vec4f(final_color, 1.0);
}