# BiliVideoFPS120 0.1.9 HUDVFPSProbe

针对 0.1.8 中 `SRC` 和倍速正常、但 `VID --` 的情况。

本版不再直接查找 `ijkmp_get_property_float` 隐藏 C 符号，也不再从对象外部读取 `_mediaPlayer`。改为调用 IJKFFMoviePlayerController 自己的 `refreshHudView`，并只截获其 `fps` HUD 数据。IJK 自带 HUD 不会被打开。

公开 ijkplayer 的 `refreshHudView` 会在播放器内部读取视频解码 FPS 与视频输出 FPS，然后写成：

```text
解码FPS / 输出FPS
```

本 tweak 取右侧作为 `VID`。显示示例：

```text
VID 59.9 HUD | SRC 30 | 2.0x
```

仍保留 `max-fps -> 120`、B站 CADisplayLink 60 -> 120、SRC 与倍速监测。未恢复任何已知高风险渲染 Hook。

编译：

```bash
make clean package FINALPACKAGE=1 messages=yes
```
