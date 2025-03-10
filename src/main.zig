const rl = @import("raylib");
const ma = @cImport({
    @cInclude("include/miniaudio.h");
});
const std = @import("std");
const Complex = std.math.complex.Complex(f32);
const PI = std.math.pi;

pub const FFTSIZE = 1 << 9;
var out_log: [FFTSIZE]f32 = undefined;
var out_smooth: [FFTSIZE]f32 = undefined;

const hannWindow = blk: {
    var table: [FFTSIZE]f32 = undefined;
    for (0..FFTSIZE) |i| {
        const t = @as(f32, @floatFromInt(i)) / (FFTSIZE - 1);
        const hann: f32 = 0.5 - 0.5 * @cos(2 * std.math.pi * t);
        table[i] = hann;
    }
    break :blk table;
};

fn map_to_logarithmic(fftData: []Complex, dt: f32) usize {
    const step: f32 = 1.06;
    const lowf: f32 = 1.0;
    var m: usize = 0;
    var max_amp: f32 = 1.0;

    var f: f32 = lowf;
    while (f < (FFTSIZE / 2)) : (f = @ceil(f * step)) {
        const f1: f32 = @ceil(f * step);
        var a: f32 = 0.0;
        var q: usize = @intFromFloat(f);

        const something = @as(usize, @intFromFloat(f1));
        while (q < (FFTSIZE / 2) and q < something) : (q += 1) {
            const b: f32 = fftData[q].magnitude();
            if (b > a) a = b;
        }
        if (max_amp < a) max_amp = a;
        m += 1;
        out_log[m] = a;
    }

    const smoothness: f32 = 8;
    for (0..m) |i| {
        out_log[i] /= max_amp;
        out_smooth[i] += (out_log[i] - out_smooth[i]) * smoothness * dt;
    }

    return m;
}

fn drawVisualizer(fftData: []Complex, dt: f32) void {
    const barsCount = map_to_logarithmic(fftData, dt);
    const barWidth = 800 / barsCount;

    for (0..barsCount) |i| {
        const magnitude = out_smooth[i];

        const scaledHeight = @as(i32, @intFromFloat(magnitude * 600));

        const x = i * barWidth;
        const y = 600 - scaledHeight;

        rl.drawRectangle(@intCast(x), y, @intCast(barWidth - 2), scaledHeight, rl.Color.white);
    }
}

fn data_callback(pDevice: [*c]ma.ma_device, pOutput: ?*anyopaque, pInput: ?*const anyopaque, frameCount: ma.ma_uint32) callconv(.C) void {
    _ = pOutput;
    const rawInput: [*]const f32 = @ptrCast(@alignCast(pInput));

    var fftBuffer: []Complex = @as([*]Complex, @ptrCast(@alignCast(pDevice.*.pUserData)))[0..frameCount];

    for (0..frameCount) |i| {
        const real = rawInput[i] * hannWindow[i];
        fftBuffer[i] = Complex{ .re = real, .im = 0 };
    }

    fft(fftBuffer);
}

fn fft(x: []Complex) void {
    const N = x.len;
    if (N <= 1) return;

    const allocator = std.heap.page_allocator;
    var even = allocator.alloc(Complex, N / 2) catch unreachable;
    var odd = allocator.alloc(Complex, N / 2) catch unreachable;
    defer allocator.free(even);
    defer allocator.free(odd);

    for (0..N / 2) |i| {
        even[i] = x[i * 2];
        odd[i] = x[i * 2 + 1];
    }

    fft(even);
    fft(odd);

    for (0..N / 2) |k| {
        const angle = -2.0 * PI * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(N));
        var t = Complex{ .re = @cos(angle), .im = @sin(angle) };
        t = t.mul(odd[k]);

        x[k] = even[k].add(t);
        x[k + N / 2] = even[k].sub(t);
    }
}

pub fn main() anyerror!void {
    // const backendsArray = [_]c_uint{@intCast(ma.ma_backend_pulseaudio)};
    // const backends: [*c]const c_uint = &backendsArray;
    var device: ma.ma_device = std.mem.zeroes(ma.ma_device);

    const allocator = std.heap.page_allocator;
    const userData = try allocator.alloc(Complex, FFTSIZE);

    var context: ma.ma_context = undefined;
    if (ma.ma_context_init(null, 0, null, &context) != ma.MA_SUCCESS) {
        std.debug.print("Failed to initialize context", .{});
        return;
    }

    var playbackInfos: [*c]ma.ma_device_info = undefined;
    var playbackCount: ma.ma_uint32 = 0;
    var captureInfos: [*c]ma.ma_device_info = undefined;
    var captureCount: ma.ma_uint32 = 0;

    if (ma.ma_context_get_devices(&context, &playbackInfos, &playbackCount, &captureInfos, &captureCount) != ma.MA_SUCCESS) {
        std.debug.print("Failed to get devices", .{});
        return;
    }

    for (0..captureCount) |i| {
        std.debug.print("{} - {s} \n", .{ i, captureInfos[i].name });
    }

    var deviceConfig = ma.ma_device_config_init(ma.ma_device_type_capture);
    deviceConfig.capture.pDeviceID = &captureInfos[2].id;
    deviceConfig.capture.format = ma.ma_format_f32;
    deviceConfig.capture.channels = 1;
    deviceConfig.sampleRate = 44100;
    deviceConfig.dataCallback = data_callback;
    deviceConfig.periodSizeInFrames = FFTSIZE;
    deviceConfig.pUserData = @ptrCast(userData.ptr);

    var result = ma.ma_device_init(&context, &deviceConfig, &device);
    if (result != ma.MA_SUCCESS) {
        std.debug.print("Failed to initialize loopback device. Error: {} \n", .{result});
        return;
    }
    defer ma.ma_device_uninit(&device);

    result = ma.ma_device_start(&device);
    if (result != ma.MA_SUCCESS) {
        ma.ma_device_uninit(&device);
        std.debug.print("Failed to start device", .{});
        return;
    }

    const screenWidth = 800;
    const screenHeight = 600;

    rl.initWindow(screenWidth, screenHeight, "Audio Visualizer");
    defer rl.closeWindow();

    rl.setTargetFPS(120);
    const image = try rl.Image.init("res/225.png");
    const texture = try rl.Texture.fromImage(image);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        {
            rl.clearBackground(rl.Color.black);
            rl.drawTexture(texture, @divFloor(screenWidth - texture.width, 2), @divFloor(screenHeight - texture.height, 2), rl.Color.white);
            drawVisualizer(userData, rl.getFrameTime());
        }
        rl.endDrawing();
    }
}
