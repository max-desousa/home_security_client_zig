// src/encoding/root_encoding.zig
const std = @import("std");
const sync = @import("sync_data");
const config = @import("config");
const c = @import("c_imports");
const time = @import("time");
const sys = @import("sys");
const camera = @import("camera");

//##############################################################################
// Function: encoding_thread
//
// Description: This is the main entry point for running the endless encoding
//              loop for the captured frames.
//##############################################################################
pub fn encoding_thread(
    io: std.Io,
    allocator : std.mem.Allocator, 
    frame_data : []camera.MemoryMappedFrame,
    frames_to_encode : *std.Io.Queue(usize),
    frames_to_requeue : *std.Io.Queue(usize),
) void {
    std.log.debug("\tLooking for H.264 encoder...", .{});

    //Small convenience setup step... ffmpeg has noisy logging. This suppresses that.
    c.av_log_set_level(c.AV_LOG_QUIET);

    // Step 1: Find the H.264 encoder
    const maybe_encoder = c.avcodec_find_encoder(c.AV_CODEC_ID_H264);
    const encoder : *const c.struct_AVCodec = if (null != maybe_encoder) @ptrCast(@alignCast(maybe_encoder)) else {
        //Error... closing comms with camera to shut that down and exiting thread
        frames_to_requeue.close(io);
        return;
    };

    // Step 2: Set up the encoder context
    var enc_ctx : *c.struct_AVCodecContext = set_encoder_context(encoder) orelse {
        //Error... closing comms with camera to shut that down and exiting thread
        frames_to_requeue.close(io);
        return;
    };
    defer c.avcodec_free_context(@ptrCast(&enc_ctx));

    // Step 3: Open the encoder (verify paramters don't cause issues)
    if (c.avcodec_open2(@ptrCast(enc_ctx), encoder, null) < 0) {
        //Error... closing comms with camera to shut that down and exiting thread
        frames_to_requeue.close(io);
        return;
    }

    while (true) {
        const duration = config.get_config_video_duration(); // 10 minutes
        const file_name_window =
            time.get_windowed_time_for_filename_string(allocator, io, duration)
            catch {
                break;
            };
        defer allocator.free(file_name_window);

        var file_name_buffer : [64]u8 = undefined;
        const file_name = std.fmt.bufPrintSentinel(&file_name_buffer, "{s}.ts", .{file_name_window}, 0) catch {
            break;
        };

        var buffer_for_dir_only_path : [128]u8 = undefined;
        const dir_only_path = sys.get_to_archive_path(&buffer_for_dir_only_path) catch {
            break;
        };
        var buffer_full_path_with_file_name : [256]u8 = undefined;
        const full_path_with_file_name = std.fmt.bufPrintSentinel(
            &buffer_full_path_with_file_name,
            "{s}{c}.{s}",
            .{
                dir_only_path,
                std.fs.path.sep,
                file_name,
            },
            0,
        ) catch {
            break;
        };

        create_video(
            io, 
            enc_ctx, 
            full_path_with_file_name,
            frames_to_encode,
            frames_to_requeue,
            frame_data,
        ) catch break;
    }

    std.log.debug("Encoding thread was ended due to encountering an error...", .{});
    frames_to_requeue.close(io);
}


//##############################################################################
// Function: set_encoder_context
//
// Description: Sets up the encoder context with desired parameters. Hard coded
//             for 640x480 YUV420P at 30fps for now - will make configurable
//             later.
//##############################################################################
fn set_encoder_context(encoder: *const c.struct_AVCodec) ?*c.struct_AVCodecContext {
    var enc_ctx : *c.struct_AVCodecContext = c.avcodec_alloc_context3(@ptrCast(encoder)) orelse {
        return null;
    };

    const fps = config.get_camera_frame_rate();

    // ------ Encoder parameters ------
    enc_ctx.width = config.get_camera_width();
    enc_ctx.height = config.get_camera_height();
    enc_ctx.time_base = .{ .num = 1, .den = (fps * 1_000) };
    enc_ctx.framerate = .{ .num = fps, .den = 1 };
    enc_ctx.pix_fmt = c.AV_PIX_FMT_YUV420P;
    enc_ctx.bit_rate = 0;
    enc_ctx.gop_size = fps;
    enc_ctx.max_b_frames = 0;
    enc_ctx.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER | c.AV_CODEC_FLAG_LOW_DELAY;

    //Buffer for getting crf value from config as string
    var crf_buffer: [4]u8 = undefined;
    const crf_str = std.fmt.bufPrintSentinel(&crf_buffer, "{d}", .{config.get_crf_value()}, 0) catch "25";

    // ultrafast + zerolatency = perfect for security cam
    _ = c.av_opt_set(enc_ctx.priv_data, "preset", "veryfast", 0);
    _ = c.av_opt_set(enc_ctx.priv_data, "tune",   "zerolatency", 0);
    _ = c.av_opt_set(enc_ctx.priv_data, "crf", crf_str, 0);

    return enc_ctx;
}


fn create_video(
    io : std.Io,
    encoder_ctx : *c.struct_AVCodecContext,
    file_name : [:0]const u8,
    queue_of_frames_to_encode: *std.Io.Queue(usize),
    queue_of_frames_to_requeue: *std.Io.Queue(usize),
    cached_frames : []camera.MemoryMappedFrame,
) !void {
    var nullable_output_fmt_ctx : ?*c.struct_AVFormatContext = null;
    if (c.avformat_alloc_output_context2(@ptrCast(&nullable_output_fmt_ctx), null, "mpegts", file_name) < 0) {
        return error.CannotCreateOutputContext;
    }
    const output_fmt_ctx = nullable_output_fmt_ctx orelse {
        return error.OutputContextIsNull;
    };
    defer c.avformat_free_context(@ptrCast(output_fmt_ctx));

    const stream : *c.struct_AVStream = c.avformat_new_stream(@ptrCast(output_fmt_ctx), null) orelse {
        return error.EncoderCouldNotSetOutputContext;
    };

    if (c.avcodec_parameters_from_context(@ptrCast(stream.codecpar), @ptrCast(encoder_ctx)) < 0) {
        return error.EncoderCouldNotSetOutputContext;
    }

    stream.time_base = encoder_ctx.time_base;

    // ------ Open file ------
    if (c.avio_open(@ptrCast(&output_fmt_ctx.pb), file_name, c.AVIO_FLAG_WRITE) < 0) {
        std.log.debug("Could not open output.mp4 for writing", .{});
        return;
    }
    defer _ = c.avio_closep(@ptrCast(&output_fmt_ctx.pb));

    // ------ Write file header ------
    if (c.avformat_write_header(@ptrCast(output_fmt_ctx), null) < 0) {
        std.log.debug("avformat_write_header failed", .{});
        return;
    }

    var starting_pts_us : ?i64 = null;

    // Reuse this for every frame (huge speedup)
    var sws_ctx: ?*c.struct_SwsContext = null;
    defer if (sws_ctx) |ctx| c.sws_freeContext(ctx);

    // Assume time is valid for one frame to ensure video is made.
    var still_in_relevant_time_window : bool = true;

    while (still_in_relevant_time_window) {
        defer {
            still_in_relevant_time_window = time.is_time_in_current_window(io, file_name) catch |err| blk: {
                std.log.debug("Error checking time window: {any}", .{err});
                break :blk false;
            };
        }

        const buffer_index = try queue_of_frames_to_encode.getOne(io);
        defer queue_of_frames_to_requeue.putOne(io, buffer_index) catch {
            queue_of_frames_to_requeue.close(io);
        };

        // ----- Raw YUYV frame -----
        var src_frame : *c.struct_AVFrame = c.av_frame_alloc() orelse { 
            //If we cannot get the frame for the encoder... let's continue and
            //try again.
            continue;
        };
        defer c.av_frame_free(@ptrCast(&src_frame));

        src_frame.format = c.AV_PIX_FMT_YUYV422;
        src_frame.width  = config.get_camera_width();
        src_frame.height = config.get_camera_height();
        if (c.av_frame_get_buffer(@ptrCast(src_frame), 0) < 0) {
            continue;
        }

        const yuyv_ptr: [*c]const u8 = @ptrCast(cached_frames[buffer_index].start_address);
        const yuyv_len = cached_frames[buffer_index].bytes_used;
        @memcpy(src_frame.data[0], yuyv_ptr[0..yuyv_len]);
        src_frame.linesize[0] = config.get_camera_width() * 2;

        // ----- Convert to YUV420P -----
        var dst_frame : *c.struct_AVFrame = c.av_frame_alloc() orelse {
            continue; 
        };
        defer c.av_frame_free(@ptrCast(&dst_frame));

        dst_frame.format = c.AV_PIX_FMT_YUV420P;
        dst_frame.width  = config.get_camera_width();
        dst_frame.height = config.get_camera_height();
        if (c.av_frame_get_buffer(@ptrCast(dst_frame), 0) < 0) {
            continue;
        }

        // Create sws context once
        if (sws_ctx == null) {
            sws_ctx = c.sws_getContext(
                config.get_camera_width(), config.get_camera_height(), c.AV_PIX_FMT_YUYV422,
                config.get_camera_width(), config.get_camera_height(), c.AV_PIX_FMT_YUV420P,
                c.SWS_BILINEAR, null, null, null,
            );
        }

        // THIS IS THE ONLY CORRECT WAY IN ZIG
        _ = c.sws_scale(sws_ctx,
            @ptrCast(&src_frame.data),
            @ptrCast(&src_frame.linesize),
            0, config.get_camera_height(),
            @ptrCast(&dst_frame.data),
            @ptrCast(&dst_frame.linesize));

        const pts_us : i64 =
            cached_frames[buffer_index].time_stamp.tv_sec * 1_000_000 +
            cached_frames[buffer_index].time_stamp.tv_usec;
        if (null == starting_pts_us) {
            starting_pts_us = pts_us;
        }

        const fps = config.get_camera_frame_rate();
        dst_frame.pts = @intCast(@divFloor(((pts_us - starting_pts_us.?) * (fps * 1_000)), 1_000_000));

        // ----- Encode -----
        _ = c.avcodec_send_frame(@ptrCast(encoder_ctx), @ptrCast(dst_frame));

        var pkt: c.AVPacket = undefined;
        c.av_init_packet(&pkt);

        while (true) {
            const ret = c.avcodec_receive_packet(@ptrCast(encoder_ctx), &pkt);
            if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF) break;
            if (ret < 0) break;

            pkt.stream_index = 0;
            // rescale to stream time base (already the same, but safe)
            pkt.pts = c.av_rescale_q_rnd(pkt.pts, encoder_ctx.time_base, stream.time_base, c.AV_ROUND_NEAR_INF);
            pkt.dts = pkt.pts;
            //pkt.duration = c.av_rescale_q(1, enc_ctx.time_base, stream.time_base);
            pkt.duration = 0;

            _ = c.av_interleaved_write_frame(@ptrCast(output_fmt_ctx), &pkt);
            c.av_packet_unref(&pkt);
        }
    }

    // ----- Finalise file -----
    _ = c.av_write_trailer(@ptrCast(output_fmt_ctx));
    const beginning, const end = std.mem.cut(u8, file_name, ".") orelse {
        return error.CouldNotRenameFile;
    };
    var buffer_for_stripping_hidden_file : [512]u8 = undefined;
    const not_hidden_file_path = std.fmt.bufPrint(
        &buffer_for_stripping_hidden_file,
        "{s}{s}",
        .{
            beginning,
            end,
        }
    ) catch |err| {
        std.debug.print("Exiting encoding thread due to renaming issues: {any}\n", .{ err });
        return error.CouldNotRenameFile;
    };
    std.Io.Dir.rename(
        .cwd(),
        file_name,
        .cwd(),
        not_hidden_file_path,
        io,
    ) catch |err| {
        std.debug.print("Exiting encoding thread due to renaming issues: {any}\n", .{ err });
        return error.CouldNotRenameFile;
    };
    std.log.debug("Finished – output.mp4 is ready and playable!", .{});
}
