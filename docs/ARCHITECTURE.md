# LeogotoPlay 架构说明

## 双端一个内核

```
        ┌──────────────── LeogotoPlay.xcworkspace ────────────────┐
        │                                                        │
 apps/ios/LeogotoPlay-iOS         apps/macos/LeogotoPlay-macOS
 (SwiftUI + UIKit 桥接)            (SwiftUI + AppKit 桥接)
        │                                   │
        └──────────► packages/LeogotoPlayCore ◄──────────┘
                     Models / Store / Services
```

- **Core（Swift Package）**：纯 Swift，不 import UIKit / AppKit。放模型、状态、文件与媒体处理。iOS 与 macOS 各自链接这一个包。
- **apps/ios**：只做 iOS 外壳——Tab 导航、`UIViewRepresentable` 播放画面、`UIImage` 缩略图缓存、`PhotosPicker`。
- **apps/macos**：只做 macOS 外壳——`NavigationSplitView` 侧栏、`NSViewRepresentable` 的 `AVPlayerLayer` 画面、`NSImage` 缓存、`NSOpenPanel` / `NSSavePanel` / `NSWorkspace`。

判断一段代码该放哪：**它需要平台 UI 类型吗？** 需要就留在 App，不需要就进 Core。Core 里出现 `UIImage`、`NSColor`、`Color(uiColor:)` 都算破线。

## 分层

```
SwiftUI Views (Features)
        ↓ 只读状态、调用方法
Stores (ObservableObject, @MainActor)     ← Core
        ↓
Services (文件 / 媒体 / 导出 / 账号)      ← Core
        ↓
AVFoundation · Photos · CryptoKit · Keychain · FileManager
```

- **View 层**不做文件 IO、不直接操作 `AVAsset`，只负责交互和展示。
- **Store 层**持有内存状态并负责持久化，所有 UI 变更都在 `@MainActor` 上落地。Core 里用 `Combine`（`@Published`）而非 SwiftUI 的 `withAnimation`，两端订阅方式一致。
- **Service 层**是无状态工具箱（除 `LocalAuthService` 是 actor，串行化账号读写）。

## 三大功能的调用链

两端流程一致，差异只在「选片入口」和「画面承载」两处。

### 1. 导入与管理

```
iOS  PhotosPicker / fileImporter
macOS NSOpenPanel / PhotosPicker
        → VideoImporter.prepare(...)       // 复制到 tmp
        → LibraryStore.importVideo(...)    // 复制到 Media、读时长、生成封面
        → library.json 持久化
```

- `VideoImporter` 暴露 `MovieTransferable`，两端复用同一套导入逻辑；安全作用域 URL 由各端的选片层处理。
- 视频物理文件不重命名用户可见标题，标题只是元数据，避免重名和特殊字符问题。
- 删除文件夹时有两种语义：视频一并删除，或视频回到「未分类」。
- App 启动 load 时会校验文件是否存在，清理失效记录。

### 2. 播放

```
iOS  VideoPlayerView → PlayerViewModel → AVPlayer + VideoLayerView(AVPlayerLayer)
macOS MacPlayerView  → 自绘控制条    → AVPlayer + MacPlayerSurface(AVPlayerLayer)
```

- 画面统一用 `AVPlayerLayer` 承载，控件由 SwiftUI 自己画。
- **macOS 不要用 AVKit 的 SwiftUI `VideoPlayer`**：在 macOS 14 + ad-hoc 签名应用上会在打开即崩（`_AVKit_SwiftUI` → `getSuperclassMetadata`）。`AVPlayerView`（NSViewRepresentable）同样不稳，已改为自绘 `AVPlayerLayer` + 纯 AVFoundation。iOS 侧仍可用 AVKit，不受影响。
- 30fps 周期观察者驱动进度；`AVPlayerItemDidPlayToEndTime` 处理播放结束与循环。
- 倍速通过 `AVPlayer.rate` 控制，暂停时不改 rate。

### 3. 剪辑 + 导出

```
iOS  VideoEditorView → EditorViewModel
macOS MacEditorView → MacEditorModel
   ├─ 预览播放（限制在裁剪区间内循环）
   ├─ TrimRangeSlider / MacTrimSlider（左右手柄 → trimStart / trimEnd）
   └─ export()
        → VideoExporter.export(...)        // AVMutableComposition + AVAssetExportSession
        → VideoExporter.saveToAlbum(...)   // PHPhotoLibrary addOnly
        → VideoExporter.moveExport(...)    // macOS 另有「导出并另存为…」走 NSSavePanel
        → 或 LibraryStore.importExport(...)
```

- 裁剪用「区间」而不是打点，`minTrimGap` 保证至少 0.1–0.2 秒。
- 静音通过不插入音频轨道实现，不依赖 `AVAudioMix`，导出结果更可预期。
- 导出有进度回调（200ms 轮询 `session.progress`），UI 显示百分比。
- 胶片条帧由 Core 的 `ThumbnailService.generateFrames` 出 `[CGImage]`，iOS 转 `UIImage`、macOS 转 `NSImage`，Core 不认识平台图像类型。

### 4. 账号

```
LoginView → AuthStore → AuthServicing
                         └─ LocalAuthService（actor）
                               ├─ accounts.json（加盐 SHA256）
                               └─ 返回 AuthSession
AuthStore → Keychain（保存 token + 用户信息）
```

- `AuthServicing` 是替换后端的唯一入口：

```swift
protocol AuthServicing {
    func register(nickname: String, email: String, password: String) async throws -> AuthSession
    func login(email: String, password: String) async throws -> AuthSession
    func logout(token: String) async
}
```

- 生产环境应删除 `LocalAuthService`，并让 `AuthStore` 持有带 401 刷新逻辑的客户端。

## 导航配置

iOS：`AppConfig.current.tabs` 决定 Tab 的顺序与数量。

```swift
var tabs: [Tab] = [.cut, .list, .mine]
```

`RootTabView` 用 `ForEach(config.tabs)` 渲染，新增 Tab 只需在 `AppConfig.Tab` 加 case 并在 `tabContent` 里给出页面。Deep link（`leogotoplay://<tab>`）同样基于这份配置做校验。

macOS：`MacSection`（`cut / library / mine`）驱动 `NavigationSplitView` 侧栏，新增页面加 case + `destination` 即可；两者是各自平台的导航习惯，不强行共用一套。

## 工程文件是生成的

两个 `.xcodeproj` 和一个 `.xcworkspace` 都由 `scripts/generate_xcodeproj.py` 生成：它扫目录拿到源文件清单，写 `PBXBuildFile` / `XCLocalSwiftPackageReference`（相对路径 `../../packages/LeogotoPlayCore`）/ 共享 scheme，再拼出把两端挂进同一 workspace 的 `contents.xcworkspacedata`。

- 好处：不用手点 Xcode 加文件，也没有 pbxproj 合并冲突。
- 代价：**新增 / 重命名 / 删除源文件后必须重跑脚本**，否则新文件不进编译。
- 本地包的引用有三个字段必须成组出现：`PBXProject.packageReferences` 里的 `XCLocalSwiftPackageReference`、target 的 `packageProductDependencies`、以及 `XCSwiftPackageProductDependency` 里的 `package = <本地包引用 id>`。少最后一个字段时命令行 `xcodebuild` 仍能构建，但 Xcode 会报 `Missing package product 'LeogotoPlayCore'`。
- 以后若要换成 XcodeGen / Tuist，把脚本里的 `project.yml` / `Project.swift` 描述迁移过去即可。

## 并发与线程

- 时长读取、缩略图生成、胶片帧生成都放到 `Task.detached(priority: .utility)`，避免阻塞主线程。
- `AVPlayer` 周期观察者回调统一转成 `Task { @MainActor ... }`，保证状态更新在主线程。
- 持久化写入有 120ms 防抖，避免连续操作（如批量移动）频繁写盘。

## 已知约束

- macOS 端当前是 ad-hoc 签名、无沙盒、无 entitlements，仅适合本机开发运行；分发需要 Developer ID + 公证，并补 `com.apple.security.files.user-selected.read-write` 等权限。
- macOS 不要在同一个数据目录下同时跑多个实例（`open -n`）：两端都写同一份 `library.json`，会出现素材重复与状态互相覆盖。调试完记得退出旧实例。
- macOS target 目前没有 asset catalog，AppIcon 走默认图标。

## 可预见的下一步

1. **剪辑能力**：滤镜（`CIFilter` + `AVVideoComposition`）、转场、文字/贴纸、多片段拼接入 `AVMutableComposition`。
2. **素材库**：批量选择、回收站（软删除）、iCloud 备份、导入进度任务队列。
3. **账号**：接真实后端、刷新 token、账号与素材库的云同步/多端合并策略。
4. **macOS 桌面化**：拖拽导入、菜单栏快捷操作、多窗口编辑、Quick Look 预览。
5. **性能**：缩略图列表骨架屏、预热下一页缩略图、长列表分页（大量视频时）。
6. **测试**：`LibraryStore` / `VideoExporter` 的单元测试，编辑流程的 UI 测试。
