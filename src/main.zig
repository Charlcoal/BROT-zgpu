const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");

const content_dir = @import("build_options").content_dir;
const window_title = "BROT";

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

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const required_limits: wgpu.RequiredLimits = .{ .limits = .{
        .max_bind_groups = 1,
        .max_uniform_buffers_per_shader_stage = 1,
        .max_uniform_buffer_binding_size = 16 * 4,
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

    // ----------- fractal pipeline ------------

    const FractalFrame = struct {
        center: @Vector(2, f32),
        resolution: @Vector(2, f32),
        height_scale: f32,
    };

    const uniform_buffer_desc: wgpu.BufferDescriptor = .{
        .size = @sizeOf(FractalFrame),
        .usage = .{ .copy_dst = true, .uniform = true },
        .mapped_at_creation = .false,
    };
    var uniform_buffer: wgpu.Buffer = gctx.device.createBuffer(uniform_buffer_desc);
    defer uniform_buffer.release();

    var fractal_frame: FractalFrame = .{
        .center = .{ 0, 0 },
        .resolution = .{ @floatFromInt(gctx.swapchain_descriptor.width), @floatFromInt(gctx.swapchain_descriptor.height) },
        .height_scale = 1,
    };

    gctx.device.getQueue().writeBuffer(uniform_buffer, 0, FractalFrame, (&fractal_frame)[0..1]);

    const binding_layout: wgpu.BindGroupLayoutEntry = .{
        .binding = 0,
        .visibility = .{ .fragment = true },
        .buffer = .{ .binding_type = .uniform, .min_binding_size = @sizeOf(FractalFrame) },
    };

    const bind_group_layout_desc: wgpu.BindGroupLayoutDescriptor = .{
        .entry_count = 1,
        .entries = @ptrCast(&binding_layout),
    };
    var bind_group_layout = gctx.device.createBindGroupLayout(bind_group_layout_desc);
    defer bind_group_layout.release();

    const binding: wgpu.BindGroupEntry = .{
        .binding = 0,
        .buffer = uniform_buffer,
        .offset = 0,
        .size = @sizeOf(FractalFrame),
    };

    const bind_group_desc: wgpu.BindGroupDescriptor = .{
        .layout = bind_group_layout,
        .entry_count = 1,
        .entries = @ptrCast(&binding),
    };
    var bind_group = gctx.device.createBindGroup(bind_group_desc);
    defer bind_group.release();

    const pipeline_layout_desc: wgpu.PipelineLayoutDescriptor = .{
        .bind_group_layout_count = 1,
        .bind_group_layouts = @ptrCast(&bind_group_layout),
    };
    var pipeline_layout = gctx.device.createPipelineLayout(pipeline_layout_desc);
    defer pipeline_layout.release();

    var shader_file: std.fs.File = try std.fs.cwd().openFile(content_dir ++ "shaders/test.wgsl", .{});
    const shader_code = try shader_file.readToEndAllocOptions(gpa, 16_384, null, 4, 0);

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
            .entry_point = "fs_main",
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
    defer fractal_pipeline.release();

    gpa.free(shader_code);
    shader_module.release();
    // ----------------- end fractal pipeline --------------------

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
