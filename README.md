# SnapBooth

SnapBooth 是面向活动现场的现拍现打 App。**iPad 是主平台**：iPad 通过 Canon CCAPI/Wi-Fi 驱动 EOS R50 V 真快门与热靴闪光灯，自动下载、保存、排版，再通过系统分享把成片交给米家 App，由用户在米家确认打印。Mac 版仅作为 USB 协议验证、开发调试和应急备用，不作为产品主链路。

## iPad 主链路状态

- EOS R50 V：已接入 Canon CCAPI。iPad 可通过 HTTP/HTTPS Wi-Fi 实时取景、触发真快门与 AD-E1 热靴闪光，并从存储卡自动下载新增 JPEG；支持佳能 Digest 用户认证，自签名证书仅对所配置的相机主机放行，密码保存在 iPad 钥匙串。UVC 只作为无闪光备用取景。
- 米家桌面照片打印机 2：iPad 默认“米家 App”模式。拍摄后点击“用米家打印”直接弹出分享面板，选择米家（未显示时查看“更多”）。跳过 SnapBooth 的打印编辑页，不合成纸张留白、边框或模板；仅保留照片画幅、滤镜和旋转。由米家设置边框、6 英寸相纸并确认打印。用户已验证 SnapBooth 分享可以进入米家；分享完成不代表打印完成，取消分享保留当前照片。不提供私有 BLE 直连打印。
- AirPrint：仅作为其他兼容打印机的备选。当前这台二代打印机未在局域网公告 IPP/IPPS 服务。
- iPad 验收标准：所有主功能必须在 iPad 真机完成。Mac Catalyst 构建通过只用于防止备用版回归，不代表 iPad 主链路已完成。

## 当前版本：0.5.3 / build 28

已清理未使用的旧界面、蓝牙直连实验代码和相关蓝牙权限声明。iPad 使用米家分享打印，保留 AirPrint 与模拟打印；Mac 保留 USB 后端。构建缓存和历史安装包已从项目目录移除。

## 历史记录：0.4.1 / build 21

Mac 版现在包含专用的米家 USB 后端，不经过 macOS 打印队列，也不使用系统误配的 DYMO Label Printer 驱动。

- 已在实机识别 `Mijia Instant Photo Printer 2`（USB VID `302c`、PID `3008`）。
- 已验证厂商命令端点、打印端点和 `DC_RASTER` 协议。
- 启动时自动读取打印机型号、固件和告警状态。
- 当前测试机返回型号 `xiaomi.printer.syrup`、固件 `2.1.2_0034`、无告警。
- Mac 默认使用“米家 USB”；自动打印已移除，只能手动确认打印。
- 佳能相机拍摄后，App 在后台完成裁切、滤镜、排版及 300 DPI JPEG 编码，再创建 USB 打印任务。
- 示例图片不会触发自动打印，可用于安全检查排版。
- Build 17 补齐米家照片任务要求的 JPEG 元数据、SHA-1、照片通道与任务状态轮询，并修正数据帧长度必须包含 4 字节任务编号的问题。
- App 只有在设备返回任务完成（`job-state=9`）后才显示“打印完成”；耗材不匹配或进纸暂停会显示失败并提示不要重复发送。
- 米家 USB 路径只支持已通过实物验证的 6 英寸相纸，固定生成横向 `1800×1200` JPEG 并发送 `media-size=5012`、`media-type=2010`；Mac 界面不再提供其他纸型，防止误选耗材导致任务暂停。
- 实机任务 `#15` 已完整上传、打印并返回 `job-state=9`；打印机最终恢复为空闲且无告警。
- Build 19 删除“拍完自动打印”及其全部触发逻辑，米家打印只能由“打印这张照片”按钮手动开始。
- 真实相机拍摄并完成排版后会自动保存 JPEG：Mac 保存到用户的 `图片/SnapBooth` 文件夹，iPad 保存到照片图库；示例图片不会触发自动保存。
- Build 20 使用原创红金婚礼封面作为首页；点击“开始拍摄”后才启动相机。
- 6 英寸相纸和成片默认横向输出为 `1800×1200`；点击“打印这张照片”会进入独立编辑页，可切换 5 种相纸边框和 5 款原创婚礼模板，最后点“确认打印”才发送任务。

USB 命令封装参考了同为 Hannto 设备的公开逆向工程项目 [eastbaymakersclub/pixcut-s1](https://github.com/eastbaymakersclub/pixcut-s1)，并针对本机米家桌面照片打印机 2 的接口和端点进行了实机探测。

## Mac 使用

1. 用 USB/Type-C 将 Canon 相机和米家桌面照片打印机 2 同时连接到 Mac。
2. 打开 `SnapBooth.xcodeproj`，选择 **My Mac (Mac Catalyst)**。
3. 首次构建前安装编译依赖：`brew install libusb gphoto2`。米家辅助程序静态链接 libusb；佳能辅助程序运行时仍依赖 Homebrew 的 libgphoto2。
4. 运行并允许相机权限。
5. 确认设备区显示 Canon 相机，打印区显示“USB 在线 · 无告警”。
6. 装好米家 6 寸相纸和对应色带。
7. 按“开始拍照”；倒计时完成后会自动生成最终 JPEG 并保存到 `图片/SnapBooth`。确认预览后，按“打印这张照片”才会发送打印任务。

“模拟打印”只生成 JPEG，不会出纸；真实打印必须手动按“打印这张照片”。

## iPad 连接佳能 R50 V

1. 在相机进入 `高级连接 → Camera Control API`，连接与 iPad 相同的 Wi-Fi，并保持相机停留在“通信中”。
2. 在 SnapBooth 的相机选择菜单中点“设置佳能 Wi-Fi 地址”。
3. 粘贴相机显示的完整 URL（例如 `https://192.168.1.11/ccapi`），按相机设置填写用户名和密码。
4. 状态显示“真快门/闪光”后再拍摄。成片会保留在相机存储卡，同时自动保存到 iPad 照片图库。

不要从 macOS 系统打印窗口选择当前的 `Mijia Instant_Photo_Printer_2` 队列：本机把它错误识别为 DYMO 标签打印机。SnapBooth 的“米家 USB”模式会绕过该队列。

## 功能

- 自动发现 AVFoundation 可识别的内置或 USB 相机；
- 相机切换、实时预览和 0/3/5/10 秒倒计时；
- 原始、1:1、3:4、2:3、16:9 裁切；
- 暖阳、清透、胶片、黑白、复古滤镜及强度调节；
- 满版、四宫格、双联照片条；
- 1 寸、2 寸证件照精确拼版和裁切线；
- 米家桌面 6 寸纸默认画布 `100 × 148 mm`；
- 保存最终成片、模拟打印、AirPrint 和 Mac 米家 USB 直连。

## 验证

Mac Catalyst：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project SnapBooth.xcodeproj -scheme SnapBooth \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' build
```

iPad Simulator：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project SnapBooth.xcodeproj -scheme SnapBooth \
  -configuration Debug -sdk iphonesimulator build
```

排版回归测试：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swiftc SnapBooth/StandardPrintGeometry.swift \
  Tests/StandardPrintGeometryTests.swift \
  -o /tmp/snapbooth-geometry-tests && /tmp/snapbooth-geometry-tests
```

## 当前限制

- Canon CCAPI 需要 R50 V 和 iPad 同处一个可互访的 Wi-Fi；相机端账号或密码修改后，需要在 App 中同步更新。
- Mac USB 后端目前只为米家桌面照片打印机 2 的 6 寸照片路径配置。
- iPad 不提供米家 BLE 直连打印；旧探测与认证实验代码已移除。
- 1/2 寸模板只保证物理尺寸和拼版，不代表符合特定证件的拍摄规范。
