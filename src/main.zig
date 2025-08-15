const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");

const content_dir = @import("build_options").content_dir;
const window_title = "BROT";

const FractalFrame = struct {
    center: @Vector(2, f32),
    resolution: @Vector(2, f32),
    height_scale: f32,
};

const GLFWRefs = struct {
    frame: *FractalFrame,
};

pub fn main() !void {
    try zglfw.init();
    defer zglfw.terminate();

    // Change current working directory to where the executable is located.
    {
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.posix.chdir(path) catch {};
    }

    zglfw.windowHint(.client_api, .no_api);

    const window = try zglfw.Window.create(800, 500, window_title, null);
    defer window.destroy();
    window.setSizeLimits(400, 400, -1, -1);

    var glfw_refs: GLFWRefs = undefined;
    window.setUserPointer(&glfw_refs);
    _ = window.setScrollCallback(scrollCallback);

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const required_limits: wgpu.RequiredLimits = .{ .limits = .{
        .max_bind_groups = 1,
        .max_uniform_buffers_per_shader_stage = 1,
        .max_uniform_buffer_binding_size = 16 * 4,
        .max_sampled_textures_per_shader_stage = 1,
    } };

    const gctx = try zgpu.GraphicsContext.create(
        gpa,
        .{
            .window = window,
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        },
        .{ .required_limits = &required_limits },
    );
    defer gctx.destroy(gpa);

    // ------------ gui -------------

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    zgui.init(gpa);
    defer zgui.deinit();

    _ = zgui.io.addFontFromFile(
        content_dir ++ "fonts/Roboto-Medium.ttf",
        std.math.floor(16.0 * scale_factor),
    );

    zgui.backend.init(
        window,
        gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    defer zgui.backend.deinit();

    zgui.getStyle().scaleAllSizes(scale_factor);

    // ----------- end gui -----------

    // ----------------- texture -----------------------
    const texture_desc: wgpu.TextureDescriptor = .{
        .dimension = .tdim_2d,
        .format = .rgba8_unorm,
        .mip_level_count = 1,
        .sample_count = 1,
        .size = .{ .width = 256, .height = 256, .depth_or_array_layers = 1 },
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .view_format_count = 0,
        .view_formats = null,
    };

    const texture: wgpu.Texture = gctx.device.createTexture(texture_desc);
    defer texture.destroy();
    defer texture.release();

    // configure test gradient

    var pixels = try gpa.alloc(u8, 4 * texture_desc.size.width * texture_desc.size.height);
    defer gpa.free(pixels);
    for (0..texture_desc.size.width) |i| {
        for (0..texture_desc.size.height) |j| {
            const index = 4 * (j * texture_desc.size.width + i);
            const p: []u8 = pixels[index .. index + 4];
            p[0] = @truncate(i);
            p[1] = @truncate(j);
            p[2] = 128;
            p[3] = 255;
        }
    }

    // upload data

    const destination: wgpu.ImageCopyTexture = .{
        .texture = texture,
        .mip_level = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = .all,
    };
    const source: wgpu.TextureDataLayout = .{
        .offset = 0,
        .bytes_per_row = 4 * texture_desc.size.width,
        .rows_per_image = texture_desc.size.height,
    };

    gctx.queue.writeTexture(destination, source, texture_desc.size, u8, pixels);

    // texture view

    const texture_view_desc: wgpu.TextureViewDescriptor = .{
        .aspect = .all,
        .base_array_layer = 0,
        .array_layer_count = 1,
        .base_mip_level = 0,
        .mip_level_count = 1,
        .dimension = .tvdim_2d,
        .format = texture_desc.format,
    };

    const texture_view = texture.createView(texture_view_desc);

    // -------------- end textrue ------------------------

    var fractal_frame: FractalFrame = .{
        .center = .{ 0, 0 },
        .resolution = .{ @floatFromInt(gctx.swapchain_descriptor.width), @floatFromInt(gctx.swapchain_descriptor.height) },
        .height_scale = 1,
    };
    glfw_refs.frame = &fractal_frame;

    const uniform_buffer_desc: wgpu.BufferDescriptor = .{
        .size = @sizeOf(FractalFrame),
        .usage = .{ .copy_dst = true, .uniform = true },
        .mapped_at_creation = .false,
    };
    const uniform_buffer: wgpu.Buffer = gctx.device.createBuffer(uniform_buffer_desc);
    defer uniform_buffer.release();

    const fractal_uniform_group = createBindGroupAndLayout(gctx, uniform_buffer, texture_view);
    var bind_group_layout = fractal_uniform_group.bind_group_layout;
    var bind_group = fractal_uniform_group.bind_group;
    defer bind_group_layout.release();
    defer bind_group.release();

    gctx.device.getQueue().writeBuffer(uniform_buffer, 0, FractalFrame, (&fractal_frame)[0..1]);

    const fractal_pipeline = try createFractalPipeline(gctx, gpa, (&bind_group_layout)[0..1]);
    defer fractal_pipeline.release();

    // ----------------- main loop ----------------------------------
    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();

        fractal_frame.resolution = .{ @floatFromInt(gctx.swapchain_descriptor.width), @floatFromInt(gctx.swapchain_descriptor.height) };
        gctx.device.getQueue().writeBuffer(uniform_buffer, 0, FractalFrame, (&fractal_frame)[0..1]);

        zgui.backend.newFrame(
            gctx.swapchain_descriptor.width,
            gctx.swapchain_descriptor.height,
        );

        // Set the starting window position and size to custom values
        zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

        if (zgui.begin("My window", .{})) {
            if (zgui.button("Press me!", .{ .w = 200.0 })) {
                std.debug.print("Button pressed\n", .{});
            }
        }
        zgui.end();

        const swapchain_texv = gctx.swapchain.getCurrentTextureView();
        defer swapchain_texv.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            // fractal pass
            {
                const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
                defer zgpu.endReleasePass(pass);
                pass.setPipeline(fractal_pipeline);
                pass.setBindGroup(0, bind_group, null);
                pass.draw(6, 1, 0, 0);
            }

            // GUI pass
            {
                const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
                defer zgpu.endReleasePass(pass);
                zgui.backend.draw(pass);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});
        _ = gctx.present();
    }
}

fn scrollCallback(
    window: *zglfw.Window,
    xoffset: f64,
    yoffset: f64,
) callconv(.c) void {
    const refs = window.getUserPointer(GLFWRefs);
    _ = xoffset;
    const scroll_factor: f32 = @floatCast(@exp(0.3 * yoffset));
    var frame = refs.?.frame;

    var mouse_pos_x: f64 = undefined;
    var mouse_pos_y: f64 = undefined;
    zglfw.getCursorPos(window, &mouse_pos_x, &mouse_pos_y);

    // change mouse_pos to Vulkan coords
    mouse_pos_x = 2.0 * mouse_pos_x / @as(f64, frame.resolution[0]) - 1.0;
    mouse_pos_y = 2.0 * mouse_pos_y / @as(f64, frame.resolution[1]) - 1.0;

    // change mouse_pos to mandelbrot coords
    mouse_pos_x = mouse_pos_x * frame.height_scale * frame.resolution[0] / frame.resolution[1];
    mouse_pos_y = mouse_pos_y * frame.height_scale;

    frame.center[0] += @as(f32, @floatCast((1.0 - scroll_factor) * mouse_pos_x));
    frame.center[1] += @as(f32, @floatCast((1.0 - scroll_factor) * mouse_pos_y));

    frame.height_scale *= scroll_factor;
}

fn createFractalPipeline(gctx: *const zgpu.GraphicsContext, alloc: std.mem.Allocator, bind_group_layouts: []const wgpu.BindGroupLayout) !wgpu.RenderPipeline {
    const pipeline_layout_desc: wgpu.PipelineLayoutDescriptor = .{
        .bind_group_layout_count = bind_group_layouts.len,
        .bind_group_layouts = bind_group_layouts.ptr,
    };
    var pipeline_layout = gctx.device.createPipelineLayout(pipeline_layout_desc);
    defer pipeline_layout.release();

    var shader_file: std.fs.File = try std.fs.cwd().openFile(content_dir ++ "shaders/test.wgsl", .{});
    const shader_code = try shader_file.readToEndAllocOptions(alloc, 16_384, null, 4, 0);

    const shader_code_desc: wgpu.ShaderModuleWGSLDescriptor = .{
        .chain = .{
            .next = null,
            .struct_type = .shader_module_wgsl_descriptor,
        },
        .code = shader_code,
    };
    const shader_desc: wgpu.ShaderModuleDescriptor = .{
        .next_in_chain = @ptrCast(&shader_code_desc),
    };
    const shader_module: wgpu.ShaderModule = gctx.device.createShaderModule(shader_desc);

    const blend_state: wgpu.BlendState = .{
        .color = .{
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
            .operation = .add,
        },
        .alpha = .{
            .src_factor = .zero,
            .dst_factor = .one,
            .operation = .add,
        },
    };
    const color_target: wgpu.ColorTargetState = .{
        .format = gctx.swapchain_descriptor.format,
        .write_mask = .all,
        .blend = &blend_state,
    };

    const pipeline_info: wgpu.RenderPipelineDescriptor = .{
        .vertex = .{
            .buffer_count = 0,
            .buffers = null,
            .module = shader_module,
            .entry_point = "vs_main",
            .constant_count = 0,
            .constants = null,
        },
        .primitive = .{
            .topology = .triangle_list,
            .strip_index_format = .undef,
            .front_face = .ccw,
            .cull_mode = .none,
        },
        .fragment = &.{
            .module = shader_module,
            .entry_point = "texture_passthrough",
            .constant_count = 0,
            .constants = null,
            .target_count = 1,
            .targets = @ptrCast(&color_target),
        },
        .depth_stencil = null,
        .layout = pipeline_layout,
        .multisample = .{
            .count = 1,
            .mask = ~@as(u32, 0),
            .alpha_to_coverage_enabled = false,
        },
    };

    const fractal_pipeline: wgpu.RenderPipeline = gctx.device.createRenderPipeline(pipeline_info);

    alloc.free(shader_code);
    shader_module.release();

    return fractal_pipeline;
}

fn createBindGroupAndLayout(gctx: *const zgpu.GraphicsContext, uniform_buffer: wgpu.Buffer, texture_view: wgpu.TextureView) struct {
    bind_group_layout: wgpu.BindGroupLayout,
    bind_group: wgpu.BindGroup,
} {
    const binding_layout: [2]wgpu.BindGroupLayoutEntry = .{ .{
        .binding = 0,
        .visibility = .{ .fragment = true },
        .buffer = .{ .binding_type = .uniform, .min_binding_size = @sizeOf(FractalFrame) },
    }, .{
        .binding = 1,
        .visibility = .{ .fragment = true },
        .texture = .{ .sample_type = .float, .view_dimension = .tvdim_2d },
    } };
    const bind_group_layout_desc: wgpu.BindGroupLayoutDescriptor = .{
        .entry_count = binding_layout.len,
        .entries = @ptrCast(&binding_layout),
    };
    const bind_group_layout = gctx.device.createBindGroupLayout(bind_group_layout_desc);

    const bindings: [2]wgpu.BindGroupEntry = .{ .{
        .binding = 0,
        .buffer = uniform_buffer,
        .offset = 0,
        .size = @sizeOf(FractalFrame),
    }, .{
        .binding = 1,
        .texture_view = texture_view,
        .size = 0,
    } };

    const bind_group_desc: wgpu.BindGroupDescriptor = .{
        .layout = bind_group_layout,
        .entry_count = bindings.len,
        .entries = @ptrCast(&bindings),
    };
    const bind_group = gctx.device.createBindGroup(bind_group_desc);

    return .{
        .bind_group_layout = bind_group_layout,
        .bind_group = bind_group,
    };
}
