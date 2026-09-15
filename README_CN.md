# BiliVideoFPS120 0.1.3 — EAGL Present Probe

本版用于解决 0.1.2 中 `VID --` 且 `/var/mobile/Media/BiliVideoFPS120.log` 不存在的问题。

## 关键变化

- 不再依赖 `IJKSDLGLView -display:` 才能统计视频帧。
- 新增对系统 `EAGLContext -presentRenderbuffer:` 的进程内 Hook。老版 ijkplayer 每真正提交一帧 OpenGL 视频时都会调用这里，因此它可以绕过 B站私有/改名 IJK 类。
- `IJKSDLGLView -display:` 仍保留为辅助计数器。
- 日志改写入 Bilibili 自己的沙盒 Documents，避免 App Sandbox 拒绝写 `/var/mobile/Media/`。
- 未检测到帧时，浮层显示 `VID -- | E1 I0 | 1.0x`：`E1` 表示 EAGL present hook 已安装；`I1` 表示 IJKSDLGLView display hook 已安装。
- 运行时 IJK Hook 重试窗口从约 20 秒延长到约 60 秒。

## 日志位置

Filza → 应用管理器 → Bilibili → 数据容器 → Documents → `BiliVideoFPS120.log`

物理路径会是：

`/var/mobile/Containers/Data/Application/<Bilibili UUID>/Documents/BiliVideoFPS120.log`

UUID 每次重装 App 都可能改变。

## 测试

找一个明确的 60fps 视频，依次测试 1x / 2x / 3x。

如果 1x ≈60、2x ≈120，说明 IJK 本身已能在 2x 时完整输出 120 个源帧/秒。
如果 1x ≈60、2x 仍≈60，则下一步需要修改 IJK 的视频调度/丢帧逻辑。

如果仍显示 `VID --`，请同时记录 `E?/I?` 两个状态，并把 Bilibili Documents 里的日志发回。
