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

后三个模块的内部依赖仅指向 SnowlitCore；SnowlitStorage 另使用 GRDB。App 链接四个产品，Package 源码由 SwiftPM 管理，不加入 App 的 Compile Sources。`Experiments/` 中的小样尚未接入业务入口，也不是已冻结的源协议或持久格式。

采用 Swift 6 语言模式和严格并发检查。GRDB 精确锁定为 7.12.0，提交 `92a554cd0d5e8d67cb18993c6054e73fe42c066c`；SwiftPM 与 Xcode 锁文件记录相同版本，许可证在 `Licenses/GRDB.txt`。升级时需复核 Swift/SQLite 兼容性并重跑事务、文件和备份故障用例。

## 构建与验证

CI 固定使用 `macos-26`、Xcode 26.6 和 iOS 26.5 模拟器，Apple 平台验证在 macOS 执行。每次运行记录实际 Xcode、Swift、SDK、runner image、模拟器版本及源码 SHA。

在具有同一工具链和运行时的 Mac 上：

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
bash scripts/ci.sh phone
bash scripts/ci.sh tablet
bash scripts/probe_ios.sh phone
bash scripts/probe_ios.sh tablet
bash scripts/probe_ios.sh phone recovery
```

脚本创建并清理专用模拟器。重复运行前，将上一次 `build/evidence/` 的结果移到其他目录，避免覆盖测试报告。

验证包含模块/源码归属检查、Core 独立编译、Storage 文件系统测试、App 启动状态测试、iPhone/iPad 启动及失败重试 UI 测试，以及未签名的 Release 设备架构编译。

实验脚本还需要 Node.js 22 或更高版本，通过 `127.0.0.1:18731` 提供独立的合成站点。它选择 WebKit/Reader 集成测试并记录脚本、源码与工具链身份；合成站点缺失会失败。`recovery` 模式仅在专用模拟器内观察无限循环和挂起 Promise，外层监督进程限制执行时间。等待超时、释放 Swift 对象或新操作成功都不等于底层 JavaScript/资源已停止。

本地服务测试可用 `node --test scripts/probes/site.test.mjs`。该命令只验证站点行为，不证明浏览器 DOM、Cookie 或 iOS 可用性。Reader 小样验证 TextKit 2 属性文本、附件/标记和准备好的系统卷页页面；真实手势、长时资源与设备性能仍需单独验收。

工作流只上传 `build/evidence/` 中的环境清单、日志、应用元数据和 xcresult，保留 14 天。它不产生发行 IPA。较高版本模拟器的成功不代表 iOS 26.0 最低运行时或真机验收通过。

Windows 可先运行 `python scripts/check_structure.py --sources-only` 检查源码导入边界。该检查不代替 Xcode 构建或 iOS 测试。

真机运行时，在本机 Xcode 中选择自己的签名团队。签名证书与描述文件不提交到仓库。
