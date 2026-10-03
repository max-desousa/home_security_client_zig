# SBC performance roadmap

Reference document for turning this Zig client into software that can keep recording on a budget single-board computer (Raspberry Pi Zero 2 W, Pi 3, Pi 4, and the Pi 5 as a special case).

This is an assessment and a build order. Approving the plan does one thing: copy this document into the repo as `docs/sbc-performance-roadmap.md`. It does not change the camera, encoder, or any other source file.

Each section labeled **Branch** is meant to be one feature branch you implement and measure yourself. They are ordered so each one stays understandable, and so a later branch is not fighting a bug from an earlier one.

---

## What the program actually does

On a machine with 8 or more cores at **compile** time, `build.zig` selects `src/core_layouts/perfect_core_layout.zig`. That process starts four concurrent loops:

1. **Capture** (`src/camera/root_camera.zig`, `infinite_capture`). Opens the V4L2 device (default `/dev/video0`) non-blocking, asks for 32 memory-mapped buffers, forces YUYV at the configured size and frame rate (default 640×480 @ 30 fps), and dequeues frames as fast as the device will give them.
2. **Encode** (`src/encoding/root_encoding.zig`). Software H.264 through libx264 (`AV_CODEC_ID_H264`), preset `veryfast`, tune `zerolatency`, CRF from config (default 25). Every frame is copied out of the mmap buffer, converted YUYV → YUV420P with libswscale (`SWS_BILINEAR`), then encoded into a short MPEG-TS segment (default 15 seconds) under `Videos/ToArchive/<camera>/`.
3. **Upload** (`src/net/root_net.zig`). Walks that folder and HTTP POSTs finished segments to `ip:port`, then moves them to `Videos/Archived/`.
4. **Cleanup** (`src/sys/root_sys.zig`). Tries to keep total video bytes under `amount of memory for local storage` (default 10_000_000, about 10 MB).

`single_core_layout.zig` and `restricted_core_layout.zig` are stubs. They call `camera.init()` with no arguments, so a build that selects them does not compile. `build.zig` chooses the layout from `std.Thread.getCpuCount()` on the **build machine**, unless you pass `-Dnumber_of_cores=N`. A desktop with 8+ cores therefore builds the only working layout. A Pi 4 (4 cores) or a Pi Zero (1 core), building on itself, selects a stub.

`src/sys/root_sys.zig` also has `const flags = @import("flags");` and nothing in `build.zig` provides that module. Worth confirming with a clean `zig build` before measuring anything. If it fails, fixing that import is part of Branch A, not a performance experiment.

---

## The mental model: you have a frame budget

A camera produces frames on a clock. The software must finish a frame, on average, before the next one is due. Otherwise it falls behind forever, or it has to drop frames on purpose.

| Frame rate | Budget for capture + convert + encode |
| --- | --- |
| 30 fps | 33 ms |
| 15 fps | 66 ms |
| 10 fps | 100 ms |
| 5 fps | 200 ms |

That budget is **CPU time on the cores you actually give the encoder**, and it has to hold after the SoC has warmed up. A Pi in a case will thermal-throttle. A number you measure in the first 30 seconds is not the number you get at minute 20.

Where the time goes in **this** code, per frame, on the current path:

1. **Wait for the camera.** Implemented as a spin: non-blocking `DQBUF`, and on `EAGAIN` the capture loop `continue`s with no `poll` and no sleep (`capture_single_frame`). An idle camera still burns a whole core.
2. **Two fresh `AVFrame` allocations and a full-frame `memcpy`.** YUYV is already in an mmap buffer. The encoder allocates a new source frame, copies every byte in, allocates a new destination frame, then frees both. See the body of the `while (still_in_relevant_time_window)` loop in `create_video`.
3. **Colorspace conversion.** `sws_scale` YUYV → YUV420P, bilinear. This reads and writes the whole frame again. It exists because the camera format is hardcoded to `V4L2_PIX_FMT_YUYV` and the encoder is hardcoded to `AV_PIX_FMT_YUV420P`.
4. **libx264.** Preset `veryfast` still does real motion search. `thread_count` is left at the x264 default, which sizes itself to the machine and then fights the capture, upload, and cleanup threads.
5. **Housekeeping on the same CPU and the same SD card.** Cleanup's `general_unprotected_strategy` / `general_protected_strategy` loop forever with no sleep: walk the tree, `open` + `stat` every file, duplicate the path strings, sort, maybe delete, repeat. Upload walks the tree every cycle and copies the file through 4 KB userspace buffers. Both steal time from the 33 ms budget and stall the encoder on SD-card metadata I/O.

RAM on the same path, at the defaults:

- One YUYV frame is `640 × 480 × 2 = 614_400` bytes (about 600 KB).
- 32 mmap buffers is about 20 MB held for the whole process lifetime. Four to six buffers is the usual amount; extra buffers only help if the encoder sometimes jitters and you are willing to add latency.
- 30 fps of YUYV is about **18 MB/s** across USB and memory. 720p YUYV at 30 fps is about **55 MB/s**, which is past what USB 2.0 on a Pi Zero / Pi 3 can do reliably (and on those boards USB is shared with Ethernet).
- x264's own working set at 640×480 is small. The per-frame alloc/free does not grow RAM forever (frames are freed), but it makes frame time spiky, which is how you miss the budget even when the average looks fine.

There is a second, separate budget: **the SD card**. A security camera writes continuously for months. The failure mode on a Pi is the card wearing out, or the root filesystem filling until the board no longer boots. CPU work that stats the whole tree in a tight loop spends that budget for free.

### What a budget board can honestly sustain

These are planning targets for **software** H.264 (the encoder this repo uses today), after the busy-loops are gone, with preset `ultrafast` and the extra copy removed. They are the bar to measure against, not a promise.

| Board | Realistic software-encode target | Why |
| --- | --- | --- |
| Pi Zero W (one ARM11 core) | 320×240 @ 5–10 fps, or don't software-encode | One core cannot do 640×480 YUYV convert + x264 at 30 fps. |
| Pi Zero 2 W / Pi 3 (four A53 cores, little RAM, USB 2.0) | 640×480 @ 10–15 fps | 30 fps YUYV plus swscale plus `veryfast` usually misses the 33 ms budget once thermals and Wi-Fi join in. |
| Pi 4 (four A72 cores) | 640×480 @ 30 fps, or 720p @ 15–30 fps if the camera is not feeding YUYV | Enough CPU for the current resolution if the rest of the process gets out of the way. 1080p30 software encode is the wrong goal. |
| Pi 5 | Software encode is the only H.264 option on the SoC | Much faster CPU. The Pi 5 has no H.264 hardware encoder. A V4L2-M2M branch that works on a Pi 4 does nothing useful here. |

The order-of-magnitude win, when the camera or the SoC already speaks H.264, is **not encoding at all** (Branch F). Past that, the wins are "stop burning cores when idle" and "stop touching every pixel twice."

---

## How you will know a branch worked

Build the binary you actually run in `ReleaseFast`. `Debug` turns on `std.heap.DebugAllocator` and the per-frame `debug.print` calls inside `capture_single_frame` (one of those runs on every successful dequeue). Those prints are stderr syscalls at frame rate. A Debug build on a Pi is a different program.

Before Branch B adds internal stats, this external recipe is enough:

- `top -H -p <pid>` for a minute. Capture should not sit at 100% of one core while waiting. Cleanup should not sit at 100% of another.
- Encode time versus the frame budget. If you only add one log line, make it "milliseconds spent in convert + `avcodec_send_frame` / `receive_packet` this frame."
- `v4l2-ctl --all` (or `VIDIOC_ENUM_FMT` logged once at startup) so you know which formats the camera offered.
- `/sys/class/thermal/thermal_zone0/temp` at the start and after 15 minutes.
- `iostat -x 5` or `/proc/diskstats` on the SD device while cleanup is "idle." Idle housekeeping should not be a stream of reads.

Keep a one-line note per branch: resolution, fps, preset, board, encode ms/frame, CPU, temperature. That note is the point of the project.

---

## Branch A — `feat/layout-matches-the-board`

**Depends on:** nothing. Do this first so the binary you measure is the binary a Pi will run.

**Why.** Performance work on `perfect_core_layout.zig` never reaches a Pi that builds locally, because 4 cores selects `restricted_core_layout.zig` and 1 core selects `single_core_layout.zig`. Both stubs call `camera.init()` incorrectly. Separately, `-Dnumber_of_cores` defaults to the compile machine's core count, so a cross-compile from an 8-core desktop silently ships the "perfect" layout to a 4-core Pi. The layout decision is a property of the device that captures video.

**What to change.**

- Make `-Dnumber_of_cores` required when `target` is not native, or default it from an explicit board flag you set yourself. The host CPU count is the wrong default whenever you cross-compile.
- Until Branches G and H exist, every layout should call the same working `main` as `perfect_core_layout.zig`. A stub that does not compile hides later measurements.
- Remove or satisfy `@import("flags")` in `src/sys/root_sys.zig`.
- Document the one command that builds `ReleaseFast` for the board you own, including the core count of that board.

**How you'll know it worked.** The same source tree builds on the Pi (or cross-compiles for it) and runs the capture/encode/upload/cleanup process. `zig build -Doptimize=ReleaseFast -Dnumber_of_cores=4` is the command you keep using for every later branch.

**Leave alone.** Thread pinning, x264 thread count, and a real single-core pipeline. Those are Branches G and H, once you have numbers.

---

## Branch B — `feat/one-line-frame-stats`

**Depends on:** A, so you are measuring the real process.

**Why.** The config file already has `[crash: poor cam performance]`, and nothing reads it. The capture path prints every frame in Debug and prints nothing useful in Release. Without a once-per-second picture of "are we inside the budget?", every later branch is a guess. This branch is also where you learn the vocabulary: produced frames, encoded frames, dropped frames, queue depth.

**What to change.**

- Read `v4l2_buffer.sequence` in `capture_single_frame`. A gap in the sequence is a frame the driver dropped because no buffer was queued. Log the gap count.
- Once per second, log: captured fps, encoded fps, last or average encode milliseconds, depth of `frames_to_encode`, sequence gaps, and process RSS if you can get it cheaply (`/proc/self/statm` is enough).
- Time the convert + encode section of `create_video`, not the time spent blocked waiting on the queue.
- Keep per-frame `debug.print` out of the steady state. Startup logs (chosen format, real frame rate, encoder name) are worth keeping.

**How you'll know it worked.** One log line per second while recording. You can point at it and say whether encode time is under the frame budget. The line itself should be too cheap to move that number (no allocation, no walk of the filesystem).

**Leave alone.** Changing fps, preset, or format in this branch. It is a measuring stick. If you change the pipeline in the same branch you will not know which edit moved the number.

---

## Branch C — `feat/stop-the-idle-spins`

**Depends on:** B, so you can see the CPU drop.

**Why.** This is the largest fix that does not change image quality.

- Capture opens the device with `O_NONBLOCK` and treats `EAGAIN` as "try again immediately." Between frames that loop is a busy-wait. On a four-core Pi that is 25% of the machine. On a one-core Pi it is the machine, and the encoder only runs in the gaps.
- `general_unprotected_strategy` and `general_protected_strategy` each contain `while (true)` with no sleep, and `file_cleanup_thread` wraps them in another `while (true)`. The inner loop never returns. Under the default 10 MB cap the body still re-walks, re-stats, and re-sorts every file as fast as the CPU and the SD card allow, even when nothing needs deleting.
- Upload always prints `Done printing list of detected files` through `std.debug.print`, which is on in every build, and it scans the tree before it sleeps. A configured delay of 0 is a second busy loop.

Blocking the capture thread costs no frames: the kernel wakes the thread when a buffer is ready. That is the normal V4L2 pattern (`poll`/`select` on the fd, or a blocking `DQBUF`). Cleanup and upload are not on the frame clock. Waking them every 30–60 seconds is plenty for a 15-second segment size.

**What to change.**

- Capture: block in `poll` until the fd is readable, then `DQBUF`. Keep the `EINTR` retry you already have in `xioctl`.
- Cleanup: one directory pass, then sleep (30–60 seconds is a good first constant, later a config field). Delete the nested infinite loop so a pass can finish and sleep.
- Upload: sleep when there is nothing to send. Remove the unconditional per-scan print.
- Do not hold a V4L2 buffer while sleeping. Buffers go back with `QBUF` as soon as you know you are done with the bytes.

**How you'll know it worked.** In `top -H`, capture sits near 0% between frames and near 0% averaged if the camera is the only waiter. Cleanup is absent from the CPU list most of the time. Encode ms/frame from Branch B stays the same or improves, because it stopped competing with two spin loops. Sequence gaps should not increase.

**Leave alone.** The cleanup policy (which file is deleted). This branch only changes how often the policy runs. Disk accounting is Branch I.

---

## Branch D — `feat/drop-late-frames`

**Depends on:** B and C. Dropping frames while capture is still spinning teaches you the wrong lesson. Measuring drops requires the sequence counter from B.

**Why.** The queues are 32 deep and the driver is asked for 32 buffers (`req.count = 32` in `initialize_mmap`). If x264 takes 50 ms and the camera delivers a frame every 33 ms, the queue grows until `putOne` blocks the capture thread. Capture then stops returning buffers to the driver. The process encodes old frames and never returns to "now." For a security camera, a skipped frame is a better outcome than a recording that is ten seconds behind the wall clock and using CPU on frames that are already late.

The unused `[crash: poor cam performance]` flag is the policy hook you already named. "Poor performance" means "the encoder cannot keep the frame budget," and the two honest responses are: drop frames and keep recording, or stop the process because the operator asked to be told.

**What to change.**

- Shrink the in-flight set. A queue depth of about 2–4, and about 4–6 V4L2 buffers, is enough to absorb one slow frame. Thirty-two buffers is about 20 MB and up to a second of latency at 30 fps before anything drops.
- If the encode queue is full, requeue that V4L2 buffer immediately and count a drop. Do not block capture on encode.
- If `crash: poor cam performance` is true and drops stay above a threshold you choose (for example, more than half the frames across 5 seconds), log a clear line and exit. If it is false, keep recording and keep counting.
- Log drops in the once-per-second stats line.

**How you'll know it worked.** Force the budget to be impossible (640×480 @ 30, preset left at `veryfast`, on the smallest board you have). Capture fps stays at the camera rate, encode fps sits at whatever the CPU can finish, queue depth stays at the cap, and the segment's timestamps keep moving with the wall clock. RSS is lower by roughly the buffers you gave back.

**Leave alone.** Making the encoder faster. That is E and F. This branch is the safety valve those branches need while you experiment.

---

## Branch E — `feat/cheaper-pixels-and-a-reused-encoder`

**Depends on:** B, C, D. This is the software-encode performance branch. Do it as one branch only if you measure in two commits (format first, then allocation reuse). If you want them as two feature branches, split on the headings below. They touch the same loop, so landing them separately is cleaner for you and slightly more merge work.

### E1. Ask the camera for a cheaper format

**Why.** `configure_device` always sets `V4L2_PIX_FMT_YUYV`. YUYV is 16 bits per pixel, uncompressed, and it is not what x264 wants (x264 wants YUV420P). Every frame therefore takes a full copy and a bilinear `sws_scale`. Many UVC webcams will instead deliver MJPEG for the same resolution at a fraction of the USB bytes, or NV12 / YUV420 which the encoder can take with no RGB-style conversion. USB bytes matter on a Pi because the bus is slow and, on older boards, shared with the network. Memory bandwidth matters because the encode is already memory-heavy.

Preference order to log and then select:

1. H.264 or MJPEG from the camera. Selection only in this branch: record that it is available. Actually passing those bytes through without decode is Branch F, so you do not mix "stop encoding" into the same change as "encode cheaper raw frames."
2. NV12 or YUV420, same resolution. Point the encoder at it and skip `sws_scale`.
3. YUYV, which is today's path, used when the camera offers nothing else.

Also log `bytesperline`. V4L2 lines are often wider than `width * bytes_per_pixel` because of alignment. A converter that assumes packed rows will look "slow" and also wrong.

Use `VIDIOC_ENUM_FMT`, `VIDIOC_ENUM_FRAMESIZES`, and `VIDIOC_ENUM_FRAMEINTERVALS` once at startup and print the list. That printout is a reference you will use for every camera you plug in.

**How you'll know it worked.** Stats line shows lower encode ms/frame, and USB/CPU idle time goes up, at the same resolution and fps. If the camera only offers YUYV, the log says so and the numbers stay put. That is a successful result: you learned the camera is the limit, and Branch E2 plus a lower fps is the remaining software lever.

### E2. Stop allocating and copying every frame

**Why.** Inside the per-frame loop, `create_video` calls `av_frame_alloc` and `av_frame_get_buffer` twice, `memcpy`s the whole YUYV frame, and `av_init_packet`s a stack packet. The swscale context is already reused; the frames are not. `malloc` at frame rate on a small core makes frame time jumpy, and the copy is a third trip over a 600 KB buffer (camera writes it, memcpy reads and writes it, swscale reads it).

**What to change.**

- Allocate the source frame, destination frame, and packet once per segment (or once per process) and reuse them.
- Feed swscale from the mmap pointer. Honor `bytesperline`. Drop the memcpy when the converter can take the pointer directly.
- If E1 found NV12 or YUV420, skip swscale and hand that pointer to the encoder. Check that the encoder is finished with the frame before you `QBUF` the buffer back to the driver. `avcodec_send_frame` can retain the frame until you drain packets.
- Replace the ignored return of `avcodec_send_frame` with the normal drain loop: receive available packets, then send, and receive again. A discarded `EAGAIN` is how an encoder stalls while the queue logic swears it is keeping up.
- `SWS_FAST_BILINEAR` (or `SWS_POINT`) is the scaler flag that matches a security camera. `SWS_BILINEAR` spends quality you will not see at CRF 25.
- Set x264 `threads` explicitly to 1 on a one- or two-core target and to 2 on a four-core target. Leave one core for capture, the kernel, and the network. The preset comment in `set_encoder_context` already says ultrafast; the code sets `veryfast`. For this branch, default the Pi-oriented preset to `ultrafast`, keep CRF configurable, and add the preset to `config.zap` so you can A/B it without a rebuild.
- Default the checked-in frame rate for a budget board to 15, not 30. Thirty remains available in the config. The frame budget table is why.

**How you'll know it worked.** Encode ms/frame drops, and the once-per-second line gets less spiky (max close to average). Sequence gaps and intentional drops from Branch D go down at the same resolution. RSS stays flat over an hour (reuse means you did not introduce a leak).

**Leave alone.** Hardware encoders, motion detection, and upload tuning.

---

## Branch F — `feat/passthrough-or-hardware-encode`

**Depends on:** E1's format probe, plus D so a bad encoder setting drops frames instead of wedging capture. Split this into two branches if you want smaller reviews. They are independent of each other.

### F1. `feat/h264-passthrough` — the camera already compressed the frame

**Why.** A lot of "USB security cameras" expose an H.264 (or MJPEG) stream over UVC. Today's code asks them for YUYV anyway, which forces the camera to decode its own stream and the Pi to encode it again. Copying the already-compressed buffer into the segment file is a small memory write. It is the difference between one core pegged and the board mostly idle, which is what leaves headroom for Wi-Fi and for staying cool inside a case.

**What to change.**

- When the negotiated format is H.264, skip libx264 and swscale. Write the V4L2 payload as the bitstream (MPEG-TS or MP4, whichever you can produce correctly from Annex-B or length-prefixed NAL units — this is the part to study, not a one-line call).
- Keep the segment rotation and the hidden-file-until-finished rename. Those are the right shape for crash safety.
- When the format is MJPEG, a first version can store MJPEG as the segment. Re-encoding MJPEG to H.264 on the Pi spends the CPU you just got back. Treat "transcode MJPEG" as a later, separate choice.

**How you'll know it worked.** CPU of the encode thread collapses, temperature stays near idle, and a desktop player opens the segment. If your camera has no compressed format, this branch's startup log says "passthrough unavailable" and the E path still runs. Ship that log. It is the feature, on cameras that cannot do this.

### F2. `feat/v4l2m2m-encode` — the Pi's own H.264 block

**Why.** Pi Zero 2, Pi 3, and Pi 4 have a hardware H.264 encoder exposed as a V4L2 memory-to-memory device. FFmpeg's encoder name is `h264_v4l2m2m`. Frames still have to be in a format the block accepts (typically NV12/YUV420), which is why E1 comes first, but the motion search leaves the CPU. The Pi 5 removed that block. On a Pi 5 this branch should detect "no m2m encoder" and keep the software path from E. Write that down in the startup log so a future you does not debug a missing `/dev/video11` on the wrong board.

**What to change.**

- Select `h264_v4l2m2m` when the device node exists and opens, otherwise keep libx264.
- One encode thread. The hardware block is the parallelism.
- Same segment writer, same drop policy.

**How you'll know it worked.** On a Pi 4, encode ms/frame falls well under the budget at a resolution software encode could not hold (try 720p @ 30, or 1080p @ 15, and watch thermals). On a Pi 5, the log says the software encoder is in use and behavior matches Branch E.

**Leave alone.** libcamera / the official CSI camera. That is a different capture API (`libcamera` rather than opening `/dev/video0` and issuing `VIDIOC_S_FMT` yourself). It deserves its own branch after USB UVC is solid, because the concepts (buffer lifetime, pixel format, who encodes) are the same and the API is not.

---

## Branch G — `feat/upload-and-cleanup-stay-off-the-frame-clock`

**Depends on:** C (sleeps exist) and D (you can see when the encoder is behind). Can be written in parallel with E if you stay out of `create_video`.

**Why.** Once capture and cleanup stop spinning, the remaining damage is I/O at the wrong time.

- Upload builds a new `std.http.Client` per file and copies the file 4 KB at a time through userspace (`write_raw_file_content_bytes_to_stream`). During that copy the CPU and the SD card are busy, so encode times spike and Branch D starts dropping frames. Wi-Fi on a small Pi makes this worse because the network softirq runs on the same cores.
- Cleanup measures disk use by walking every file and `stat`ing it, then allocates a duplicated path and name per file, on every pass. The default cap is 10 MB. One or two segments fill it, so the next pass deletes the oldest names. The policy is fine to keep; the measurement is what hurts. A full root filesystem on a Pi is also a failure mode the byte counter of `Videos/` does not see, because the OS, logs, and apt live on the same card.

**What to change.**

- Keep a running byte total: add a file's size when the encoder finishes the rename, subtract it when cleanup deletes or upload moves it. Walk the tree only at startup to seed the total.
- Before deleting, look at filesystem free space (`statvfs`) and start deleting early enough that the root filesystem keeps a reserve (a few hundred MB). The config value remains the video budget; the reserve is "the OS must still boot."
- Upload one finished segment at a time, with a larger buffer (64–256 KB) or `sendfile` if you want to learn that syscall. Reuse one HTTP client.
- Skip or pause upload while the encode queue is non-empty or encode ms/frame is over budget. A segment that is already on disk can wait 30 seconds. A frame cannot.
- Set a lower scheduling priority on the upload and cleanup threads than on capture and encode (`nice`, or `IOPRIO_CLASS_IDLE` for the disk work). The frame budget is the high-priority job.
- `fsync` the segment once, after the trailer is written and before the rename, if you want power-loss to cost at most one segment. Do not `fsync` per frame. The hidden-name-until-rename pattern you have is the right idea; keep it.

**How you'll know it worked.** Start an upload of a large file and watch the Branch B line. Encode ms/frame and drop count should barely move. `iostat` is quiet between cleanup wakes. Filling the disk stops deleting while there is still free space for the OS.

**Leave alone.** The meaning of GeneralUnprotected vs GeneralProtected. Those are product choices you already wrote down in `FileCleanupStrategy`. This branch makes them cheap to enforce.

---

## Branch H — `feat/single-core-pipeline`

**Depends on:** C, D, E. This is the branch that makes `single_core_layout.zig` a real design. Skip it if the board you own has four cores and E already meets the budget; come back when you aim at a Pi Zero.

**Why.** Four threads on one core, even after the spins are gone, still context-switch inside the frame budget. x264 with `threads > 1` on one core is slower than `threads = 1`. The layout files exist because you already noticed core count changes the shape of the program. The single-core shape is: one loop that blocks for a frame and encodes it, and housekeeping that runs after a segment is finished, not during the frame.

**What to change.**

- For `-Dnumber_of_cores=1`: one thread does blocking capture + encode. After a segment is renamed, that thread may upload or clean for a bounded time, or a second thread may do it at idle priority. x264 `threads = 1`.
- For 2–7 cores: pin encode to one core, capture to another (capture will mostly sleep), and leave upload/cleanup on whatever remains. x264 `threads` at 1 or 2, not "all cores."
- Keep the drop policy. A single core that misses the budget must drop, not grow a queue.

**How you'll know it worked.** On a one-core target, encode ms/frame is lower than the four-thread build of the same settings, and the once-per-second line shows housekeeping running between segments rather than inside them.

---

## Branch I — `feat/backoff-when-hot-or-late`

**Depends on:** B, D, E. Optional, and the one that makes it feel like an appliance.

**Why.** A fixed `config.zap` that meets the budget at boot will miss it after the SoC hits its thermal limit. Pis do this inside any closed case. The response that keeps recording is to step down one rung and stay there until the stats recover: 30 → 15 fps, then `veryfast` → `ultrafast` if you have not already, then a smaller resolution. Step back up only after a long cool period, or you will oscillate.

**What to change.**

- Read the thermal zone and the Branch B encode time.
- One rung at a time, with a cooldown of several minutes.
- Log the rung change on the stats line.

**How you'll know it worked.** Under a warm box, the process stays up, drop rate returns to near zero on the lower rung, and the log shows the transition. You do not need a perfect controller. You need "it still records."

---

## Branch J — `feat/record-when-the-picture-changes`

**Depends on:** E (you need a cheap luma plane, not a second full decode) and D. This is a behavior change, so keep it last among the performance branches.

**Why.** A hallway camera's picture is still almost all the time. Encoding those frames spends the whole frame budget to write bytes nobody will watch. A coarse luma downsample (for example 80×60) and a pixel-difference against the previous sample is cheap compared with x264. When the difference stays under a threshold, drop the frame the same way Branch D drops a late frame, and keep a keyframe every few seconds so a viewer can still see that the stream was alive.

Do this after the pipeline can already sustain your target fps. A motion check on top of an encoder that is already late just adds work.

**What to change.**

- A config threshold and a "maximum seconds between stored frames" so a static scene still gets a heartbeat frame.
- Use the drop path from Branch D so buffer lifetime stays correct.
- Log "skipped as still" separately from "skipped as late" on the stats line. Those are different bugs when the count looks wrong.

**How you'll know it worked.** Point the camera at a still wall. Encode fps falls, CPU and disk writes fall, and a person walking through brings encode fps back up within a segment. Point it at trees in wind. If it never skips, the threshold is too sensitive and you have learned something about the scene. That is the branch working as a learning exercise.

---

## Suggested order

| Order | Branch | Kind of win |
| --- | --- | --- |
| 1 | A `feat/layout-matches-the-board` | You are measuring the binary a Pi runs |
| 2 | B `feat/one-line-frame-stats` | A number to judge every later branch |
| 3 | C `feat/stop-the-idle-spins` | Gives cores and the SD card back without touching pixels |
| 4 | D `feat/drop-late-frames` | Stays on "now" when the CPU cannot keep up |
| 5 | E `feat/cheaper-pixels-and-a-reused-encoder` | Makes software H.264 fit the frame budget |
| 6 | F1 or F2 | Skips software H.264 when the camera or the Pi 4 already has it |
| 7 | G `feat/upload-and-cleanup-stay-off-the-frame-clock` | Upload and disk accounting stop causing drops |
| 8 | H `feat/single-core-pipeline` | Only if the target has one core |
| 9 | I `feat/backoff-when-hot-or-late` | Survives a warm case |
| 10 | J `feat/record-when-the-picture-changes` | Cuts work when the scene is still |

A through D are worth doing even if you later buy a faster board. E is the branch that teaches the cost of pixels. F is the branch that teaches where H.264 is supposed to run. G teaches why a camera process dies from the filesystem rather than from the codec. H through J are specializations.

## Things that look like performance work and are not, yet

- Hand-written SIMD for YUYV → YUV420. Format negotiation and skipping the convert beat a faster convert. Revisit only if E1 proves the camera is YUYV-only and E2's swscale is still the top of the profile.
- Replacing FFmpeg. The time is in preset, pixel format, thread count, and per-frame allocation, all of which you can change at the call site you already have.
- Motion detection before the pipeline meets the frame budget.
- A CSI / libcamera capture path before the UVC path is measured. Same lessons, a larger API.
- Tuning CRF for image quality. CRF 25 versus 28 changes bitrate and disk use. It does not change the "can this Pi keep up" question nearly as much as preset, resolution, and frame rate.

## What approving this plan does

Copy this document, unchanged in substance, to `docs/sbc-performance-roadmap.md` so it lives in the project tree. Do not start a feature branch and do not edit Zig sources as part of that step.
