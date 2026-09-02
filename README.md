# Proxy Audio

macOS 虚拟声卡。让 HDMI 电视 / 显示器也能用系统音量键。

基于 [briankendall/proxy-audio-device](https://github.com/briankendall/proxy-audio-device)（Unlicense）。这是独立仓库，不是官方 Fork。

## 解决什么问题

不少 Mac（尤其是 Mac mini）用 HDMI 接电视或显示器时，系统声音里那台设备是亮的，**音量却是灰的**，菜单栏和键盘音量键都调不了。

Proxy Audio 在系统里加一块虚拟输出。你把系统默认输出设成它，音量键调的是这块虚拟声卡；驱动再把声音转到真正的 HDMI 设备上。

这是原项目就有的做法。本仓库多做的是：**电视关掉、电脑休眠再醒来之后，驱动自己把 HDMI 设备找回来**，不用再打开设置重选。

HDMI 断电后设备 UID 有时会变，睡眠唤醒时系统通知也不总是到。所以这里会记住设备名 / 厂商 / 传输类型，并定期复查。在 LG OLED（系统里常叫 **LG TV SSCR2**，C2 / C3 / C4 都一样）上是这么用的；同一类 HDMI 音量灰色、休眠后丢设备的情况，也可能适用。

## 和上游的区别

- 目标设备离线后再出现时自动重新绑定
- 监听设备列表和 `DeviceIsAlive`，通知丢了大约每 5 秒再查
- 设置 App 可安装 / 卸载驱动，不需要自己拷 HAL 插件
- 未合入上游里改实时音频时钟的 PR

无官方签名和公证，只适合本机使用。修改过的驱动不能和官方安装包混装。

## 使用

1. 用 Xcode 构建 **Proxy Audio Device Settings** scheme（Release），得到 `Proxy Audio.app`（驱动打在 App 里）
2. 拖到「应用程序」后打开
3. 未装驱动时点「安装」，输入密码
4. 「电视」选你的 HDMI 输出（例如 LG TV SSCR2）
5. 系统设置 → 声音，默认输出选 **Proxy Audio Device**
6. 「保持工作」用「使用电脑时」，这样不会挡住睡眠

缓冲大小放在「高级」里。太小会爆音或失真，一般保持 512。

卸载：在 App 里点「卸载」。

## 构建

需要完整 Xcode。

```
xcodebuild -project proxyAudioDevice.xcodeproj \
  -scheme "Proxy Audio Device Settings" \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

产物在 DerivedData 的 `Release/Proxy Audio.app`。

## License

[Unlicense](LICENSE)。原作者 Brian Kendall。
