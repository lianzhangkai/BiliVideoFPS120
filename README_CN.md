# BiliVideoFPS120 0.1.1 — LateLoad + 真视频帧提交计数

这是 0.1.0 的修正版。0.1.0 如果一直显示 `VID -- | SRC --`，最可能的原因是 B站把 ijkplayer 动态加载得较晚，Tweak 构造时 `IJKFFMoviePlayerController` 还不存在，固定 Logos hook 没挂上。

0.1.1 的改动：

- 不再假设 IJK 类在启动时已经存在；每 0.5 秒重试，最多约 20 秒。
- 直接 hook `IJKSDLGLView -display:`，只统计非 NULL overlay 的真实视频帧提交次数。因此即使 controller 的 `fpsAtOutput` 不可用，`VID` 也应该能显示。
- `SRC` 仍优先读取 `IJKFFMoviePlayerController -fpsInMeta`；如果这个 B站版本没有该接口，SRC 可能仍显示 `--`，但不影响最关键的 VID 实测。
- 保留 `max-fps=120` 的安全放宽。
- 保留 B站进程内 `CADisplayLink 60 -> 120` / `frameInterval 2 -> 1`。
- 日志会记录 IJK/KSY 候选类和 hook 状态，便于继续定位私有 fork。

## 测试重点

找一个明确 60fps 视频，分别看：

- 1x：VID 是否约 60
- 2x：VID 是约 60 还是约 120
- 3x：VID 上限预期不超过约 120

如果 `VID` 有数值而 `SRC` 还是 `--`，已经足够判断倍速时是否真的把源帧送满 120Hz。若 VID 仍为 `--`，把 `/var/mobile/Media/BiliVideoFPS120.log` 发回来，里面会列出实际加载的 IJK/KSY 类名。

## 编译

保持你现有 GitHub Actions 旧 arm64e 环境：

```bash
make clean package FINALPACKAGE=1 messages=yes
```

目标：iOS 13.0，SDK 13.7，arm64 + arm64e。
