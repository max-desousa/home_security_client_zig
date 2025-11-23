const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/opt.h");
});

pub fn encoding_thread(io: std.Io) !void {
    std.debug.print("\tLooking for encoder...\n", .{});
    const encoder = try find_encoder();
    std.debug.print("\tEstablishing encoder context...\n", .{});
    var encoder_context = try create_encoder_context(encoder);
    defer c.avcodec_free_context(@ptrCast(&encoder_context));
    std.debug.print("\tCreating output context...\n", .{});
    var output_context = try create_output_context(encoder_context, encoder);
    defer c.avformat_free_context(output_context);

    if (0 > c.avcodec_open2(encoder_context, encoder, null)) {
        return error.CouldNotOpenCodec;
    }
    _ = c.avio_open(&output_context.pb, "output.mp4", c.AVIO_FLAG_WRITE);
    _ = c.avformat_write_header(output_context, null);

    const starting_time_stamp = try std.Io.Clock.now(std.Io.Clock.real, io);
    std.debug.print("Timestamp: {any}\n", .{starting_time_stamp});
    var current_time_stamp: std.Io.Timestamp = starting_time_stamp;
    var duration_in_seconds: i64 = 0;

    while (10 > duration_in_seconds) {
        current_time_stamp = try std.Io.Clock.now(std.Io.Clock.real, io);
        duration_in_seconds = std.Io.Timestamp.durationTo(starting_time_stamp, current_time_stamp).toSeconds();
    }

    _ = c.av_write_trailer(output_context);
    _ = c.avio_closep(&output_context.pb);
}

pub fn find_encoder() !*c.struct_AVCodec {
    const codec: ?*c.struct_AVCodec = c.avcodec_find_encoder(c.AV_CODEC_ID_H264);
    if (null == codec) {
        return error.CodecNotFound;
    }
    return codec.?;
}

pub fn create_encoder_context(codec: *c.struct_AVCodec) !*c.struct_AVCodecContext {
    const nullable_enc_context: ?*c.struct_AVCodecContext = c.avcodec_alloc_context3(codec);

    if (null == nullable_enc_context) {
        return error.EncoderContextNotCreated;
    }
    var encoder_context: *c.struct_AVCodecContext = nullable_enc_context.?;
    errdefer c.avcodec_free_context(&encoder_context);

    encoder_context.width = 640;
    encoder_context.height = 480;
    encoder_context.time_base = .{ .num = 1, .den = 30 };
    encoder_context.framerate = .{ .num = 30, .den = 1 };
    encoder_context.pix_fmt = c.AV_PIX_FMT_YUV420P;

    encoder_context.bit_rate = 4_000_000;
    encoder_context.gop_size = 30;
    encoder_context.max_b_frames = 2;

    if ((c.AV_CODEC_ID_H264 == codec.id) or
        (c.AV_CODEC_ID_HEVC == codec.id))
    {
        _ = c.av_opt_set(encoder_context.priv_data, "preset", "ultrafast", 0);
        _ = c.av_opt_set(encoder_context.priv_data, "tune", "zerolatency", 0);
    }

    return encoder_context;
}

pub fn create_output_context(encoder_context: *c.struct_AVCodecContext, codec: *c.struct_AVCodec) !*c.struct_AVFormatContext {
    var nullable_output_context: ?*c.struct_AVFormatContext = null;
    _ = c.avformat_alloc_output_context2(&nullable_output_context, null, null, "output.mp4");

    if (null == nullable_output_context) {
        return error.OutputContextCreationFailed;
    }

    const output_context: *c.struct_AVFormatContext = nullable_output_context.?;
    errdefer c.avformat_free_context(output_context);

    const nullable_stream: ?*c.struct_AVStream = c.avformat_new_stream(output_context, null);
    if (null == nullable_stream) {
        return error.VideoStreamCreationFailed;
    }
    var stream: *c.struct_AVStream = nullable_stream.?;
    stream.time_base = encoder_context.time_base;
    stream.codecpar.*.codec_id = codec.id;
    stream.codecpar.*.codec_type = c.AVMEDIA_TYPE_VIDEO;
    stream.codecpar.*.width = encoder_context.width;
    stream.codecpar.*.height = encoder_context.height;
    stream.codecpar.*.format = encoder_context.pix_fmt;
    stream.codecpar.*.bit_rate = encoder_context.bit_rate;

    return output_context;
}

fn get_format_context(file_name: []const u8) !*c.struct_AVFormatContext {
    var fmt_ctx: ?*c.struct_AVFormatContext = null;

    if (0 > c.avformat_alloc_output_context2(&fmt_ctx, null, null, file_name.ptr)) {
        std.debug.print("Failed to allocate output context\n", .{});
        return error.FailedToAllocateContext;
    } else {
        std.debug.print("FFMPEG output context successfully created\n", .{});
    }

    return fmt_ctx.?;
}

pub fn init_ffmpeg() void {
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
}
