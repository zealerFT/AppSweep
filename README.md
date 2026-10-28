# AppSweep

AppSweep 是一款原生 macOS 应用清理工具。它按应用的 Bundle ID 查找关联的缓存、日志、偏好设置、保存状态、应用支持目录、容器和网页数据，并把用户确认的项目移到 macOS 废纸篓。

当前版本是 **0.1.0 预发布版**。它适合测试和反馈，尚未代表已经完成所有 macOS 版本、Intel 设备和干净系统环境验收的正式发行版。

## 功能

- 扫描 `/Applications` 和 `~/Applications` 中的应用，支持搜索、排序和拖入应用。
- 按明确的 Bundle ID 匹配关联文件，不按显示名称猜测归属。
- 默认选择应用本体、缓存和日志；偏好设置、容器和个人数据需要用户主动勾选。
- 清理前重新检查应用是否运行、文件归属和文件身份，避免误删已变化的路径。
- 只移到 macOS 废纸篓，不直接永久删除；操作记录保存在本机，便于找回位置。
- 中文和英文界面，支持系统深色外观。
- 权限面板只引导 macOS 系统设置，不自动提权，也不修改 SIP、Gatekeeper 或 TCC。

## 安装和首次使用

正式发布后，从 GitHub Releases 下载 `.dmg`，将 `AppSweep.app` 拖到“应用程序”文件夹，再从“应用程序”中打开。

首次打开时，macOS 可能显示开发者身份或文件访问权限提示。请只在确认下载来源可信时继续。需要扫描当前用户 Library 中受保护的目录时，在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中允许 AppSweep，然后回到应用点击“立即重新扫描”。

普通清理流程如下：

1. 在左侧选择应用，等待关联文件扫描完成。
2. 检查每一行的路径、类型和大小；涉及偏好设置、容器或个人数据时，先确认内容确实可以删除。
3. 点击“移到废纸篓”，在确认窗口检查选中数量和大小。
4. 完成后可在“操作记录”中查看每个项目的结果和废纸篓位置。

更完整的步骤、限制和故障排查见 [中文操作手册](docs/USER_GUIDE.zh-CN.md)。

## 如何理解扫描提示

“扫描限制”只表示这次扫描可能遗漏内容，例如无法读取的目录、符号链接、大小估算不完整、共享 Bundle ID 或需要官方卸载器的后台服务。

“扫描提示”表示 AppSweep 安全跳过了非标准或已经损坏的应用包。这类提示不需要用户反复授权，也不会影响其它标准应用的扫描；如果需要处理该软件，请使用它自己的卸载器或在访达中处理。

右上角的刷新按钮会重新读取应用列表，并在已有选中应用时重新扫描它的关联文件。应用详情中路径右侧的圆形箭头只重新扫描当前应用。

## 安全边界

AppSweep 不是“所有残留一键清零”工具。当前版本不会：

- 按应用显示名称猜测文件归属；
- 清理共享 Group Containers、钥匙串、系统目录、其他用户目录或外置磁盘；
- 绕过管理员权限、系统保护或文件访问授权；
- 处理所有厂商自定义的安装方式。

检测到登录项、后台服务、系统扩展、驱动、安全软件或匹配的 launchd 任务时，AppSweep 会阻止直接清理并提示使用官方卸载程序。多个已安装副本共用一个 Bundle ID 时，共享数据也会被保护。

移到废纸篓不会立即释放磁盘空间；清空废纸篓后才会释放。清空前可以通过操作记录定位文件并从访达恢复。

## 隐私

AppSweep 在本机运行，没有账号、分析、广告、网络客户端、云存储或自动更新服务。它只读取应用元数据、支持的 Library 路径和文件属性，不上传文件内容。操作记录可能包含应用名称、Bundle ID 和本机路径，详见 [PRIVACY.md](PRIVACY.md)。

## 本地构建

要求：macOS 13 或更高版本、Swift 6 工具链和 Xcode Command Line Tools。

```bash
git clone <your-repository-url>
cd AppSweep
swift run AppSweepSafetyChecks
bash scripts/build.sh
open dist/AppSweep.app
bash scripts/dmg.sh
```

`scripts/build.sh` 默认读取仓库根目录的 `VERSION`，生成当前架构的本地测试包，使用 ad-hoc 签名，未公证。构建产物位于 `dist/`，不会被提交到 Git，因为 `.gitignore` 已排除 `.build/`、`build/` 和 `dist/`。

运行隔离 UI QA：

```bash
CONFIGURATION=debug OUT_DIR="$PWD/build/qa-app" bash scripts/build.sh
build/qa-app/AppSweep.app/Contents/MacOS/AppSweep \
  --qa-smoke "$PWD/build/qa" -AppleLanguages '(zh-Hans)'
```

核心安全检查使用独立的 Swift 测试程序，不依赖第三方包：

```bash
swift run AppSweepSafetyChecks
```

## 正式分发

不上 App Store 也需要为公开分发准备 Developer ID Application 签名和公证。正式发布者需要自己的 Apple Developer Program 账号、Developer ID 证书、稳定的反向域名 Bundle ID 和 `notarytool` 钥匙串 profile。

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Organization (TEAMID)'
export APP_BUNDLE_ID='com.yourcompany.AppSweep'
export NOTARY_PROFILE='your-keychain-profile-name'
export APP_VERSION='0.1.0'
bash scripts/release.sh
```

正式发布前还要在 Apple Silicon、Intel 和最低支持的 macOS 版本上测试，并在干净系统上验证 Gatekeeper、权限持久性和卸载流程。更新 `VERSION` 后提交并创建同名的 `vX.Y.Z` Git tag，再从该 tag 构建正式包。不要把未经公证的本地测试包当作正式安装包。

## 项目结构

```text
Sources/AppSweepCore/       扫描、文件安全和移入废纸篓的核心逻辑
Sources/AppSweep/            SwiftUI/AppKit 界面和本地化资源
Tests/AppSweepCoreTests/     隔离的核心安全检查
docs/                        操作手册和开发维护文档
packaging/                   App Bundle 的基础 Info.plist
scripts/                     构建、DMG、图标和正式发布脚本
VERSION                      构建和发布的默认版本号
```

## 许可证

许可证尚未由项目所有者确定。公开仓库前请补充合适的许可证文件和版权归属；不要在没有授权的情况下复制第三方应用图标、素材或代码。
