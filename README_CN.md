# BiliVideoFPS120 0.1.8 CoreVFPSProbe

这一版继续保持 0.1.7 的“安全探针”原则，不 Hook 视频渲染函数。

## 新增

直接读取 IJK 核心内部统计：

- `FFP_PROP_FLOAT_VIDEO_OUTPUT_FRAMES_PER_SECOND` (10002) → 实际送入视频输出链的 FPS
- `FFP_PROP_FLOAT_VIDEO_DECODE_FRAMES_PER_SECOND` (10001) → 解码 FPS（写日志）
- `FFP_PROP_FLOAT_PLAYBACK_RATE` (10003) → IJK 核心实际倍速

实现方式：从 `IJKFFMoviePlayerController` 的 `_mediaPlayer` ivar 取得 IjkMediaPlayer 指针，再调用已经加载的 `ijkmp_get_property_float`。不会动态 Hook `display_pixels:` / EAGL / Metal / SampleBuffer。

优先显示：

```
VID 59.8 CORE | SRC 60 | 1.0x
VID 118.4 CORE | SRC 60 | 2.0x
```

如果核心符号不可解析，会自动退回 0.1.7 的 `view.fps` / `fpsAtOutput`。

## 测试重点

找明确 60fps 视频：

- 1×：记录 VID / SRC
- 2×：记录 VID / SRC

若 `SRC 60 + 2.0x` 时 `VID ≈ 115~120 CORE`，说明 IJK 已经完整输出约 120 个源帧/秒。
若仍 `VID ≈ 60 CORE`，再进入 video_refresh / 丢帧逻辑修改阶段。

日志仍在 B站数据容器 `Documents/BiliVideoFPS120.log`。
