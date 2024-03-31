const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");

const ModeEnum = enum { sine, pulse, square};
const mode: ModeEnum = .pulse;
const c = 0.1;
const cord_len: f64 = 15.0;
const SimEnum = enum { bad, accel };
const sim: SimEnum = .accel;

var run_sim = false;
var procs: gl.ProcTable = undefined;

const vertex_shader = @embedFile("./vertex.glsl");

const fragment_shader = @embedFile("./fragment.glsl");

const shader_error = error{ vShaderFailed, fShaderFailed, ShaderError };

pub fn main() !void {
    const screen_width: u32 = 800;
    const screen_height: u32 = 600;
    const partitions: u32 = 5000;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    glfw.setErrorCallback(errorCallback);
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        return error.InitFailed;
    }
    defer glfw.terminate();
    

    // Create our window
    const window = glfw.Window.create(screen_width, screen_height, "POV standing wave", null, null, .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile
    }) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return error.InitFailed;
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    if(!procs.init(glfw.getProcAddress)) {
        std.log.err("failed to init procTable: {?s}", .{glfw.getErrorString()});
        return error.InitFailed;
    }
    gl.makeProcTableCurrent(&procs);
    defer gl.makeProcTableCurrent(null);

    gl.Viewport(0, 0, screen_width, screen_height);
    window.setSizeCallback(sizingCallback);
    window.setKeyCallback(input);

    var success: gl.int = undefined;
    var info_log: [512]gl.char = undefined;
    const shader_program = gl.CreateProgram();
    defer gl.DeleteProgram(shader_program);
    {
        const v_shader = gl.CreateShader(gl.VERTEX_SHADER);
        defer gl.DeleteShader(v_shader);
        gl.ShaderSource(v_shader, 1, @ptrCast(&vertex_shader), null);
        gl.CompileShader(v_shader);
        gl.GetShaderiv(v_shader, gl.COMPILE_STATUS, &success);
        if (success == 0) {
            gl.GetShaderInfoLog(v_shader, 512, null, &info_log);
            std.debug.print("Error in vertex shader compilation:\n {s}", .{info_log});
            return error.vShaderFailed;
        }

        const f_shader = gl.CreateShader(gl.FRAGMENT_SHADER);
        defer gl.DeleteShader(f_shader);
        gl.ShaderSource(f_shader, 1, @ptrCast(&fragment_shader), null);
        gl.CompileShader(f_shader);
        gl.GetShaderiv(f_shader, gl.COMPILE_STATUS, &success);
        if (success == 0) {
            gl.GetShaderInfoLog(f_shader, 512, null, &info_log);
            std.debug.print("Error in fragment shader compilation:\n {s}", .{info_log});
            return error.fShaderFailed;
        }

        gl.AttachShader(shader_program, v_shader);
        gl.AttachShader(shader_program, f_shader);
        gl.LinkProgram(shader_program);
        gl.GetProgramiv(shader_program, gl.LINK_STATUS, &success);
        if (success == 0) {
            gl.GetProgramInfoLog(shader_program, 512, null, &info_log);
            std.debug.print("Error in program compilation:\n {s}", .{info_log});
            return error.ShaderError;
        }
    }
    const time_location = gl.GetUniformLocation(shader_program, "time");

    var data = initConditions(allocator, partitions, cord_len) catch { std.debug.print("OOM", .{}); std.os.exit(1); };
    defer allocator.free(data);
    const x_buffer = data[0..partitions];

    var y_buffer = data[partitions..][0..partitions];
    var step_buffer = allocator.alloc(f64, y_buffer.len * 2) catch { std.debug.print("OOM", .{}); std.os.exit(1); };
    var buffer1 = step_buffer[0..partitions];
    var buffer2 = step_buffer[partitions..][0..partitions];
    switch(sim) {
        .bad => {
            //in bad, buffer1 = past, buffer2 = future
            @memcpy(buffer1, y_buffer);
        },
        .accel => {
            //in accel, buffer1 = accel, buffer2 = vel
            @memset(step_buffer, 0);
        }
    }

    defer allocator.free(step_buffer);

    var vertices = try allocator.alloc(f32, data.len);
    defer allocator.free(vertices);
    scaleXVertices(x_buffer, cord_len, vertices[0..partitions]);
    scaleYVertices(y_buffer, 1.1, vertices[partitions..][0..partitions]);
    
    var vao: [1]gl.uint = undefined;
    gl.GenVertexArrays(1, &vao);
    defer gl.DeleteVertexArrays(1, &vao);
    var vbo: [2]gl.uint = undefined;
    gl.GenBuffers(2, &vbo);
    defer gl.DeleteBuffers(2, &vbo);

    gl.BindVertexArray(vao[0]);

    const x_index = 0;
    const y_index = 1;

    gl.BindBuffer(gl.ARRAY_BUFFER, vbo[0]);
    gl.VertexAttribPointer(x_index, 1, gl.FLOAT, gl.FALSE, @sizeOf(gl.float), 0);
    gl.BufferData(gl.ARRAY_BUFFER, partitions * @sizeOf(gl.float), vertices[0..partitions], gl.STATIC_DRAW);

    gl.BindBuffer(gl.ARRAY_BUFFER, vbo[1]);
    gl.VertexAttribPointer(y_index, 1, gl.FLOAT, gl.FALSE, @sizeOf(gl.float), 0);
    gl.BufferData(gl.ARRAY_BUFFER, partitions * @sizeOf(gl.float), vertices[partitions..][0..partitions], gl.DYNAMIC_DRAW);

    gl.EnableVertexAttribArray(x_index);
    gl.EnableVertexAttribArray(y_index);

    gl.BindVertexArray(0);
    gl.BindBuffer(gl.ARRAY_BUFFER, 0);

    var delta_t_acc: f64 = undefined;

    while (!window.shouldClose()) {
        glfw.pollEvents();

        if(run_sim) {
            const delta_t = 0.002;
            switch (sim) {
                .bad => {
                    physicsStepBad(delta_t, x_buffer[1]-x_buffer[0], buffer1, y_buffer, buffer2);
                    var temp: @TypeOf(y_buffer) = undefined;
                    temp = buffer1;
                    buffer1 = y_buffer;
                    y_buffer = buffer2;
                    buffer2 = temp;
                },
                .accel => {
                    physicsStepAccel(delta_t, x_buffer[1]-x_buffer[0], buffer1, buffer2, y_buffer);
                }

            }
            scaleYVertices(y_buffer, 1.1, vertices[partitions..][0..partitions]);
            
            gl.BindBuffer(gl.ARRAY_BUFFER, vbo[1]);
            gl.BufferSubData(gl.ARRAY_BUFFER, 0, partitions * @sizeOf(gl.float), vertices[partitions..][0..partitions]);
            delta_t_acc += delta_t;
            gl.Uniform1f(time_location, @floatCast(delta_t_acc / 50.0));
        }
        gl.ClearColor(0, 0, 0, 0);
        gl.Clear(gl.COLOR_BUFFER_BIT);

        gl.UseProgram(shader_program);
        gl.BindVertexArray(vao[0]);
        
        gl.DrawArrays(gl.LINE_STRIP, 0, partitions);
        window.swapBuffers();
        std.time.sleep(10000);
    }
}

fn initConditions(ally: std.mem.Allocator, n: u32, cord_length: f64) ![]f64 {
    var result = try ally.alloc(f64, 2 * n);

    const step: f64 = cord_length / @as(f64, @floatFromInt(n));

    for(result[0..n], 0..) |*x, i| {
        x.* = step * @as(f64, @floatFromInt(i));
    }

    for(result[n..][0..n], 0..) |*y, i| {
        switch(mode) {
            .sine => {
                y.* = @sin(std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) * 2);
            },
            .pulse => {
                y.* = blk: {
                    if(i >= n * 4 / 7) break :blk 0.0;
                    if(i <= n * 3 / 7) break :blk 0.0;
                    break :blk @sin(std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) * 2 * 7 / 2.0);
                };
            },
            .square => {
                y.* = blk: {
                    if(i >= n * 4 / 7) break :blk 0.0;
                    if(i <= n * 3 / 7) break :blk 0.0;
                    break :blk 1.0;
                };
            }
        }
    }
    return result;
}

fn scaleXVertices(data: []f64, cord_length: f64, out_buffer: []f32) void {
    if(data.len > out_buffer.len) unreachable;
    for(data, out_buffer) |in, *out| {
        out.* = @floatCast((in / cord_length - 0.5) * 1.9);
    }
}

fn scaleYVertices(data: []f64, amplitude: f64, out_buffer: []f32) void {
    if(data.len > out_buffer.len) unreachable;
    for(data, out_buffer) |in, *out| {
        out.* = @floatCast(in / amplitude);
    }
}

fn physicsStepBad(delta_t: f64, delta_x: f64, past_buffer: []const f64, curr_buffer: []const f64, fut_buffer: []f64) void {
    //assume endpoints are fixed
    for(fut_buffer[1..fut_buffer.len-1], 1..) |*out, i| {
        out.* = blk: {
            var acc = 2 * curr_buffer[i];
            acc -= past_buffer[i];
            const curvy = (curr_buffer[i+1] - 2*curr_buffer[i] + curr_buffer[i-1]) / (delta_x * delta_x);
            acc += c * c * delta_t * delta_t * curvy;
            break :blk acc;
        };
    }
    fut_buffer[0] = curr_buffer[0];
    fut_buffer[fut_buffer.len-1] = curr_buffer[fut_buffer.len-1];
}

fn physicsStepAccel(delta_t: f64, delta_x: f64, accel: []f64, vel: []f64, curr_buffer: []f64) void {

    for(accel[1..accel.len-1], vel[1..accel.len-1], 1..) |*out_a, *out_v, i| {
        out_a.* = c * c * (curr_buffer[i+1] - 2*curr_buffer[i] + curr_buffer[i-1]) / (delta_x * delta_x);
        out_v.* += delta_t * out_a.*;
    }
    for(curr_buffer[1..curr_buffer.len-1], 1..) |*out, i| {
        out.* += vel[i] * delta_t;
    }
}

fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

fn sizingCallback(_: glfw.Window, width: i32, height: i32) void {
    gl.Viewport(0, 0, width, height);
}

fn input(window: glfw.Window, key: glfw.Key, scan_code: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = scan_code; // autofix
    _ = mods; // autofix
    switch(key) {
        .escape => window.setShouldClose(true),
        .space => {if(action == .press) run_sim = true;},
        else => {}
    }
}
