const std = @import("std");
const camera = @import("camera");
const buffer_queue = @import("buffer_queue");
const encoding = @import("encoding");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("linux/videodev2.h");
    @cInclude("errno.h");
    @cInclude("sys/ioctl.h");
    @cInclude("string.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libavutil/imgutils.h");
});

pub const linked_list = struct {
    data: u8,
    next: ?*linked_list,
};

pub const shared_data = struct {
    head: ?*linked_list,
    mutex: std.Io.Mutex,
};

var DATA: shared_data = .{
    .head = null,
    .mutex = std.Io.Mutex.init(),
};

pub fn perfect_core_layout() !void {
    // Implementation for perfect core layout
    std.debug.print("Using perfect core layout\n", .{});

    std.debug.print("====================\n");
    std.debug.print("Initializing thread pool... (using new Io concurrent)\n", .{});
    const allocator = blk: if (.ReleaseFast == builtin.mode) {
        break :blk std.heap.SmpAllocator;
    }
    else {
        const gpa : std.heap.GeneralPurposeAllocator = .init{};
        break :blk gpa.allocator;
    }
    const allocator = std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    std.debug.print("Finished setting up threads and io\n", .{});

    std.debug.print("====================\n");

    var cam = try camera.init("/dev/video0", gpa);
    defer cam.deinit();

    //try pool.spawn(capture_thread, .{&cam});
    try pool.spawn(encoding.encoding_thread, .{});

    for (pool.threads) |thread| {
        thread.join();
    }
}

fn capture_thread(cam: *camera.Camera) void {
    std.debug.print("Number of buffers in camera: {d}\n", .{cam.buffers.len});
    cam.start_capturing() catch |err| {
        std.debug.print("Error starting capturing: {any}\n", .{err});
        return;
    };
    std.debug.print("Started infinitely capturing frames...\n", .{});
    cam.capture_frames_infinitely() catch return;
}

fn encoding_thread(cam: *camera.Camera) void {
    std.debug.print("Encoding thread started...\n", .{});
    _ = &cam;

    //##########################################################################

    std.debug.print("Starting FFmpeg initialization...\n", .{});

    var fmt_ctx: ?*c.struct_AVFormatContext = null;

    if (0 > c.avformat_alloc_output_context2(&fmt_ctx, null, null, "output.mp4")) {
        std.debug.print("Failed to allocate output context\n", .{});
    }

    const codec: ?*c.AVCodec = c.avcodec_find_encoder(c.AV_CODEC_ID_H264);
    if (null == codec) {
        std.debug.print("H.264 codec not found\n", .{});
    }

    var video_st: ?*c.struct_AVStream = null;
    video_st = c.avformat_new_stream(fmt_ctx, null);
    if (null == video_st) {
        std.debug.print("Failed to create new stream\n", .{});
    }

    var enc_ctx: ?*c.struct_AVCodecContext = null;
    enc_ctx = c.avcodec_alloc_context3(codec);
    enc_ctx.?.width = 640;
    enc_ctx.?.height = 480;
    //enc_ctx.?.time_base = (c.AVRational){ .num = 1, .den = 30 };
    enc_ctx.?.time_base = .{ .num = 1, .den = 30 };
    enc_ctx.?.framerate = .{ .num = 30, .den = 1 };
    enc_ctx.?.pix_fmt = c.AV_PIX_FMT_YUV420P;
    enc_ctx.?.bit_rate = 400000;
    enc_ctx.?.gop_size = 30;
    enc_ctx.?.max_b_frames = 0;

    _ = c.av_opt_set(enc_ctx.?.priv_data, "preset", "ultrafast", 0);
    _ = c.av_opt_set(enc_ctx.?.priv_data, "tune", "zerolatency", 0);

    if ((fmt_ctx.?.*.oformat.*.flags & c.AVFMT_GLOBALHEADER) != 0) {
        enc_ctx.?.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    if (c.avcodec_open2(enc_ctx.?, codec.?, null) < 0) {
        std.debug.print("Could not open codec\n", .{});
    }

    _ = c.avcodec_parameters_from_context(video_st.?.codecpar, enc_ctx.?);
    video_st.?.time_base = enc_ctx.?.time_base;

    if ((fmt_ctx.?.*.oformat.*.flags & c.AVFMT_NOFILE) == 0) {
        if (c.avio_open(&fmt_ctx.?.*.pb, "output.mp4", c.AVIO_FLAG_WRITE) < 0) {
            std.debug.print("Could not open output file\n", .{});
        }
    }

    if (c.avformat_write_header(fmt_ctx.?, null) < 0) {
        std.debug.print("Error occurred when opening output file\n", .{});
    }

    std.debug.print("FFmpeg initialization completed successfully.\n", .{});

    //##########################################################################
    // Pre-allocate everything we need for the hot loop

    const width = enc_ctx.?.width;
    const height = enc_ctx.?.height;

    var frame = c.av_frame_alloc() orelse {
        std.debug.print("Could not allocate video frame\n", .{});
        return;
    };
    defer c.av_frame_free(&frame);

    const num_bytes = c.av_image_get_buffer_size(enc_ctx.?.pix_fmt, width, height, 1);
    const yuv_buffer = c.av_malloc(@intCast(num_bytes)) orelse {
        std.debug.print("av_malloc failed for yuv buffer\n", .{});
        return;
    };
    defer c.av_free(yuv_buffer);

    _ = c.av_image_fill_arrays(
        frame.*.data[0..8],
        frame.*.linesize[0..8],
        @ptrCast(yuv_buffer),
        enc_ctx.?.pix_fmt,
        width,
        height,
        1,
    );

    frame.*.format = enc_ctx.?.pix_fmt;
    frame.*.width = width;
    frame.*.height = height;

    var pkt: c.struct_AVPacket = std.mem.zeroes(c.struct_AVPacket);
    _ = c.av_init_packet(&pkt);
    defer c.av_packet_unref(&pkt);

    var pts: i64 = 0;
    _ = &pts;

    //##########################################################################

    while (true) {
        const nullable_new_buffer = buffer_queue.EncodingBuffer.get_most_recent_buffer_number();
        if (nullable_new_buffer == null) continue;

        const new_buffer = nullable_new_buffer.?;
        defer cam.release_buffer(new_buffer) catch |err| blk: {
            std.debug.print("Error releasing buffer: {any}\n", .{err});
            break :blk;
        };
        std.debug.print("Encoding buffer number: {d}\n", .{new_buffer});

        var cam_buf: c.struct_v4l2_buffer = std.mem.zeroes(c.struct_v4l2_buffer);
        cam_buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        cam_buf.memory = c.V4L2_MEMORY_MMAP;

        if (-1 == xioctl(cam.file_descriptor.?, c.VIDIOC_DQBUF, &cam_buf)) {
            std.debug.print("Failed to dequeue buffer for encoding.\n", .{});
            continue;
        }

        const yuyv_ptr = cam.buffers[new_buffer].start;
        const yuyv_len = cam_buf.bytesused;
        if (yuyv_len < (width * height * 2)) {
            std.debug.print("YUYV buffer too small (got {d} but expected {d} bytes)\n", .{ yuyv_len, (width * height * 2) });
            continue;
        }

        // ---- 3d) Convert YUYV422 → YUV420P (manual, zero-allocation) ----
        const src_stride: usize = @intCast(width * 2); // YUYV = 2 bytes/pixel
        const yuyv_u8: [*c]const u8 = @ptrCast(yuyv_ptr);

        const y_plane = frame.*.data[0];
        const y_stride: usize = @intCast(frame.*.linesize[0]);
        const u_plane = frame.*.data[1];
        const v_plane = frame.*.data[2];
        const uv_stride: usize = @intCast(frame.*.linesize[1]);

        var y: usize = 0;
        while (y < height) : (y += 2) {
            var x: usize = 0;
            const row0 = yuyv_u8 + (y + 0) * src_stride;
            const row1 = yuyv_u8 + (y + 1) * src_stride;

            while (x < width) : (x += 2) {
                // ---- two YUYV macropixels (4 bytes) → 4 Y + 1 U + 1 V ----
                const y0 = row0[0]; // Y
                const u = row0[1]; // U (shared)
                const y1 = row0[2]; // Y
                const v = row0[3]; // V (shared)

                const y2 = row1[0]; // Y (next line)
                const y3 = row1[2]; // Y (next line)

                // ---- store Y (full resolution) ----
                y_plane[(y + 0) * y_stride + (x + 0)] = y0;
                y_plane[(y + 0) * y_stride + (x + 1)] = y1;
                y_plane[(y + 1) * y_stride + (x + 0)] = y2;
                y_plane[(y + 1) * y_stride + (x + 1)] = y3;

                // ---- store U/V (half resolution) ----
                u_plane[(y / 2) * uv_stride + (x / 2)] = u;
                v_plane[(y / 2) * uv_stride + (x / 2)] = v;

                // advance source pointer (4 bytes per macropixel pair)
                _ = row0 + 4;
                _ = row1 + 4;
            }
        }
        if (cam_buf.flags & c.V4L2_BUF_FLAG_TIMESTAMP_MASK == c.V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC) {
            const ts_sec = cam_buf.timestamp.tv_sec;
            const ts_usec = cam_buf.timestamp.tv_usec;
            pts = @intCast(ts_sec * 1_000_000 + ts_usec);
            pts = pts * @divExact(enc_ctx.?.*.time_base.den, 1_000_000); // convert µs → PTS units
        } else {
            pts += 1; // simple frame counter fallback
        }
        frame.*.pts = pts;

        if (c.avcodec_send_frame(enc_ctx, frame) < 0) {
            std.debug.print("avcodec_send_frame failed\n", .{});
            _ = xioctl(cam.file_descriptor.?, c.VIDIOC_QBUF, &cam_buf);
            continue;
        }
        while (true) {
            const ret = c.avcodec_receive_packet(enc_ctx, &pkt);
            if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF) break;
            if (ret < 0) {
                std.debug.print("avcodec_receive_packet error: {d}\n", .{ret});
                break;
            }

            // rescale packet timestamps from codec time_base → stream time_base
            pkt.pts = c.av_rescale_q_rnd(pkt.pts, enc_ctx.?.*.time_base, video_st.?.*.time_base, c.AV_ROUND_NEAR_INF);
            pkt.dts = c.av_rescale_q_rnd(pkt.dts, enc_ctx.?.*.time_base, video_st.?.*.time_base, c.AV_ROUND_NEAR_INF);
            pkt.duration = c.av_rescale_q(pkt.duration, enc_ctx.?.*.time_base, video_st.?.*.time_base);
            pkt.stream_index = video_st.?.*.index;

            // write packet
            _ = c.av_interleaved_write_frame(fmt_ctx, &pkt);
            c.av_packet_unref(&pkt);
        }

        // ---- 3h) Re-queue the V4L2 buffer (so the capture thread can reuse it) ----
        if (xioctl(cam.file_descriptor.?, c.VIDIOC_QBUF, &cam_buf) == -1) {
            std.debug.print("VIDIOC_QBUF failed (idx={d})\n", .{new_buffer});
        }
    }
}

fn xioctl(fd: c_int, request: c_ulong, arg: *anyopaque) c_int {
    var r: c_int = -1;
    r = c.ioctl(fd, request, arg);
    while (-1 == r and std.c._errno().* == c.EINTR) {
        r = c.ioctl(fd, request, arg);
    }
    return r;
}
