# 定位测试

个人使用的 iPhone 原生定位测试 App。目标系统为 iOS 27+，首测设备为 iOS 27.3。

- 输入十进制度数，设置固定位置或恢复真实定位。
- 支持本机六位码配对和导入 RPPairing 文件，配对凭据保存在设备 Keychain。
- 通过 LocalDevVPN 连接本机开发者服务，开发者镜像内置于 App，连接后按需安装。

## 构建和 USB 安装

1. 将源码放到自己的 GitHub 私有仓库，在 Actions 中手动运行「构建 iPhone IPA」。也可在带 iOS SDK 的 Xcode 27 环境执行 `bash scripts/build-ipa.sh`。
2. 下载构建产物并解压，得到 `LocationBench.ipa`。这个 IPA 需在安装时签名。
3. 在 Windows 安装 iLoader 及其要求的 Apple 设备驱动。插入并解锁 iPhone，按提示信任电脑。 [iLoader 安装说明](https://github.com/nab138/iloader#how-to-use)
4. 在 iLoader 选择手机，登录 Apple 账号并导入 `LocationBench.ipa` 签名安装。按手机提示开启开发者模式和信任开发者。

## 手机端真机验证

1. 连接 Wi-Fi，安装并打开 LocalDevVPN。 [App Store](https://apps.apple.com/app/localdevvpn/id6755608044)
2. 在定位测试 App 点击「配对本机」，允许本地网络访问。然后到「设置 → 隐私与安全性 → 开发者模式」选择与 `LocationBench` 配对，输入 App 或通知显示的六位验证码。若本机配对未成功，可用 Windows 上的 `idevice_pair` 通过 USB 生成 **Remote pairing** 文件，将其暂存到 iPhone 的「文件」并在 App 导入。导入后可以删除用于传输的文件副本。 [USB 配对说明](https://github.com/jkcoxson/idevice_pair#over-usb)
3. 在 LocalDevVPN 开启隧道。回到 App 输入两个测试坐标并依次应用，每次切到 Apple 地图检查蓝点。初次运行会安装内置开发者镜像，请让 App 停留在前台。
4. 在 App 点击「恢复真实定位」，再到地图确认。验证锁屏、切换 App 和断开隧道后的表现。若状态未知，恢复隧道后重新进 App 执行恢复。

首版使用外置 LocalDevVPN 和 Wi-Fi。定位会话由 iOS 管理，切换 App、后台挂起或隧道中断可能影响其持续时间。界面显示指令发送结果，实际定位以真机观察为准。

## 代码

- `LocationBench/LocationBenchApp.swift` 是操作界面。
- `LocationBench/LocalPairing.swift` 和 `PairingStore.swift` 处理本机配对、导入和凭据保存。
- `LocationBench/DeviceConnection.swift` 连接 DVT 定位服务并释放会话。
- `LocationBench/DeveloperImage.swift` 提供内置开发者镜像。
