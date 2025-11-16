const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/opt.h");
});

pub fn encoding_thread() void {
    std.debug.print("Thread for encoding stared...\n", .{});

    const fmt_ctx = get_format_context("output.mp4");
    _ = &fmt_ctx;
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
