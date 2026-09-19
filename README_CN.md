# BiliVideoFPS120 0.2.0 VoutCounterSafe

这一版针对 0.1.9 中 `SRC` 和倍速正常、`VID` 始终 `--` 的情况换了路线。

## 核心变化

- 不再调用 `refreshHudView`，也不再依赖 B站 fork 是否更新 IJK HUD FPS
- 不恢复 0.1.6 中导致闪退的 EAGL / Metal / `display_pixels:` 动态 Objective-C Hook
- 优先尝试解析并 Hook IJK 的 C 函数 `SDL_VoutDisplayYUVOverlay`
  - upstream IJK 在每次把视频帧送入输出层时都会调用它
  - 如果该符号在 B站二进制中可见，状态栏会显示真正的 `VID xx.x`
- 如果符号被 strip/hidden，使用公开的 `dropFrameRate` 做后备估算
  - 显示为 `VID~100`，波浪号表示“估算”，不是宣称实际 present FPS
  - 估算：`SRC × playbackRate × (1-dropFrameRate)`，并封顶到屏幕 120Hz
- 继续把 `max-fps < 120` 提升到 120
- 继续把 B站请求的 `CADisplayLink 60 -> 120`、旧 `frameInterval 2 -> 1`
- Overlay 改成自适应文字宽度，背景 alpha 0.18，减少遮挡弹幕

## 显示示例

如果 C 输出函数 Hook 成功：

```text
VID 99.7  SRC 50  2.0x
```

如果只能估算：

```text
VID~100  SRC 50  2.0x
```

如果两条路都拿不到：

```text
VID --  SRC 50  2.0x
```

## 日志

B站数据容器：

```text
Documents/BiliVideoFPS120.log
```

重点看：

```text
HOOK OK SDL_VoutDisplayYUVOverlay
FPS mode=VOUT ...
```

或：

```text
FPS mode=EST ... drop=...
```

## 编译

```bash
make clean package FINALPACKAGE=1 messages=yes
```

目标环境：iPad Pro 2018 / A12X / iPadOS 13.7 / Odyssey + libhooker / arm64 + old-ABI arm64e。
