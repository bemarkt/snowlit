# Snowlit

原生 iOS/iPadOS 阅读应用，最低系统版本 26.0。

目前是基础工程：支持启动、应用目录准备和失败重试。书源、书架和阅读功能尚未接入。

## 工程

打开 `Snowlit.xcodeproj`，使用共享的 `Snowlit` scheme。

一个 Xcode App 负责装配与界面，一个本地 Swift Package 提供四个模块：

| 模块 | 边界 |
| --- | --- |
| SnowlitCore | 领域类型和基础接口 |
| SnowlitStorage | 存储与文件 |
| YingxueKit | 映雪书源 |
| SnowlitReader | 原生阅读呈现 |

后三个模块仅依赖 SnowlitCore，App 链接四个产品。Package 源码由 SwiftPM 管理，不加入 App 的 Compile Sources。尚无业务消费者的模块只保留编译边界，不预设业务 API。

采用 Swift 6 语言模式和严格并发检查。当前没有第三方包依赖，因此没有 Package.resolved；添加依赖时需要提交解析后的锁文件。

## 构建与验证

CI 固定使用 `macos-26`、Xcode 26.6 和 iOS 26.5 模拟器，Apple 平台验证在 macOS 执行。每次运行记录实际 Xcode、Swift、SDK、runner image、模拟器版本及源码 SHA。

在具有同一工具链和运行时的 Mac 上：

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
bash scripts/ci.sh phone
bash scripts/ci.sh tablet
```

脚本创建并清理专用模拟器。重复运行前，将上一次 `build/evidence/` 的结果移到其他目录，避免覆盖测试报告。

验证包含模块/源码归属检查、Core 独立编译、Storage 文件系统测试、App 启动状态测试、iPhone/iPad 启动及失败重试 UI 测试，以及未签名的 Release 设备架构编译。

工作流只上传 `build/evidence/` 中的环境清单、日志、应用元数据和 xcresult，保留 14 天。它不产生发行 IPA。较高版本模拟器的成功不代表 iOS 26.0 最低运行时或真机验收通过。

Windows 可先运行 `python scripts/check_structure.py --sources-only` 检查源码导入边界。该检查不代替 Xcode 构建或 iOS 测试。

真机运行时，在本机 Xcode 中选择自己的签名团队。签名证书与描述文件不提交到仓库。
