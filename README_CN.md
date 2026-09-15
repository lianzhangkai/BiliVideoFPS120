# BiliVideoFPS120 0.1.7 SafeViewFPSProbe

这是 0.1.6 闪退后的安全诊断版。

## 关键变化

0.1.7 删除所有高风险渲染后端 Hook：

- 不 Hook `EAGLContext -presentRenderbuffer:`
- 不 Hook `CAMetalLayer -nextDrawable`
- 不 Hook `AVSampleBufferDisplayLayer -enqueueSampleBuffer:`
- 不 Hook `IJKSDLGLView -display:`
- 不动态 Hook 第三方 View 的 `display_pixels:`

只保留此前已验证不会导致闪退的：

- `IJKFFMoviePlayerController -prepareToPlay`
- `-play`
- `-setPlaybackRate:`
- `IJKFFOptions max-fps 60 -> 120`
- B站内 `CADisplayLink 60 -> 120`

## FPS 检测方式

每 0.5 秒直接读取：

1. `IJKFFMoviePlayerController.view`
2. `view.fps`
3. `IJKFFMoviePlayerController.fpsAtOutput`
4. `fpsInMeta` / `monitor.fps`

显示示例：

`VID 59.9 VIEW | SRC 60 | 1.0x`

如果 VIEW 没有值但 controller 有：

`VID 59.9 OUT | SRC 60 | 1.0x`

## 日志

B站数据容器的：

`Documents/BiliVideoFPS120.log`

会记录实际 `player.view` 的类名、layer 类名、是否实现 `fps` / `display_pixels:` / `display:`。

## 编译

```bash
make clean package FINALPACKAGE=1 messages=yes
```
