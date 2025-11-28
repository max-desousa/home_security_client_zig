const c = @import("c_imports").c;

const std = @import("std");
const debug = @import("debug");
const sync = @import("sync_data");

pub fn encoding_thread(sync_data: *sync.SynchronousData) void {
    debug.print("\tLooking for encoder...\n", .{});

    const encoder = find_encoder() catch |err| {
        debug.print("Failed to find encoder: {any}\n", .{err});
        sync_data.mutex.lock();
        defer sync_data.mutex.unlock();
        sync_data.sync_error = sync.ThreadingErrors.EncoderCouldNotBeFound;
        return;
    };

    debug.print("\tCreating encoder context...\n", .{});
    var encoder_context = create_encoder_context(encoder) catch |err| {
        debug.print("Failed to create encoder context: {any}\n", .{err});
        sync_data.mutex.lock();
        defer sync_data.mutex.unlock();
        sync_data.sync_error = sync.ThreadingErrors.EncoderCouldNotSetContext;
        return;
    };
    defer c.avcodec_free_context(&encoder_context);

    debug.print("\tCreating output context...\n", .{});
    var output_context = create_output_context(encoder_context, encoder) catch |err| {
        debug.print("Failed to create output context: {any}\n", .{err});
        sync_data.mutex.lock();
        defer sync_data.mutex.unlock();
        sync_data.sync_error = sync.ThreadingErrors.EncoderCouldNotSetOutputContext;
        return;
    };
    defer c.avformat_free_context(output_context);

    // === CRITICAL: Set time bases and global header flag ===
    encoder_context.*.time_base = .{ .num = 1, .den = 30 };
    encoder_context.*.framerate = .{ .num = 30, .den = 1 };
    output_context.*.streams[0].*.time_base = encoder_context.*.time_base;
    encoder_context.*.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;

    // Re-open codec with updated settings
    if (c.avcodec_open2(encoder_context, encoder, null) < 0) {
        debug.print("Could not open codec\n", .{});
        sync_data.mutex.lock();
        defer sync_data.mutex.unlock();
        sync_data.sync_error = sync.ThreadingErrors.EncoderCouldNotOpenCodec;
        return;
    }

    // Open output file
    if (c.avio_open(&output_context.pb, "output.mp4", c.AVIO_FLAG_WRITE) < 0) {
        debug.print("Could not open output file 'output.mp4'\n", .{});
        return;
    }
    defer _ = c.avio_closep(&output_context.pb);

    // === WRITE HEADER (THIS WAS MISSING!) ===
    if (c.avformat_write_header(output_context, null) < 0) {
        debug.print("Error writing MP4 header\n", .{});
        return;
    }

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = std.Io.Threaded.io(&threaded);

    const starting_time_stamp = std.Io.Clock.now(std.Io.Clock.real, io) catch unreachable;
    var current_time_stamp: std.Io.Timestamp = starting_time_stamp;
    var duration_in_seconds: i64 = 0;

    var frame_count: i64 = 0;

    while (duration_in_seconds < 10) {
        current_time_stamp = std.Io.Clock.now(std.Io.Clock.real, io) catch {
            sync_data.sync_error = sync.ThreadingErrors.IOError;
            break;
        };
        duration_in_seconds = std.Io.Timestamp.durationTo(starting_time_stamp, current_time_stamp).toSeconds();

        const buff_num = sync_data.get_first();
        if (buff_num == null) continue;

        const buffer_index = buff_num.?;

        // === Convert YUYV → YUV420P ===
        var raw_frame = c.av_frame_alloc() orelse {
            sync_data.pop() catch {};
            continue;
        };
        defer c.av_frame_free(&raw_frame);

        raw_frame.*.format = c.AV_PIX_FMT_YUYV422;
        raw_frame.*.width = 640;
        raw_frame.*.height = 480;
        if (c.av_frame_get_buffer(raw_frame, 0) < 0) {
            sync_data.pop() catch {};
            continue;
        }

        const yuyv_data: [*c]const u8 = @ptrCast(sync_data.buffers[buffer_index].start);
        const yuyv_size = sync_data.buffers[buffer_index].bytes_used;
        @memcpy(raw_frame.*.data[0], yuyv_data[0..yuyv_size]);
        raw_frame.*.linesize[0] = 640 * 2;

        var yuv420_frame = c.av_frame_alloc() orelse {
            sync_data.pop() catch {};
            continue;
        };
        defer c.av_frame_free(&yuv420_frame);

        yuv420_frame.*.format = c.AV_PIX_FMT_YUV420P;
        yuv420_frame.*.width = 640;
        yuv420_frame.*.height = 480;
        if (c.av_frame_get_buffer(yuv420_frame, 0) < 0) {
            sync_data.pop() catch {};
            continue;
        }

        const sws_ctx = c.sws_getContext(
            640,
            480,
            c.AV_PIX_FMT_YUYV422,
            640,
            480,
            c.AV_PIX_FMT_YUV420P,
            c.SWS_BILINEAR,
            null,
            null,
            null,
        ) orelse {
            sync_data.pop() catch {};
            continue;
        };
        defer c.sws_freeContext(sws_ctx);

        _ = c.sws_scale(sws_ctx, &raw_frame.*.data[0], &raw_frame.*.linesize[0], 0, 480, &yuv420_frame.*.data[0], &yuv420_frame.*.linesize[0]);

        // Set PTS (simple incrementing = rock solid)
        yuv420_frame.*.pts = frame_count;
        frame_count += 1;

        // Send frame to encoder
        _ = c.avcodec_send_frame(encoder_context, yuv420_frame);

        // Drain all available packets
        var packet: c.AVPacket = undefined;
        c.av_init_packet(&packet);
        packet.data = null;
        packet.size = 0;

        while (true) {
            const ret = c.avcodec_receive_packet(encoder_context, &packet);
            if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF) break;
            if (ret < 0) {
                debug.print("Error encoding frame\n", .{});
                break;
            }

            // Rescale timestamps
            packet.pts = c.av_rescale_q_rnd(packet.pts, encoder_context.*.time_base, output_context.*.streams[0].*.time_base, c.AV_ROUND_NEAR_INF);
            packet.dts = packet.pts;
            packet.duration = c.av_rescale_q(1, encoder_context.*.time_base, output_context.*.streams[0].*.time_base);
            packet.stream_index = 0;

            _ = c.av_interleaved_write_frame(output_context, &packet);
            c.av_packet_unref(&packet);
        }

        // Return buffer to camera
        sync_data.pop() catch {};
    }

    // === FINALIZE FILE ===
    _ = c.av_write_trailer(output_context);
    debug.print("Encoding complete. output.mp4 written.\n", .{});
}

pub fn find_encoder() !*c.struct_AVCodec {
    const codec = c.avcodec_find_encoder(c.AV_CODEC_ID_H264) orelse return error.CodecNotFound;
    return codec;
}

pub fn create_encoder_context(codec: *c.struct_AVCodec) ![*c]c.struct_AVCodecContext {
    const ctx = c.avcodec_alloc_context3(codec) orelse return error.AllocFailed;
    errdefer c.avcodec_free_context(&ctx);

    ctx.*.width = 640;
    ctx.*.height = 480;
    ctx.*.pix_fmt = c.AV_PIX_FMT_YUV420P;
    ctx.*.bit_rate = 2_000_000;
    ctx.*.gop_size = 30;
    ctx.*.max_b_frames = 0;

    // Low latency settings
    _ = c.av_opt_set(ctx.*.priv_data, "preset", "ultrafast", 0);
    _ = c.av_opt_set(ctx.*.priv_data, "tune", "zerolatency", 0);

    return ctx;
}

pub fn create_output_context(encoder_context: *c.struct_AVCodecContext, codec: *c.struct_AVCodec) !*c.struct_AVFormatContext {
    var fmt_ctx: ?*c.struct_AVFormatContext = null;
    if (c.avformat_alloc_output_context2(&fmt_ctx, null, null, "output.mp4") < 0) {
        return error.OutputContextFailed;
    }

    const stream = c.avformat_new_stream(fmt_ctx, null) orelse return error.StreamFailed;
    stream.*.codecpar.*.codec_id = codec.id;
    stream.*.codecpar.*.codec_type = c.AVMEDIA_TYPE_VIDEO;
    stream.*.codecpar.*.width = encoder_context.width;
    stream.*.codecpar.*.height = encoder_context.height;
    stream.*.codecpar.*.format = encoder_context.pix_fmt;
    stream.*.codecpar.*.bit_rate = encoder_context.bit_rate;

    return fmt_ctx.?;
}
