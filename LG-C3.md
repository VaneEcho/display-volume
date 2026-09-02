# LG C3 个人稳定版

分支：`lg-c3-stability`（基于 `master`，已含 PR #70）。

手工整合了 PR #71（generation token + 5 秒重试）和 PR #72（优先设备、离线回退、恢复后切回）的思路，没有直接 cherry-pick。未合入 PR #66 / #74 的实时时钟改动。

## 行为

- Proxy Audio Device 保持为系统默认输出；物理设备切换只在驱动内部完成。
- 持续保存目标 UID，以及名称 / 厂商 / transport，供 HDMI 断电后 UID 变化时后备匹配。
- 匹配顺序：精确 UID → 唯一的名称+厂商+HDMI/DP 身份 → USB 端口变化（#71）。多个候选时不选，避免误绑。
- 监听设备列表和 `DeviceIsAlive`，并在串行非实时队列上每约 5 秒复查。
- 目标离线时默认静音；可选择回退到 Mac mini 内置扬声器。目标回来后自动切回。
- Settings 在目标离线时显示 `名称（离线）`，而不是空白。
- 默认仍是「仅用户活跃时运行」，避免挡住系统睡眠。

## 构建

需要完整 Xcode，并把 `xcode-select` 指到 Xcode：

```
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
cd proxy-audio-device
xcodebuild -project proxyAudioDevice.xcodeproj -scheme ProxyAudioDevice -configuration Release build
xcodebuild -project proxyAudioDevice.xcodeproj -scheme "Proxy Audio Device Settings" -configuration Release build
```

产物一般在 `build/Release/`：

- `ProxyAudioDevice.driver`
- `Proxy Audio Device Settings.app`

修改后的驱动没有官方签名/公证，只适合本机使用。

## 安装

安装前备份旧驱动，并确认 `/Library/Audio/Plug-Ins/HAL` 里没有同 UUID 的两份驱动。

```
sudo mkdir -p /Library/Audio/Plug-Ins/HAL
sudo rm -rf /Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver
sudo cp -R build/Release/ProxyAudioDevice.driver /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver
sudo killall coreaudiod
```

然后打开 Settings，选择 LG C3，保持 Proxy Audio Device 为系统默认输出。离线回退选项默认关闭（静音）。

## 卸载

```
sudo rm -rf /Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver
sudo killall coreaudiod
```

## 验证矩阵

- 启动时电视已打开
- 启动时电视关闭，之后再打开
- 电视正常关/开 10～20 次
- Mac 睡眠/唤醒，电视保持打开
- Mac 睡眠期间关闭电视，唤醒后再开电视
- 切到 Mac mini 扬声器再切回来
- 44.1 / 48 kHz、系统提示音、连续播放、音量键
- 无爆音、嘶声、音量突跳、重复设备、阻止睡眠
