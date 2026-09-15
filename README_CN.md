# BiliVideoFPS120 0.1.0 — 实际视频 FPS 探针 + 安全 120fps 上限放宽

目标设备：iPad Pro 2018 / iPadOS 13.7 / Odyssey-libhooker / arm64e。

## 这一版做什么

1. 实时读取 ijkplayer 自己的 `fpsInMeta` 和 `fpsAtOutput`：
   - `SRC` = 视频源标称 FPS；
   - `VID` = IJKSDLGLView 实际输出/提交 FPS；
   - 同时显示当前 `playbackRate`。
2. 状态栏约 3/5 位置显示：`VID 59.9 | SRC 60 | 2.0x`，避免和 GlobalFPSOverlay 0.2.0（4/5位置）重叠。
3. 在 ProMotion 120Hz 设备上把 ijkplayer 的 `max-fps` 安全提升到 120，避免 60fps 源视频因为旧的 30/60fps 上限被提前丢帧。
4. 将 B站内部显式请求 60fps 的 `CADisplayLink` 提升到 120（主要针对 UI/弹幕）。
5. **不强制 framedrop=0**。3×播放 60fps 视频理论需要 180帧/秒，120Hz 屏幕不可能完整显示，播放器仍需要正常丢掉来不及显示的帧。

## 最重要的测试

找一个确定为 60fps 的 B站视频：

- 1× 播放 15 秒，记录 `VID / SRC`；
- 2× 播放 20 秒，记录 `VID / SRC`；
- 长按 3× 播放 15 秒，记录 `VID / SRC`。

### 结果怎么解释

- `SRC≈60，1× VID≈60，2× VID≈115~120`：已经实现“60fps源 × 2 = 真120fps输出”，无需继续改视频调度器。
- `SRC≈60，2× VID仍≈60`：倍速时 IJK 在视频时钟/late-frame 路径丢了一半帧，下一版要针对 video refresh / framedrop 做动态策略。
- `SRC≈60，3× VID≈115~120`：正常且已经接近屏幕上限；3×不可能完整显示180个不同源帧。
- `SRC≈30，2× VID≈60`：同样是正常的真2×完整帧输出。

日志：`/var/mobile/Media/BiliVideoFPS120.log`

## 和现有插件的关系

- 可和 `GlobalTimePitchFix 0.8.0` 共存；本插件不改音频 PCM/DSP。
- 可和 `GlobalFPSOverlay 0.2.0` 共存；GlobalFPSOverlay显示 App/UI DisplayLink FPS，本插件显示 IJK 实际视频输出 FPS。
- 如果之前装过独立的 `Bili120HzUnlock` 实验包，建议先卸载它，避免重复 hook `CADisplayLink`。

## 编译

仓库根目录运行 GitHub Actions，或：

```bash
make clean package FINALPACKAGE=1 messages=yes
```
