struct FracFrame {
    center: vec2f,
    resolution: vec2f,
    height_scale: f32,
}

@group(0) @binding(0) var<uniform> frame: FracFrame;

@vertex
fn vs_main(@builtin(vertex_index) in_vertex_index: u32) -> @builtin(position) vec4f {
    const verts = array<vec2f, 6>(
        vec2f(-1.0, -1.0), vec2f(-1.0,  1.0), vec2f(1.0,  1.0),
        vec2f( 1.0,  1.0), vec2f(-1.0, -1.0), vec2f(1.0, -1.0)
    );
    var p = verts[in_vertex_index];
    return vec4f(p, 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) screen_pos: vec4f) -> @location(0) vec4f {
    const max_count: u32 = 5000;
	const escape_radius: f32 = 1e8;
	const interior_test_e_sqr: f32 = 1e-6;

    var c: vec2f = 2.0 * screen_pos.xy / frame.resolution;
    c -= vec2f(1); // coords match vert shader
    c *= frame.height_scale;
    c.x *= frame.resolution.x / frame.resolution.y;
    c += frame.center;
    var pos: vec2f = c;

    var count: u32 = 1;
    var x_sqr: f32 = pos.x * pos.x;
    var y_sqr: f32 = pos.y * pos.y;
	var rad_sqr: f32 = x_sqr + y_sqr;
	var interior_test_sqr: f32 = rad_sqr;
    while rad_sqr < escape_radius * escape_radius && count < max_count && interior_test_sqr > interior_test_e_sqr {
        pos.y = 2.0 * pos.x * pos.y + c.y;
        pos.x = x_sqr - y_sqr + c.x;
        x_sqr = pos.x * pos.x;
        y_sqr = pos.y * pos.y;
		rad_sqr = x_sqr + y_sqr;
		interior_test_sqr *= 4.0 * rad_sqr;
        count++;
    }

    if count == max_count || interior_test_sqr <= interior_test_e_sqr {
    	return vec4f(0.0, 0.0, 0.0, 1.0);
    } else {
		let neg_log_potential = max(0, f32(count) - log2(log2(x_sqr + y_sqr) / 2.0f));
		let portion = neg_log_potential / f32(max_count);
    	return vec4f(sin(portion * 60.0f - 0.8f) / 2.0f + 0.5f, sin(portion * 60.0f - 1.6f) / 2.0f + 0.5f, 0.0, 1.0);
	}
}