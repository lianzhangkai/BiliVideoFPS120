# BiliVideoFPS120 0.1.5 — ThirdGLView Probe

针对 0.1.3 日志已经确认的情况：

- `IJKFFMoviePlayerController` 确实是当前播放器；
- `setPlaybackRate:` 能抓到 1×/3×；
- B站把 IJK `max-fps` 设为 60，插件已改为 120；
- 但标准 `IJKSDLGLView -display:` 与 `EAGLContext -presentRenderbuffer:` 都没有帧。

这强烈说明当前 B站版本使用了 IJK 的 **第三方 GL View** 通道。公开的 IJK 接口 `IJKSDLGLViewProtocol` 对第三方渲染器定义的是 `-display_pixels:`，而 `IJKFFMoviePlayerController` 也提供 `initWithMoreContent...withGLView:` 来注入第三方 View。

## 0.1.5 新增

1. 在 `prepareToPlay/play/setPlaybackRate:` 时直接读取当前 IJK player 的 `view`。
2. 记录实际渲染 View 的类名、Layer 类型、`isThirdGLView`。
3. **动态 Hook 实际 View 类的 `display_pixels:`**，统计 IJK 向第三方渲染器提交的真实视频帧数。
4. 如果该 View 自己实现 `fps`，也作为备用输出 FPS（显示后缀 `VFP`）。
5. `SRC` 除 `fpsInMeta` 外，再使用 `IJKFFMonitor.fps` 回退，解决部分 fork 中 SRC 一直 `--`。
6. 保留 `max-fps 60 -> 120`、SampleBuffer / EAGL / Metal 多后端探测、B站 UI 60→120 CADisplayLink 提升。

## 显示

优先命中第三方渲染通道时：

```
VID 59.8 PIX | SRC 60 | 1.0x
VID 118.6 PIX | SRC 60 | 2.0x
```

`PIX` = IJK `display_pixels:` 的提交频率。

如果只拿到渲染 View 自带的 fps：

```
VID 59.8 VFP | SRC 60 | 1.0x
```

仍未命中时会显示：

```
VID -- | H P1 T1 E1 I1 S1 M1 | 1.0x
```

其中 `T1` 表示实际播放器 View 的 `display_pixels:` Hook 已安装。

日志：B站沙盒 `Documents/BiliVideoFPS120.log`。

## 编译

```bash
make clean package FINALPACKAGE=1 messages=yes
```
