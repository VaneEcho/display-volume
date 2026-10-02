# Display Volume

**让 Mac 音量键也能控制显示器声音。**

Native macOS volume control for HDMI and DisplayPort audio.

Mac 通过 HDMI、DisplayPort 或 USB-C 连接部分显示器、电视时，系统音量会变灰，音量键也无法调节。你只能使用显示器按键或遥控器，而 Mac 一侧保持固定输出电平。

Display Volume 添加一个可调音量的虚拟输出，再将声音转发给显示器。设置一次，之后照常使用键盘音量键和系统音量滑块。

## 使用

1. 从 [Releases](https://github.com/VaneEcho/display-volume/releases) 下载并解压 `Display Volume.app`，放入「应用程序」。
2. 打开应用，点击「安装驱动」，输入管理员密码。
3. 在「设备」中选择显示器或电视，点击「设为系统输出」。
4. 用 Mac 音量键调节声音。设置完成后可以退出应用，驱动会继续工作。

默认使用「自动」运行方式。电视暂时离线后，驱动会继续寻找原设备；设备重新出现时尝试恢复输出。

## 适用范围

- 适合 Mac 系统音量不可调的 HDMI / DisplayPort 显示器和电视音频；USB-C 显示器是否适用取决于其实际音频设备。
- 提供立体声 PCM 软件音量和静音，不调整显示器的硬件音量，不提供环绕声或 Dolby / DTS 直通。
- 已在本机 LG TV SSCR2 环境使用；其他显示器、扩展坞和连接方式仍需验证。
- 应用最低系统目标为 macOS 12，使用原生 AppKit 控件跟随系统外观；旧系统兼容性尚未逐版实测。

如果声音仍然过大或过小，也可以调整显示器自身的音量。软件只能衰减传入的音频，不能提高显示器的最大音量。

## 高级设置

通常保留默认值即可。

| 设置 | 用途 |
| --- | --- |
| 自动（推荐） | 使用电脑或播放时运行，空闲时暂停 |
| 播放时 | 按需启动，声音开头可能有短暂延迟 |
| 持续运行 | 持续保持输出，可能影响自动睡眠 |
| 缓冲 | 默认 512 帧；出现断续时可尝试更大值 |
| 名称 | 修改系统中显示的虚拟输出名称 |

更新驱动：打开新版应用，选择「高级 → 更新驱动…」。

卸载驱动：选择「高级 → 卸载驱动…」。更新和卸载需要管理员密码，会短暂中断系统声音。

**从 Proxy Audio 升级：** Display Volume 是本项目的新名称，保留原有驱动标识和配置。退出旧应用后使用新版更新驱动即可；旧的虚拟输出名称可能保留，可在高级设置中修改。不要同时安装上游官方驱动和本项目驱动。

当前构建未做 Developer ID 签名和 Apple 公证，macOS 可能阻止直接打开。也可按照下文从源码构建。

## 1.2.2 更新

- 合并系统设备列表、电视音频流和声道配置变化通知；延迟重连以等待 HDR 切换完成，即使设备 ID 未变也会重建输出

## 1.2.1 更新

- 监听 HDMI 音频流和声道配置变化；HDR 切换重建电视音频流后自动恢复输出，无需重新选择设备

## 1.2 更新

- 简化主界面，加入一键设为系统输出；声音设置放在右下角
- 安装后持续等待驱动加载；音频回调初始化失败后重试
- 避免设备拒绝缓冲请求时反复重启输出，显示实际缓冲大小
- 修复分离声道、多声道位置和音频缓冲读取边界
- 统一系统上报的 dB 与实际增益，加入短暂的音量平滑过渡
- 修复 UTF-8 字符串内存错误，清理旧设备监听，将异常日志移出实时音频回调

音量曲线修正后，相同档位可能比旧版更响，更新后请先低音量试听。

## 构建与验证

使用 Xcode 27 或更新版本，无第三方依赖。内部工程和 scheme 名称保留，方便现有构建流程升级。

```sh
xcodebuild -project proxyAudioDevice.xcodeproj \
  -scheme "Proxy Audio Device Settings" \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

产物：`build/Build/Products/Release/Display Volume.app`，已内置驱动。

运行音频回归测试：

```sh
xcrun clang++ -std=c++17 -fsanitize=address,undefined -g \
  tests/audio_tests.cpp proxyAudioDevice/AudioRingBuffer.cpp \
  -framework CoreServices -o /tmp/display-volume-tests
/tmp/display-volume-tests
```

测试覆盖音量、静音、声道映射、缓冲边界和平滑过渡。休眠唤醒、电视开关、长时间播放及采样率切换仍需实机验收。

## 致谢与许可

基于 Brian Kendall 的 [proxy-audio-device](https://github.com/briankendall/proxy-audio-device)，沿用 [Unlicense](LICENSE)。本项目增加了设备重连、驱动管理、界面和稳定性改进，是独立维护的衍生项目。
