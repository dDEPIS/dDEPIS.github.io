struct Uniforms {
  resolution: vec2f,
  time: f32,
  padding: f32, // Padding to align the next vec2 to 16 bytes
  yaw: f32, // x = yaw, y = pitch
  pitch: f32
}



@group(0) @binding(0) var<uniform> uniforms: Uniforms;

// Constants for materials
const MAT_GROUND = 0.0;
const MAT_STEM = 1.0;
const MAT_ROSE = 2.0;
const MAT_DIRT = 3.0;
const MAT_DISSOLVE = 4.0;


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
    let spacing = 1.8; 
    let cell = floor(p.xz / spacing);
    let local_p = fract(p.xz / spacing) - 0.5;
    let sign_p = sign(local_p);
    
    var d_min: f32 = 100.0;
    var final_mat: f32 = MAT_ROSE; 
    
    for (var i: f32 = 0.0; i <= 1.0; i += 1.0) {
        for (var j: f32 = 0.0; j <= 1.0; j += 1.0) {
            let neighbor_offset = vec2f(i, j) * sign_p;
            let current_cell = cell + neighbor_offset;
            
            let seed = hash12(current_cell);
            let seed2 = hash12(current_cell + vec2f(13.3, 41.5));
            
            let speed = 0.25 + seed * 0.25; 
            let start_h = 4.0 + seed2 * 4.0;
            let cycle_duration = 12.0;// + seed * 3.0; 
            
            let local_time = (time + seed * 100.0) % cycle_duration;
            
            // "Virtual" drop Y is where it WOULD be if it never slowed down
            let virtual_drop_y = start_h - (local_time * speed);
            let ground_y = -0.48;// + seed * 0.06;
            let ground_dist = virtual_drop_y - ground_y;
            
            // --- 1. DISSOLVE EARLIER ---
            // Shifted the bounds: Starts dissolving 0.3 units ABOVE ground, 
            // finishes fully dissolving at 0.3 units BELOW virtual ground.
            let dissolve_progress = smoothstep(0.6, -0.2, ground_dist);
            
            if (dissolve_progress > 0.99) { continue; }
            
            let size = 0.13 + seed * 0.04;
            
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
            
            // Because 'actual_y' curves smoothly, the rotation naturally decelerates with it!
            let fall_progress = start_h - actual_y;
            q = opRotateX(q, fall_progress * (2.5 + seed) + seed * 10.0);
            q = opRotateY(q, fall_progress * 1.5 + seed * 20.0);
            q = opRotateZ(q, fall_progress * 1.0 + seed * 5.0);
            
            let d_base = sdPetal(q / size, 0.32) * size;
            
            let noise = (sin(q.x * 80.0) * sin(q.y * 50.0) * sin(q.z * 70.0)) * 0.5 + 0.5;
            let carve_amount =  (noise * dissolve_progress * 0.02);//(dissolve_progress * 0.05) +
            let d = d_base + carve_amount;
            
            if (d < d_min) {
                d_min = d;
                
                // 3. TRIGGER MATERIAL EARLIER
                // Switch to the glowing dissolve material as soon as the progress > 0
                if (dissolve_progress > 0.0) {
                    let glow_intensity = smoothstep(0.0, 1.0, noise) * sin(dissolve_progress * 3.1415);
                    final_mat = MAT_DISSOLVE + clamp(glow_intensity, 0.0, 0.99);
                } else {
                    final_mat = MAT_ROSE;
                }
            }
        }
    }
    return vec2f(d_min, final_mat);
}

fn sdRose(p: vec3f) -> f32 {


    let d_sphere = length(p - vec3f(0.0, 0.1, 0.0)) - 0.4;

    if (d_sphere > 0.05) {
        return d_sphere;
    }

    var d_min = 100.0;
   // var d_min_2d = distancePriority(100.0,0.0);

    let petal_count =15.0; 
    let golden_angle = 2.39996; 
      let time = uniforms.time * 2.0 ;
    for (var i = 1.0; i < petal_count; i += 1.0) {
        
        let r = (0.01) * sqrt(i); 
        let theta = i * golden_angle;
         
        // Lower outer petals
        let petal_center = vec3f(r * cos(theta), -r * 0.2, r * sin(theta));

        
        let scale = 0.1 + (i / petal_count) * 0.25;

        var q = p - petal_center;
        
        q = opRotateY(q, -theta + 1.57);
      
        let tilt = -0.3 + (i / petal_count)* (1.0+sin(time)*0.2); // 
        q = opRotateX(q, -tilt);
        
        // Scale the coordinate space
        q = q / 0.2;

        // Calculate distance and multiply back

    let pivot_offset = vec3f(0.0, 0.7, 0.0);
        
      
        let d = sdPetal(q - pivot_offset, scale) * scale;
        
   
         d_min = min(d_min, d);
  
    }
    
    return d_min;
}
fn sdLeaf(p: vec3f) -> f32 {
    
    // 1. THE PETIOLE (Leaf Stem) ---
 
    let petiole_length = 0.09;
    let p_start = vec3f(0.1, 0.1, 0.0);
    let p_end   = vec3f(petiole_length, -0.1, 0.0); // Slight rise in Y
    
    // Capsule SDF manually
    let pa = p - p_start;
    let ba = p_end - p_start;
    let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    let d_petiole = length(pa - ba * h) - 0.008; // 0.008 = Thickness


    // THE LEAF BLADE ---
    // Shift coordinate system to the end of the petiole
    var q = p ;
    
    let time =uniforms.time;

    // Rotate blade down slightly relative to the petiole
    q = opRotateZ(q, -0.9);
    q = opRotateY(q, -3.14);
    
    q= q- vec3f(-0.3, 0.0, 0.0);
    //BEND (Gravity)
    
    q.y += q.x * q.x * 1.5;
    
    // FOLD (V-shape)
    q.y -= abs(q.z) * 0.4;

    // SHAPE PROFILE (The "Rose" Shape)
 
    let blade_len = 0.25;
    
  
    let taper = smoothstep(-0.05, 0.1, q.x) * (1.0 - smoothstep(0.1, blade_len, q.x));
    
    let width_profile = mix(0.1, 5.0, q.x / blade_len);
 

    // DRAW BLADE
    
    let scale = vec3f(blade_len, 0.01, 0.15);
    
    // Ellipsoid SDF
    let k0 = length(q / scale);
    let k1 = length(q / (scale * scale));
    let d_blade = k0 * (k0 - 1.0) / k1;
    
   
    return smin(d_petiole, d_blade, 0.015);
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
    
    // Bounding box
    if (length(p - pos_on_line) < 0.9 && h > 0.15 && h < 0.8) {
        // Low Density: We only want ~3 leaves along the stem
        let leaf_density = 3.5; 
        let id = floor(h * leaf_density);
        
        // Calculate local Y same as spines
        let local_y = (fract(h * leaf_density) - 0.5) * (ba_length / leaf_density);
        
        var p_l = p - pos_on_line;
        
        // Rotate leaves. 
        // We add '+ 1.0' to offset them so they don't line up perfectly with spines
        p_l = opRotateY(p_l, id * 2.4 + 1.0); 
        
        p_l.y = local_y; 
        
        // Push out to surface
        p_l.x -= stem_radius; 
        
      
        p_l = opRotateZ(p_l, 0.7); 
        
        d_leaf = sdLeaf(p_l);
    }


    let d_stem_d_leaf = smin(d_stem, d_leaf, 0.003);
    
    var fin = smin(d_stem_d_leaf, d_spine, 0.01);
    var material = MAT_STEM;
    if(d_spine< d_stem_d_leaf)
    {
        material = MAT_DIRT; 
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
    
    let wave = sin(q.x * 50.0) * 0.005 + sin(q.z * 50.0) * 0.005 +sin(q.x * 80.0) * 0.003 + sin(q.z * 80.0) * 0.003 ;
    
    q.y += curve + wave; 

    let size = 0.1;
    let v1 = vec3f(0.0, 0.0, -1.0 * size * 0.5);
    let v2 = vec3f(0.0, 0.0,  1.0 * size * 0.5); 
    let v3 = vec3f(1.5 * size, 0.0, 0.0);       

   
    let d_flat = udTriangle(q, v1, v2, v3);
    let d_sepals = d_flat - 0.01; 

   

    var d_bud = sdVerticalVesicaSegment( pos - vec3f(0.0, -0.13, 0.0), 0.4, 0.20);

    let cutoff_height = 0.1; 
    d_bud =  max(d_bud, pos.y - cutoff_height);

  //  let d = sdPetal(pos ,1);

 
   var rose = sdRose(pos+ vec3f(0.0, -0.03, 0.0)); //sdRose(pos);
   var bud = min(d_sepals, d_bud);

    var d_greenery = smin(d_stem.x, d_sepals, 0.02);
    d_greenery = smin(d_greenery, d_bud, 0.02);


    
   let flower =min(rose,d_greenery);  //sdRose(pos);//  min(sdRose(pos),min(d, min(d_sepals, d_bud))) ; //min(d, min(d_sepals, d_bud)); 

    var material = d_stem.y;


    if( rose < d_greenery)
    {
        material = MAT_ROSE;
    } 
   return vec2f(flower, material);
}

// --- The Main Scene Description ---

fn map(p_in: vec3f) -> vec2f {
    var p = p_in;
    
    let time = uniforms.time ;

    // 1. Ground
     var res = vec2f(p.y + 0.5, MAT_GROUND);

    if(length( vec2f(p.x, p.z)) < 0.7)
    {
       
        res = vec2f(p.y + 0.5 +sin(p.x*10)*0.02 +sin(3+p.z*13)*0.03+ sin(p.x*15)*0.01 +sin(p.z*18)*0.01+ sin(30+ p.x*110)*0.002 +sin(35+p.z*115)*0.002
        + sin(10+ p.x*127)*0.001 +sin(5+p.z*123)*0.001, MAT_DIRT);
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
fn softshadow(ro: vec3f, rd: vec3f, mint: f32, tmax: f32, k: f32) -> f32 {
    var res = 1.0;
    var t = mint;
    var ph = 1e20; // "Previous h" - start with a huge number

    for(var i = 0; i < 16; i++) { // Increased iterations for accuracy
        let h = map(ro + rd * t).x;

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

    for(var i = 0; i < 150; i++) { 
        let p = ro + rd * t;
        let res = map(p); 
        let d = res.x;
        mat_id = res.y;

        if (d < 0.001) {    
            hit = true;
            break;
        }
        if (t > 20.0) {    
            break;
        }
        t = t + d * 0.3; 
    }

    var final_color =vec3f(0.0, 0.0, 0.0);     

    if (hit) {
        let p = ro + rd * t;       
        let normal = calc_normal(p); 
        
       // let light_pos = vec3f(4.0, 5.0, 0.0);
        let light_pos = vec3f(0.0, 15.0, 0.0);

        let light_dir = normalize(light_pos - p);
        
        let diff = clamp(dot(normal, light_dir), 0.1, 1.0);
        let shadow = softshadow(p + normal * 0.01, light_dir, 0.02, length(light_pos - p), 16.0);

        var albedo = vec3f(0.0);
        
        if (abs(mat_id - MAT_GROUND) < 0.1) {
            albedo = vec3f(0.2, 0.2, 0.2);  
           
        } else if (abs(mat_id - MAT_STEM) < 0.1) {
            albedo = vec3f(0.05, 0.1, 0.02)*0.8;
        } else if (abs(mat_id - MAT_ROSE) < 0.1) {
          //  let height_factor = smoothstep(2.0, 2.4, p.y);
            albedo =vec3f(0.15, 0.02, 0.05)*0.8;  //mix(vec3f(0.6, 0.0, 0.05), vec3f(0.9, 0.05, 0.1), height_factor);
        }
        else if (abs(mat_id - MAT_DIRT) < 0.1) {
           albedo = vec3f(0.1, 0.07, 0.0)*0.8;   
        }

         else if (mat_id >= MAT_DISSOLVE && mat_id < MAT_DISSOLVE + 1.0) 
         {
            
            // Unpack the 0.0 - 0.99 glow intensity
            let glow_intensity = fract(mat_id);
            
            let base_color = vec3f(0.15, 0.02, 0.05) * 0.8; 
            let glow_color = vec3f(0.15, 0.02, 0.05)*3; // Bright fiery orange
            
            // Apply the base texture mix
            albedo = mix(base_color, glow_color, glow_intensity);
            
            // Emissive Boost: 
            // Because ambient and diffuse multiply the albedo later, we push 
            // the albedo heavily over 1.0 so the final source color naturally acts emissive.
            albedo += glow_color * glow_intensity * 5.0; 
        }

        
        let ambient = vec3f(0.6) * albedo;
        let diffuse = albedo * diff * vec3f(1.0, 0.95, 0.8);// * shadow; 
        
        final_color = ambient + diffuse;
        final_color = mix(final_color, vec3f(0.0, 0.0, 0.0), 1.0 - exp(-0.01 * t * t));
    }


   let noise = hash12(pos.xy + uniforms.time);
    
 
    final_color += (noise - 0.5) * (25.0 / 255.0);


    return vec4f(final_color, 1.0);


    return vec4f(final_color, 1.0);
 
}