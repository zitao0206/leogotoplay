# LeogotoPlay

`LeogotoPlay` 是一个视频工具 App 的双端工程：**iOS 版 + macOS 版**，共用一层端无关的 `LeogotoPlayCore`（Swift Package）。

两边都是同一套产品能力：

1. **素材库管理**：根目录直接导入 / 展示视频（与文件夹同一套列表 cell，含缩略图、名称.mp4、大小、添加日期、时长）→ 文件夹收纳（V1.0.3 支持多级子文件夹，V1.0.4 固定列表视图）→ 搜索 / 排序 / 移动 / 重命名 / 删除
2. **播放器**：进度拖动、倍速、循环、画面填充
3. **基础剪辑**：相簿 / 素材库视频 → 裁剪（时间轴双手柄）、静音 → 存回相簿或存入素材库，也可导出到用户指定的位置
4. **账号体系**：登录 / 注册 / 登录态持久化（本地演示实现，接口已抽象，方便接后端）

iOS 首页是 `Cut / List / Mine` 三个 Tab，结构由 `AppConfig` 驱动，可增删改序；macOS 用侧栏对应 `剪辑台 / 素材库 / 我的` 三个入口。

| iOS Cut | iOS List | iOS Mine |
| --- | --- | --- |
| ![Cut](docs/screenshots/01-cut.png) | ![List](docs/screenshots/02-list.png) | ![Mine](docs/screenshots/03-mine.png) |

### V1.0.4 · List 页收敛

| 根目录（统计卡 = 视频 / 占用空间 / 总时长，点击进入全部视频） | 文件夹内（不显示统计卡） |
| --- | --- |
| ![根目录](docs/screenshots/08-root-stats.png) | ![文件夹内](docs/screenshots/09-folder-no-stats.png) |

- 去掉文件夹区域的布局切换按钮（列表 / 卡片），固定列表展示；卡片视图代码一并移除。
- 去掉文件夹标题右侧的 `All` 入口。
- 统计卡从「视频 / 文件夹 / 占用」改为「视频 / 占用空间 / 总时长」，整块可点，点进去就是全部视频列表（原来 All 的去处）；卡片上不显示右指向箭头，点击提示只靠卡片本身。
- 文件夹内页不再显示统计卡，进目录直接看子文件夹与视频。
- 搜索时（关键词非空）首页也不显示统计卡，页面直接呈现「搜索结果」，避免搜索时还占着顶部统计的空间。

搜索态截图：`docs/screenshots/10-search-no-stats.png`。

### V1.0.5 · 空态与标题

| 根目录（文件夹副标题 = 数量） | 有子文件夹、没有视频的目录（不显示空态） |
| --- | --- |
| ![根目录](docs/screenshots/12-root-folder-count.png) | ![子文件夹](docs/screenshots/13-folder-subfolders-no-empty.png) |

- 文件夹内页只有在「既没有视频、也没有子文件夹」时才显示 `这是个空文件夹`；已有子文件夹或视频就不再出现空态卡片。
- 首页「文件夹」分组副标题从说明文案改成数量，例如 `3 个文件夹`（按当前根目录下的文件夹数计）。
- 视频长按菜单里去掉了「收藏 / 取消收藏」两项，长按只剩 播放 / 剪辑 / 移动 / 重命名 / 删除。
- 文件夹内页去掉「子文件夹」小标题和 `N 个` 计数，子目录直接从顶部开始列。

早期版本截图（V1.0.3：`+` 建文件夹 / 相册导入，文件夹内 `+` 建子文件夹 / 添加视频）：`06-root-buttons.png`、`07-folder-add-video.png`；更早的 `04-list-plus.png`、`05-folder-subfolder.png` 里 `+` 与相册图标尚未交换、文件夹内还是操作菜单。

## 目录结构

一个仓库、两个 App 外壳、一个共享内核，用一个 workspace 把三者挂在一起：

```
Leogotocool/                       # 仓库根（本目录）
├── LeogotoPlay.xcworkspace        # 平时只需要打开这个
├── apps/
│   ├── ios/
│   │   ├── LeogotoPlay-iOS.xcodeproj
│   │   └── Sources/
│   │       ├── App/               # App 入口、RootTabView、AppConfig（Tab 配置）
│   │       ├── DesignSystem/      # Theme（颜色/字号）+ 通用组件
│   │       ├── Features/          # Cut / List / Mine / Player / Editor
│   │       └── Resources/         # Info.plist、Assets.xcassets
│   └── macos/
│       ├── LeogotoPlay-macOS.xcodeproj
│       └── Sources/
│           ├── App/               # @main、NavigationSplitView 宿主、菜单命令
│           ├── DesignSystem/      # MacTheme、MacComponents（卡片/空态/弹窗）
│           ├── Features/          # Root（侧栏）/ Cut / Library / Player / Editor / Mine
│           └── Resources/         # Info.plist
├── packages/
│   └── LeogotoPlayCore/           # 端无关逻辑，Swift Package
│       └── Sources/LeogotoPlayCore/
│           ├── Models/            # VideoItem、VideoFolder、UserAccount、AuthSession
│           ├── Store/             # LibraryStore、AuthStore（@MainActor，Combine）
│           └── Services/          # 文件存取、导入、导出、缩略图、Keychain、账号服务
├── docs/                          # ARCHITECTURE.md、截图
└── scripts/
    └── generate_xcodeproj.py      # 由文件列表生成两个 .xcodeproj + 一个 workspace
```

分层原则：**Core 只放端无关逻辑**（不 import UIKit / AppKit，不出现 `UIImage`/`NSImage`/`Color(uiColor:)`）；导航、播放画面、配色与系统集成留在各自 App 里。这样 iOS 和 macOS 只维护「壳」，业务逻辑改一次两端都生效。

## 运行

需要 Xcode 15.2+；部署目标 iOS 16.0 / macOS 13.0。

```bash
# 打开 workspace（推荐，一次加载两端 + 共享包）
open LeogotoPlay.xcworkspace
```

在 Xcode 里选择 scheme `LeogotoPlay-iOS` 或 `LeogotoPlay-macOS`，选好模拟器 / My Mac 后 `Cmd + R`。真机需要在 *Signing & Capabilities* 里指定自己的 Team（工程未写死 Team）。

命令行验证（本机已跑通）：

```bash
# iOS（模拟器）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apps/ios/LeogotoPlay-iOS.xcodeproj -scheme LeogotoPlay-iOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro Max' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# macOS（本机 run，ad-hoc 签名）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apps/macos/LeogotoPlay-macOS.xcodeproj -scheme LeogotoPlay-macOS \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath build build

# 只校验共享包
cd packages/LeogotoPlayCore && swift build
```

> 若 `xcode-select -p` 指向 CommandLineTools，`xcodebuild` / `xcrun` 会找不到 SDK，命令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

**新增 / 删除源文件后必须重跑** `python3 scripts/generate_xcodeproj.py`，工程的编译清单是脚本按目录扫出来的，不重跑会报 “cannot find X in scope”。

## 调试入口

两端都留了只在 Debug 生效的直达钩子，方便截图和验证页面：

- iOS：启动参数 `-startTab cut|list|mine`，或深链 `leogotoplay://cut|list|mine`
- macOS：启动参数 `-startSection cut|library|mine`；`-autoOpenFirstVideo YES` 会自动打开最近视频的剪辑窗口

```bash
# macOS 直接打开剪辑窗口
open -a "$PWD/build/Build/Products/Debug/LeogotoPlay.app" \
  --args -startSection cut -autoOpenFirstVideo YES
```

## 数据与权限

- iOS 数据在 App 沙盒 `Documents/LeogotoPlay/`，macOS 在 `~/Library/Application Support/LeogotoPlay/`，都是 `Media/`（视频文件）+ `Thumbnails/`（封面）+ `library.json`（元数据）。
- 登录态存 Keychain，账号资料存本地 JSON；`AuthService` 是协议，换成真后端只改实现。
- 相簿读写需要 `NSPhotoLibraryUsageDescription` / `NSPhotoLibraryAddUsageDescription`（两端 Info.plist 已写）。

## Bundle 标识

| 端 | Bundle ID | 说明 |
| --- | --- | --- |
| iOS | `com.leogotoplay.app` | 深链 `leogotoplay://` |
| macOS | `com.leogotoplay.mac` | 本机 ad-hoc 签名，未沙盒 |
