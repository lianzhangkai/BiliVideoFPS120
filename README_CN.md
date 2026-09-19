# BiliVideoFPS120 0.2.1 — ExactRendererCounter

0.2.0 仍然 `VID --`，说明 B站内置 IJK 的 `SDL_VoutDisplayYUVOverlay` 符号没有暴露出来，而且 `dropFrameRate` 也没有提供可用的回退值。

这一版改为只针对当前 `IJKFFMoviePlayerController.view` 的**真实运行时类**。如果这个 View 的 `display_pixels:` 方法签名严格符合 IJK 公共协议：

- Objective-C 参数总数 = 3
- 返回值 = `void`
- 显式参数 = 指针类型

才安装 Hook 并统计调用次数。不会再广泛 Hook EAGL、Metal、SampleBuffer 或任意 View。

成功时：

`VID 99.6  SRC 50  2.0x`

这里 VID 是 IJK 向实际 renderer 提交视频帧的速率，不是 `SRC × 倍速` 估算。

如果还是 `VID --`，把下面日志发回来：

`Bilibili 数据容器/Documents/BiliVideoFPS120.log`

日志会包含真实 renderer 类名、`display_pixels:` 的 method encoding，以及该类中带 display/render/pixel/present/draw/frame 的方法名。下一步就可以按真实 renderer 定点处理，不再猜。

仍保留：`max-fps < 120 -> 120`、`CADisplayLink 60 -> 120`、`frameInterval 2 -> 1`。Overlay 仍为 alpha 0.18、宽度跟文字长度。

编译：

```bash
make clean package FINALPACKAGE=1 messages=yes
```
