pub const c = @cImport({
    @cInclude("errno.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("linux/videodev2.h");
    @cInclude("string.h");
    @cInclude("sys/ioctl.h");
});
