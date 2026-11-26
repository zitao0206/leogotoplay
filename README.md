# LeogotoPlay

`LeogotoPlay` 是一个视频工具 App 的双端工程：**iOS 版 + macOS 版**，共用一层端无关的 `LeogotoPlayCore`（Swift Package）。

两边都是同一套产品能力：

1. **素材库管理**：根目录直接导入 / 展示视频（与文件夹同一套列表 cell，含缩略图、名称.mp4、大小、添加日期、时长）→ 文件夹收纳（V1.0.3 支持多级子文件夹，V1.0.4 固定列表视图）→ 搜索 / 排序 / 移动 / 重命名 / 删除
2. **播放器**：进度拖动、倍速、循环、画面填充
3. **基础剪辑**：相簿 / 素材库视频 → 裁剪（时间轴双手柄）、静音 → 存回相簿或存入素材库，也可导出到用户指定的位置
4. **账号体系**：登录 / 注册 / 登录态持久化（本地演示实现，接口已抽象，方便接后端）

iOS 首页是 `Cut / List / Mine` 三个 Tab，结构由 `AppConfig` 驱动，可增删改序；macOS 用侧栏对应同样三个入口。

### Mac-V1.0 · 整体页面结构

- 首页沿用 `NavigationSplitView` 侧栏 + 主区域，两侧分工不变，只把三个入口统一成 iOS 的命名：`Cut` / `List` / `Mine`，中文名（剪辑台 / 素材库 / 我的）降为副标题，默认仍落在 `List`。Debug 的 `-startSection cut|library|mine` 深链照旧可用。
- 侧栏底部原来显示当前账号（`AuthStore.displayName`），属于「登录状态」，本次整块去掉，只留一行素材库统计「N 个视频 · 占用空间」；`MacRootView` 不再需要 `AuthStore` 环境对象。
- `Mine` 页里的账号卡（登录 / 注册 / 退出登录）原样保留，账号能力没动，只是不把登录状态摊在首页。
- 顺手把 `MacEditorView` 里 `Button("重置区间", action: model.resetTrim)` 的告警（`@MainActor` 方法转 `() -> Void` 丢隔离）改成闭包调用，macOS 目标 clean build 0 warning。

### Mac-V2.0 · Cut 页

- 整体走深色：App 启动时把外观设成 `.darkAqua`，页面底色 `#0F0F11`、卡片 `#1A1B20`（`MacTheme.canvas / surface / inkGradient`），强调色沿用 #FF5C3D 的暖红，Cut 页顶部再加一层右上角发散的暖红辉光，和 App 主视觉一致。List / Mine 也跟着变深色，不再出现「侧栏浅、内容黑」的割裂。
- 首页三段式：① 热门工具（2×4 网格：一键提取人脸 / 一键人脸打码 / 一键视频增强 / 一键提取文字，入口先摆齐，点了提示「macOS 端开发中」，能力后续接）；② 「开始编辑」整条卡（左侧加号 + 「开始编辑 / 添加一个本地视频，进入剪辑台」，宽度与上方工具卡对齐，右侧单独一格「素材库」可直接挑已导入的视频），点开始编辑走 `NSOpenPanel` 选本地视频 → 导入素材库 → 直接弹剪辑窗口；③ 最近编辑（横向卡片，按 `modifiedAt` 取最近 8 个）。
- 新增 macOS 剪辑草稿（`MacEditorDraft` / `MacEditorDraftStore`，存 UserDefaults）：打开剪辑页离开时把裁剪区间和静音状态写进去，再次从「最近编辑」点同一个视频直接回到上次的起点 / 终点；卡片左上角打「草稿」角标，时长显示草稿的成片时长，副标题是「草稿 · 几小时前」；没有草稿的卡片标「未编辑 · 文件大小」。右键可继续编辑 / 删除，删除会连同素材库文件、缩略图和草稿一起清掉。
- 原「从相册选片」入口从 Cut 页移除（V2.0 只按本地视频 + 素材库两条主线走），相簿相关代码（`PhotosPicker` 绑定、`importPhoto`）一并删掉。
- 调试钩子：`-startSection cut` 直达 Cut，`-autoOpenFirstVideo YES` 延迟 1s 打开最近一个视频的剪辑窗口（用来验草稿还原）。

### Mac-V2.1 · 剪辑页改整页

- 剪辑从 sheet 改成整页：Cut 页用 `MacCutRoute`（home / editor）切换，剪辑页左上角「‹ 剪辑台」返回。点「开始编辑」进空剪辑页，点「最近编辑」卡片直接进剪辑页并载入该视频 + 还原草稿（裁剪区间、静音）。
- 剪辑页按剪映专业版的骨架分左右两栏：左栏宽 340，上半是视频列表（素材库全部视频，缩略图 + 标题 + 时长，当前载入的高亮），下半是编辑区 + 时间轴（胶片条双柄裁剪、播放头、播放键、静音开关、存入素材库 / 保存到照片）；右栏是播放器（黑底画布 + 底部时间码 / 播放键 / 回到开头）。
- 编辑器 `MacEditorModel` 的 `source` 改成可选，新增 `open(_:)` 支持页面内换素材；载入时按 `libraryVideoID` 找草稿还原现场，离开页面（返回或关窗）写回草稿。
- 顺手把 `MacLibraryView` 的 body 拆成 `decorated` + `content` 两个子视图：原来那一大坨修饰器把类型推断压超时，报 `unable to type-check this expression in reasonable time`，拆完编译恢复正常。

### Mac-V2.2 · 剪映式时间轴

- 「开始编辑」改成居中一条（加号 + 文字居中，宽度与热门工具卡对齐），点了进空剪辑页；Cut 页彻底去掉「素材库」入口、`MacSourcePickerSheet`、`startFromLocalFile`、`isImporting` 等从素材库挑片 / 选本地文件的旧逻辑，导入只剩剪辑页内的「添加视频」。
- 剪辑页按剪映专业版布局：左栏 = 视频列表（一行一个，末尾固定「＋ 添加视频」）+ 编辑区；右栏 = 播放器，导出按钮挪到播放器右上角。
- 载入改成拖放：列表行 `onDrag` 传 `UUID`，编辑区空态是虚线框，拖进来才 `open`，否则只提示「拖动即载入」。
- 编辑模型从「单区间 trimStart/trimEnd」升级为多片段：`MacClip` + `MacEditorDraft`（旧草稿的 `trimStart/trimEnd` 自动迁移成一个片段，编码只写新字段）。预览用 `AVMutableComposition` 逐片段拼视频/音频轨，播放头按「成片时间」映射回片段 + 源时间。
- 时间轴上方工具：撤销（栈深 20）、重置、分割、向左分割、向右分割、缩小、放大（`pixelsPerSecond` 24–320）。`MacTimelineView` 按每秒像素铺片段块、画白色播放头，点击或拖动即 seek。
- 导出走 core 的多片段接口（`VideoExporter.export(sourceURL:clips:quality:progressHandler:)`），清晰度可选最高质量 / 1080p / 720p，可勾静音、可存入素材库。

### Mac-V2.3 · 剪辑独立开窗

- 进剪辑一律新开一个独立窗口（`MacEditorWindowManager`）：从 Cut 首页「开始编辑」「最近编辑」卡片、以及素材库的行编辑进入，都在新窗口里剪，主窗口保持原样；同一条素材已经有窗口在剪时直接把那个窗口提前，草稿现场不丢。窗口标题是「剪辑 · 视频名」，关窗后通知 Cut 首页刷新草稿角标。
- 剪辑页左右比例改成 64 : 36（左侧素材墙 + 时间轴，右侧播放器），窗口最小 1040×660，与剪映专业版的骨架一致。
- 左侧素材区参考剪映的素材面板：顶部「导入」按钮 + 总数，下面「全部」标题与自适应卡片墙（缩略图铺满卡片、时长压在右上角、文件名在卡片下方），末尾固定一张虚线「添加视频」卡；拖动卡片到编辑区才载入。

### Mac-V2.4 · 时间轴胶片与选中框

- 工具栏「分割」右侧新增「删除」，删掉播放头所在的那一段（最后一段不给删，会提示至少要保留一个片段），可撤销。
- 时间轴每段铺满逐帧缩略图：`ThumbnailService.generateFramesStreaming` 按源视频每秒取一帧、边解边填（上限 900 帧），缩放时间轴时一起跟着拉伸/压缩，还没解出来的格子是灰色底。
- 加入 App 同款选中框：播放头落进的段落画白色粗框，左右各一个白色夹持把手（中间一根深色竖条），段落左上角胶囊显示「片段 N · 时长」，播放头移动时选中框跟着走。

### Mac-V2.5 · 工具栏图标化

- 时间轴上方的工具条按参考图改成纯图标（去掉文字标签）：撤销、重置、分割、删除、向左分割、向右分割依次排开，缩小 / 放大单独靠右；悬停有一层淡底，中文名挪到 tooltip 里。
- 按钮状态跟着功能走：撤销没历史时、删除没有选中段时、缩放到头时自动变灰。

### Mac-V2.5.1 · 删掉时间轴下方的旧入口

- 时间轴下面的整块入口都去掉了：播放键 / 时间码 / 片段数 / 静音开关那一行，以及清晰度分段（最高质量 / 1080p / 720p）和「存入素材库」按钮，播放与时间码统一走右侧播放器，导出只留播放器右上角的「导出」。

### Mac-V2.6 · 时间轴居中 + 横向滑杆

- 时间轴从紧贴工具条下方挪到操作区竖直方向的中间：工具条仍在上，时间轴上下各留弹性空白。
- 时间轴下面加了一条横向滑杆（灰色槽 + 可拖动滑块），拖动即可左右滚动时间轴；滑块长度按「可视宽度 / 总宽度」计算，缩放到头时滑块会缩到最短。
- 工具条顺序按参考图调整成：撤销、重置、分割、向左分割、向右分割、删除、缩小、放大；删除按钮在选中片段时高亮（淡底 + 描边），没有选中时变灰不可点。

### Mac-V2.7 · 时间轴加高 + 滑杆贴底

- 时间轴轨道高度从 58 提到 87（1.5 倍），胶片帧、选中框把手、播放头一起放大；整条时间轴仍在操作区竖直居中。
- 横向滑杆挪到编辑面板最底部，紧贴底边（只留 2pt 内边距），不再跟在时间轴后面。
- 顺手修了胶片取帧：改用容差 0.05 秒的 `AVAssetImageGenerator`（core 那张无限容差接口对长 GOP 视频会把整条胶片都取成同一帧），现在每秒一帧都是真画面。

### Mac-V2.7.1 · 分割类图标换成参考图

- 分割 / 向左分割 / 向右分割 不再用 SF Symbols 的剪刀和箭头，改成自绘图标（`Canvas` 画的「括号 + 虚线」）：分割是两个相对的括号，向左分割是实线括号 + 右侧虚线（右半被裁掉），向右分割是左侧虚线 + 实线括号，和参考图一致。
- 时间轴两端各留 100pt 空白滑动距离（合计 200pt）：默认片段起点贴着左边（空白留给用户自己拖），往回能再滑 100pt 看到空白，滑到尾部还能再滑 100pt；滑杆的可视比例按「含空白的总宽」算，所以滑块会比之前略短。

### Mac-V2.7.2 · 六个工具图标按参考图重绘

- 撤销、重置、分割、向左分割、向右分割、删除六个图标全部改成 `Canvas` 自绘（`MacEditorGlyph` + `MacGlyphButton`），不再混用 SF Symbols：统一 26pt 设计栅格、方头粗线。
- 撤销 / 重置是一对镜像的半圆回转箭头（底部横线 → 半圆 → 顶部横线），末端只有一根斜向小刺，不再是 SF 那种双撇箭头；半圆用折线拼出来，避开 `Path.addArc` 在不同坐标系下的方向歧义。
- 分割是两个短脚括号 `][`，向左分割是「括号 + 右侧方块虚线」，向右分割是「左侧方块虚线 + 括号」；虚线=被裁掉的那一侧。
- 删除是满宽桶盖 + 中央小提手 + 近满宽方形桶身，比之前的 SF 垃圾桶更接近参考图那种方正的剪映风格。

### Mac-V2.7.5 · 刻度尺贴顶 + 正方形缩略图

- 时间轴刻度尺固定在编辑面板顶部（紧贴上方工具条），轨道在剩余空间居中后再整体上移 50pt，横向滑杆留在最底部。
- 胶片缩略图从「间隔 × 每秒像素」的矩形改成固定 `trackHeight × trackHeight` 的正方形（87pt），圆角 6pt。

### Mac-V2.7.6 · 缩略图密度重定义 + 手势平移

- 缩放状态从「每秒多少像素」改成「一张缩略图覆盖几秒」：默认 `60/16 = 3.75s`（每分钟 16 张），放大一档分母 ×1.5（`60/24`、`60/36`、`60/54`…）直到 `1/30s`（每秒 30 帧）为极限；缩小一档 `×2`（`60/8`、`60/4`），`60/4` 已是最小宽度。每秒像素始终等于 `87 / 间隔`，所以一张正方形正好占一个间隔的宽度，胶片严丝合缝。
- 编辑区可以不用按钮也能平移时间轴：轨道上方的空白带和轨道下方到滑杆之间的空白都支持鼠标拖拽（抓手光标），滚动轮 / 触控板横向滑动在时间轴范围内也能平移（`ScrollWheelPanReader` 只吞掉落在时间轴内的横向滚动，Shift + 竖向滚轮等价于横向）。
- 修掉胶片后段空白：槽位 key 用的是素材时间（片段入点 `clip.start`），而渲染窗口用的是时间轴时间，两者相差一个入点偏移，导致只画到「入点 + 可视长度」就停。现在 `MacTimelineView` 先把可视窗口按「片段在时间轴上的累加起点」映射回素材时间再决定渲染区间，模型补帧窗口也做同样映射。

### V1.0.4 · List 页收敛

- 去掉文件夹区域的布局切换按钮（列表 / 卡片），固定列表展示；卡片视图代码一并移除。
- 去掉文件夹标题右侧的 `All` 入口。
- 统计卡从「视频 / 文件夹 / 占用」改为「视频 / 占用空间 / 总时长」，整块可点，点进去就是全部视频列表（原来 All 的去处）；卡片上不显示右指向箭头，点击提示只靠卡片本身。
- 文件夹内页不再显示统计卡，进目录直接看子文件夹与视频。
- 搜索时（关键词非空）首页也不显示统计卡，页面直接呈现「搜索结果」，避免搜索时还占着顶部统计的空间。

### V3.4 · 真机调试反馈

- Cut 页「最近编辑」为空时，空态里不再给「从文件导入」按钮（导入入口只保留上面那块「从相册选片」）。顺手把 Cut 页整条没再造按钮引用的文件导入代码删干净（`showFileImporter` / `FileImportPurpose` / `handleFileImport`），不再留死代码。
- 设置项跟着「功能选择」联动：Cut 关了（`tab.cut.visible = false`）就没有导出这回事，整组「导出 · 导出清晰度」隐掉；List 关了则整组「播放 · 默认循环播放」隐掉。存储、关于两组不受影响。
- 设置里删掉「存储 · 素材占用」这一行，存储组只剩「清理缩略图缓存」（占用空间在 List / Mine 的统计卡上看就够了）。
- List 页根目录一个文件夹都没有时，文件夹区给一张引导卡：`folder.badge.plus` 图标 + 「还没有文件夹」+「点击右上角，新建文件夹就会出现在这里。」，和下面「根目录还没有视频」的空态排在一起。

### V3.5 · 一键提取文本

- Cut 页热门工具里「一键成片」换成「一键提取文字」，点击进独立页面，不再走「开发中」提示。页面自带导航栈、左上「关闭」，内容依次是能力介绍（画面文字 + 声音，可只取一种也可两种都要）、中央虚线大按钮「从相册中选片」、两个开关、「说明」卡（软字幕轨道读不到、音乐/多人/方言会降准确度）。
- 两个开关「画面字幕文字」「声音转文字」默认都开，至少留一项（关到只剩一项时那一项禁掉），值存本地 `UserDefaults`（`text.extract.frames` / `text.extract.speech`），下次进来还是上次的选择。
- 选中相册视频后先算估时（`1.5 + 0.06×时长` 的画面 + `1.2×时长` 的声音，约 24s 素材报「约 32 秒」），弹「开始提取？」确认框，写明处理期间屏幕常亮、不要锁屏或切 App；确认后才开始跑。
- 处理中整屏刷黑（`#0D0D0F`，连 sheet 底色一起换，避免顶部漏出浅色圆角），正中一颗会呼吸的白色光球，内部是主题暖色流光（`Theme.accent` #FF5C3D → `accentSecondary` #FF9A6B → 浅橙，11s 转一圈，顶部叠一层柔光做玻璃球质感），球下方「文字提取中 17%」+ 一行灰字「正在识别画面文字，请不要锁屏或切换程序」；顶部只留一个返回箭头，左上角点它弹「停止提取？」确认后中止（已识别的文字一并丢弃，视频不受影响）。期间 `isIdleTimerDisabled = true` 保持不息屏，导航栏隐藏，`interactiveDismissDisabled` 防止下拉关页，结束/失败/取消都会复位。
- 流程：画面这条路按 0.5s 抽帧（`AVAssetReader`，BGRA），用 Vision `VNRecognizeTextRequest`（`.accurate`、中英双语、语言纠正）逐帧识别，按 boundingBox 从上到下拼行，相邻帧文本相同就合并延长结束时间，带 `preferredTransform` 处理竖拍旋转；声音这条路先把音轨导成 m4a，再按 30s 切片喂 `SFSpeechAudioBufferRecognitionRequest`，「词级片段按 0.7s 停顿合并成句」（中文不留空格、英文补空格），时间码按切片偏移还原成全片时间；语音失败不中止画面结果，只往 warnings 里记一条。
- 语音识别优先挑支持端上识别的语种（zh-CN → zh-Hans-CN → en-US → en-GB，离线、不上传）；设备没有端上模型时退回在线识别，并新增 `NSSpeechRecognitionUsageDescription`（「把视频里的说话内容转成文字，识别在本机完成，不上传。」）。模拟器上实测：端上模型不可用 → 走在线识别，38 条语音行正常出字。
- 结果用 sheet 展示：warnings 置顶，每条「起止时间码 + 来源胶囊（画面橙色 / 语音蓝色）+ 文本」，底部「复制全部文字」（进剪贴板 + toast「已复制 N 条文字」）和「共 N 条 · 画面 x / 语音 y」统计，左上「取消」直接关。
- 提取页用 `fullScreenCover` 呈现（原来是 sheet，处理时父页面会在顶部露出一条浅色边），页内仍是 `NavigationStack`，日常态有导航栏、处理态隐藏。
- 调试钩子：`-openTextExtract YES`（带素材库首个视频进页面）、`-textExtractPageOnly YES`（只开空页面）、`-textExtractSkipConfirm YES`（跳过估时确认直接开跑）。sheet 用 `sheet(item:)` 承载（`TextExtractRequest`），否则内容闭包会拿到未落库的 `nil` URL。

### V3.6 · 一键人脸打码

- Cut 页热门工具里「智能字幕」换成「一键人脸打码」（`face.dashed` 图标），点进去是独立页面：能力介绍卡、中央虚线大按钮「从相册中选片」、四种打码方式（马赛克 / 高斯模糊 / 纯色黑块 / 模糊 + 轻噪点）各带一句人话说明和示意图标，末尾一张「说明」卡（重编码会有轻微画质损失、侧脸/被挡住的脸/画面里很小的脸可能漏检）。四条规则细节见每条说明：马赛克块大小 = 脸宽/12，模糊半径跟着脸宽走，黑块最保险但不好看，模糊 + 轻噪点抗「人脸还原」工具的效果稍好。
- 选中的方式存本地 `UserDefaults`（`face.mask.style`，见 `FaceMaskPrefs.styleKey`），下次进来还是上次那条。
- 选中相册视频后先算估时（`1.5 + 0.9×时长`，模糊 + 轻噪点再 +0.1×时长），弹「开始打码？」确认框写明「预计需要约 N 秒，处理期间请不要锁屏或切换 App」；确认后才开跑。
- 处理中整屏黑场（`#0D0D0F`）+ 正中一颗主色系光球（`Theme.accent` #FF5C3D → `accentSecondary` #FF9A6B → 浅橙 #FFD4BC 的 11s 流光 + 2.2s 呼吸，外层白泛光），球下「人脸打码中 17%」+ 灰字「正在定位并遮挡人脸，请不要锁屏或切换程序」；顶部返回箭头弹「停止打码？」。期间 `isIdleTimerDisabled = true`，结束/失败/取消都复位。
- 完成后进结果页：`AVPlayer` 预览 + 可拖动进度条（一碰进度条就暂停播放、松手也不自动续播，拖到哪停哪，方便停住看清某一帧有没有漏打；页面里不再放「拖动进度条…」那句说明文案），标签行是「检测到 N 个人 / 时长 / 所用方式」（挪到标题下方），视频播放区不再限 9:16 / 430pt，而是一路向下填满到屏幕底部安全区，播放键和时间条压在视频卡片底部；底部动作条和「存入素材库」「再打一条」全部去掉，只有右上角一个「保存」，点了直接存相册并 toast「已保存到相册」。
- 检测链路：`AVAssetReader` 逐帧 BGRA → 按 `preferredTransform` 摆正（`orientation` 已是 `.up`，不能再把 transform 传给 Vision，否则会转两遍、竖拍视频一张脸都检不出）→ 缩到 720 长边 → Vision `VNDetectFaceRectanglesRequest` revision 3 → 按位置串轨迹（`FaceTracker`，Vision 跳帧时 uuid 不稳，所以按中心距离匹配，同一张脸不会重复计数）→ `CIPixellate` / `CIGaussianBlur` / 纯色 / 模糊+噪点 合成 → `AVAssetWriter`（h264，码率 ≈ w·h·fps·0.10）+ 原音轨透传。
- 检测节奏按实测耗时自适应：每帧算一次检测耗时做 EMA，>120ms 就放稀（最多每 8 帧检一次），<40ms 就加密（最快每 2 帧），慢机器自动变快、快机器少漏检。
- **踩到的坑（就是「检测不到人脸」的原因）**：这台 Intel Mac 上的模拟器建不了 Vision 的 GPU/Metal 推理上下文，`VNImageRequestHandler` 一跑就抛 `Could not create inference context`，退回的 `CIDetector` 在模拟器里也全返回 0（拿素材库里九条视频、每秒抽帧扫一遍都是 0，而同一帧在 macOS 原生 Vision 上是能检出 1 张脸的）。解法是给 `VNDetectFaceRectanglesRequest` 开 `usesCPUOnly`（iOS 16 起标记废弃，但仍是唯一公开入口）——CPU 推理下同一帧稳定返回 1 张脸；代码里 `#if targetEnvironment(simulator)` 直接走 CPU 推理，真机上仍然 GPU 优先、失败才降 CPU，再不行才退 `CIDetector`。
- 调试钩子：`-openFaceMask YES`（素材库首个视频进打码页）、`-openFaceMaskTest YES`（用 `Documents/face-test.mp4`）、`-faceMaskPageOnly YES`（只开空页面）、`-faceMaskSkipConfirm YES`（跳过估时确认直接开跑）、`-faceMaskMock YES`（用固定框验证渲染链路，绕过检测）。
- 模拟器实测（8s / 1080×1920 竖拍口播片段，人物正脸）：检测 240 帧里每帧 1 张脸、人脸计数 1，四种方式写出正常 mp4；耗时 70s，其中检测 3.6s、掩码合成 0.1s、渲染 65s（软件渲染慢，真机走 Metal 会快得多）。
- 已知未做：侧脸 / 遮挡 / 画面里很小的脸仍可能漏；不支持手动补框；macOS 端未同步。

### V3.7 · 一键视频增强

- Cut 页热门工具里「AI 画质增强」换成「一键视频增强」（`sparkles` 图标），点进去是独立页面，结构和 V3.6 打码页同构：能力介绍卡、中央大按钮「从相册中选片」、「增强方式」两张开关卡、「说明」卡。
- 两类增强可任意勾选（默认两个都勾，选择存 `UserDefaults`：`enhance.audio` / `enhance.video`）：`音质优化`（降噪 / 去混响：高通 90Hz 去低频轰鸣 + 有界噪声底的自适应下行扩展（安静处约 −8 dB，有效信号 0 dB）+ 门控后按原始峰值归一化 + 软限幅 0.92）、`画面优化`（每帧 CIExposureAdjust +0.12EV、对比度 1.12、饱和 1.08、亮度 +0.015、CISharpenLuminance 0.35）。都不勾时开关卡下方提示「至少要勾一个」。只勾音质优化时视频轨走 passthrough 直接透传，不再逐帧重编码。
- 选片后按勾选项估时（`1.2 + 0.85×时长（画面）+ 0.3×时长（音质）`）弹「开始增强？」确认框，写明「预计需要约 N 秒，处理期间请不要锁屏或切换 App」。
- 处理中整屏黑场 + 主色光球（复用 `ProcessingOrb`），球下「视频增强中 55%」+「正在处理画面 / 正在处理声音，请不要锁屏或切换程序」；顶部返回箭头弹「停止增强？」，期间 `isIdleTimerDisabled = true`。
- 完成后进结果页：顶部「关闭 / 增强完成 / 保存（右上角橙色）」，标签行「时长 / 音质优化 / 画面优化」，视频预览 + 播放键 + 可拖动进度条（碰进度条即暂停、松手不续播），视频区一路铺到屏幕底部安全区。
- **踩到的坑（管线设计）**：
  - 一开始把「处理后的 PCM 音轨」和「h264 视频轨」挂在同一个 `AVAssetWriter` 上、先写完视频再补音频，结果写了 40 多帧后 `videoInput.isReadyForMoreMediaData` 永远为 false（writer 停在 `.writing` 也不报错）——AVAssetWriter 要按时间戳交错落两轨，音频一路没数据时视频写不动。改成三步走：先把声音单独处理成一个 m4a（独立 writer，音轨独占），再逐帧写一个无声的 h264 mp4，最后 `AVMutableComposition` + `AVAssetExportPresetPassthrough` 把两轨封到一起（只重封装，不二次编码）。
  - 处理后的 PCM 重新打包成 `CMSampleBuffer` 时，`CMBlockBufferCreateWithMemoryBlock` 传 `memoryBlock: nil` 建出来的空 block 取不到数据指针（`CMBlockBufferGetDataPointer` 失败），得自己 `malloc` 一块内存、用 `kCFAllocatorMalloc` 交给 block 托管再填数据。
  - 归一化不敢「边读边算峰值」，否则前半段不知道后面多大声；改成两遍：第一遍只跑高通、不经过门控量**原始**峰值（不落盘），第二遍用同一套确定性处理再算一遍并按 `gain = min(0.9/peak, 20)` 输出（V3.7.1 起上限从 8 倍放宽到 20 倍，并与门控解耦）。
- 调试钩子：`-openEnhanceTest YES`（优先用 `Documents/enhance-test.mp4`，没有就退回 `face-test.mp4`）、`-enhancePageOnly YES`（只开空页面）、`-enhanceSkipConfirm YES`（跳过估时确认直接开跑）。
- 模拟器实测（0.6s / 1080×1920 竖拍片段，1080×1920 输出）：输出 mp4 含 h264 视频轨 + AAC 44.1k 立体声音轨（80kbps），视频码率约 12Mbps；音频 RMS 0.169（源 0.197，高通 + 门限后略降），峰值 0.91 说明归一化生效。这台 Intel Mac 模拟器上渲染仍是瓶颈（0.6s / 18 帧约 1 分钟），真机走 Metal 会快得多。
- 已知未做：去混响只是「压混响尾巴」的轻量版，不是真正的频谱去混响；降噪对持续底噪有效、对人声回叠无能为力；估时常数还是经验值，未按真机校准；保存只进相册，不自动进素材库；macOS 端未同步。

#### V3.7.1 · 一键视频增强：音质优化实际没生效的修复

- 现象：真机对比听下来「音质优化」几乎没有变化，只有一点点变亮 / 变干净。
- 根因：噪声底估计 `noiseFloor = min(max(framePeak, nf*1.0008), nf*1.05+0.0004)` 的下界和上界都是**乘法增长**，安静时也至少每帧 +0.08%，44000 帧/秒下 1 秒就能从 0.02 涨到 1e14 量级；`threshold = 2.2 × nf` 随即变成天文数字，`gate` 被 `max(0.15, …)` 永远钳在 0.15。整条音轨实际等于「固定 −16.5 dB + 补增益被封在 8 倍（+1.6 dB）」，软压缩因为信号已低于 0.6 从不触发，归一化只在峰值 ≥0.75 FS 时生效。
- 修复：
  - 噪声底改成有界、快降慢升：安静时按 30 ms 时间常数跟到当前包络，变吵时最多 0.5 dB/s 爬升，且永远不超过当前包络；门增益按 `env / nf` 连续映射到 0.35…1（安静处约 −8 dB，有效信号进来即 0 dB），再加 8 ms 平滑避免“抽气”声。
  - 所有时间常数改为按秒定义、按真实采样率换算（原来是按“每缓冲”写的，逐采样跑时 15 ms 被压成 0.7 ms）。实测 0.3 幅度 997 Hz 突信号 → 间隙 0.02 底噪：有声段 gate 1.000，空隙段 0.406（−7.8 dB），不再全轨恒定 −16.5 dB。
  - 峰值测量与门控解耦：第一遍只走高通量原始峰值，增益上限放到 20 倍（+26 dB），归一化对所有素材都成立。
  - 增益施加在门控之后，末尾加 0.92 的软限幅兜尖峰。
  - 只勾音质优化时视频轨 passthrough，不再重编码（省掉 0.85×时长和一次代际损失）。
  - `floats()` 改用 `CMBlockBufferCopyDataBytes`（分块缓冲不再越界读），采样率 / 声道数从音轨 ASBD 读取，单声道素材不再被当成双声道错位处理；进度按 PTS 算，不再用 `index/(index+6)` 这种永远到不了 1 的公式。
- 仍待做：真正的频谱降噪（vDSP STFT 谱减 + 最小统计噪声估计）和去混响，门控做不到「降噪」，只做 −3 dB 的轻度抑制。

### V3.8 · 一键提取人脸

- Cut 页热门工具四宫格（2×2）顺序：一键提取人脸（`person.crop.rectangle`）→ 一键人脸打码 → 一键视频增强 → 一键提取文字；原来占位的「一键去水印」入口已删除（功能仍未做）。
- 点进去是独立页面（`Features/FaceExtract/`，结构沿用打码 / 增强页）：能力介绍卡（三条 bullet）、「取帧间隔」卡（滑杆）、中央 54×54 圆角「+」大按钮「从相册中选片」、底部「说明」卡（侧脸 / 遮挡 / 小脸可能抓不到、最多 80 张、同一张脸只留质量最好的一帧、原视频不动）。
- 「取帧间隔」是滑杆，范围 1…10 秒取 1 帧，1 秒/帧是最细的一档（也是默认），10 秒/帧最省时间；松手写回 `UserDefaults`（`face.extract.interval`，见 `FaceExtractPrefs`），下次进来还是上次那个间隔。卡片右下角实时显示「每 N 秒 1 帧」。抽帧条件就是这个间隔（`FaceExtractor.run(url:frameInterval:)` 里 `pts - lastSample >= interval`），弹框里的「抽检 N 帧」= 时长 ÷ 该间隔。
- 选片后不直接开跑，先在视频中间取 3 帧实测 `Vision` 检测耗时（第一帧含模型初始化直接丢掉，剩下两帧取平均），再按 `1.0 + 抽检帧数（时长 ÷ 所选取帧间隔）× 每帧耗时 × 1.25` 折算整段耗时。所以估时是个体化的：这台 Intel Mac 模拟器上 8 秒片、1 秒/帧时实测约 2～3 秒（真机会更快），拿不到实测值时才退回每帧 60ms 的兜底。
- 估完弹一张自绘确认卡（系统 `alert` 不支持字重/字号变化，加粗会失效）：标题「开始提取人脸？」、一行元信息「视频 00:08 · 每 1 秒 1 帧 · 8 帧」，中间一行小字「按本机速度预计需要」+ 22pt 半粗主色「约 5～6 秒」（不上底色，只靠字号和颜色跳出来），下面是「取消 / 开始提取」两个按钮；「处理期间请不要锁屏或切换 App」那句提醒已删掉（处理蒙版上本来就有）。点「开始提取」才开跑，点取消则清掉临时文件。
- 处理中整屏黑场 + 复用 `ProcessingOrb` 光球，球下「人脸提取中 37%」+ 灰字「正在逐帧扫描人脸，请不要锁屏或切换程序」；顶部返回箭头弹「停止提取？」（已扫过的丢弃、原视频不受影响）。期间 `isIdleTimerDisabled = true`，完成 / 失败 / 取消都复位。
- 完成后进结果页：顶部「关闭 / 提取完成 / 保存」，标签行「共 N 张 / 时长 / 3:4 裁切」，下面三列网格铺满所有脸，每张左下角压一个入镜时间码角标，点任意一张全屏看大图。右上「保存」一次性把所有图片写进系统相册（`PHPhotoLibrary.performChanges` 里逐条 `PHAssetCreationRequest.addResource`，`.addOnly` 授权），成功后 toast「已保存 N 张到相册」。
- 检测链路：`AVAssetReader` 逐帧 BGRA → 按 `preferredTransform` 摆正（同打码页的坑：摆正后不要再把 transform 传给 Vision）→ 缩到 720 长边 → Vision `VNDetectFaceCaptureQualityRequest`（顺带拿 `faceCaptureQuality` 作为择优依据）→ 失败退 `VNDetectFaceRectanglesRequest` rev3 → 再退 `CIDetector`。每张脸的框按「脸高 ×2、3:4 竖版、中心上移 0.15 倍脸高」裁切并夹进画面边缘，最短边小于 48px 的小脸直接丢。
- Vision 后端按「GPU → CPU（`usesCPUOnly`）→ CoreImage → 放弃」一次性降级，同打码页：这台 Intel Mac 的模拟器建不了 GPU 推理上下文，靠 CPU 那级才出结果；降级只试一次，不会每帧白跑一遍失败请求。
- 去重：同一秒内和已有轨迹 IoU > 0.35 且时间跨度 < 1.6s 视为同一张脸；新帧质量分比已存的 > 0.06 才替换，所以吐出来的是「每个出现过的人一张最清楚的图」。超过 80 张时按质量分取前 80 张，再按时间排序输出。
- 调试钩子：`-openFaceExtractTest YES`（用 `Documents/face-test.mp4`）、`-faceExtractPageOnly YES`（只开空页面）、`-faceExtractSkipConfirm YES`（跳过估时确认直接开跑）、`-faceExtractAutoSave YES`（出结果后自动存相册，验证批量保存）；取帧间隔可以通过启动参数直接指定，例如 `-face.extract.interval 5`。
- 模拟器实测（8s / 1080×1920 单人出镜片段）：1 秒/帧（8 帧）扫完约 3 秒，同一张脸去重后 1 张，裁出 276×367 的 3:4 竖图（源画面里脸本身只有约 183px 高，裁切不放大，保持原始像素）；5 秒/帧时弹框报「每 5 秒 1 帧 · 2 帧 · 约 2 秒」；三列网格 + 时间码角标正常，`faceExtractAutoSave` 批量写入相册 1 张成功（`DCIM` 里多出一张 276×367 的 JPG）。
- 已知未做：侧脸 / 遮挡 / 小脸仍可能漏；只出图不自动进素材库；macOS 端未同步。

#### V3.8.2 · 全工程 review：告警清零 + 修掉三类隐患

- 编译告警从 64 条清到 0 条：`AVAsset.tracks(withMediaType:)` / `preferredTransform` / `naturalSize` / `nominalFrameRate` / `timeRange` / `formatDescriptions` 这批 iOS 16 起弃用的同步 API，全部换成 `loadTracks` / `track.load(...)` 的异步写法（`FaceMaskService`、`VideoEnhanceService`、`TextExtractor`、`FaceExtractService` 同步改；`writeVideo`、`screenLines` 顺势从同步 `throws` 改成 `async throws`，调用点补 `await`）。顺带清掉 `MPVolumeView.showsRouteButton`（iOS 13 弃用）与 `NavigationLink(isActive:)`（iOS 16 弃用，改成 `navigationDestination(isPresented:)`）。
- 新功能两个真 bug：① 去重时间窗原来写死 1.6s，取帧间隔拉到 2 秒以上时每帧都会开新轨迹，同一张脸被重复出图——改成 `trackWindow = max(1.6, 间隔 × 1.5)`；② 「提取失败」的 `alert` 挂在选片页的子树里，进了结果页后这棵子树已经不在图层树里，保存失败之类的错误根本弹不出来——把 `alert` 抬到根 `ZStack`。
- 健壮性：`AVAssetReader` 读失败不再当成「扫完了」静默返回，补 `reader.status == .failed` 抛错；`taskBox` 从 `private let` 改 `@State`（人脸提取 / 打码 / 增强三页同改），SwiftUI 重绘不会再把运行中的 `Task` 丢掉，取消按钮才真的能取消；保存后置 `hasSaved`，防止重复点「保存」把同一批图写两遍相册。
- 顺手修掉一个既有功能 bug（打码 / 增强共用）：`一键视频增强` 对 22.05kHz 这类低采样率素材重编码音轨时会直接「Cannot Encode Media」失败——原因是对 22.05k 单声道也给了 96kbps/声道的码率，超出 AAC 编码器允许范围。改成按采样率折算 `min(96k, 采样率 × 2.5)` 并保底 24kbps，`enhance-test.mp4`（22.05k 单声道）现在能正常出片。
- 回归结果（iPhone 15 Pro Max / iOS 17.2 模拟器，clean build 0 warning）：打码 `-openFaceMaskTest` 检出 1 人、00:08 出片且人脸被遮；增强 `-openEnhanceTest` 音质 + 画面都完成、00:01 出片；文字提取 `-openTextExtract` 出 19 条（画面 14 / 语音 5）；List 落库的 `-openFirstFolder YES` 深链正常。人脸提取本次未再跑，逻辑改动只涉及元信息读取与去重时间窗。

#### V3.8.3 · Bugfix：相册重选、成片音轨、导出回导

- 相册「再选一次没反应」：`PhotosPicker` 的绑定 `photoItem` 选完不清空，再选同一段视频时值没变化，`onChange` 不触发，看起来就是点了没反应。四个工具页（打码 / 增强 / 文字提取 / 人脸提取）改成在 `onChange` 里先把 `photoItem = nil` 再起 `Task`；Cut 从相册选片、List / 文件夹导入原本就在 `defer` 里清空，逻辑不变。
- **打码成片一直是无声的（真 bug，不是新功能带来）**：原来想「音轨透传」，给 `AVAssetWriter` 加的是 `outputSettings: nil` 的音频输入，但这个输入在 mp4 上 `writer.canAdd()` 直接返回 false（模拟器实测打日志确认 `input=n`），音轨根本没进去。改成两段式：先写无声的 h264 mp4，再用 `AVMutableComposition` + `AVAssetExportPresetPassthrough` 把原音轨（按 `timeRange` 裁到视频长度）封回去。`face-test.mp4` 复测：输出 1 条视频轨 + 1 条 AAC 22050 单声道音轨，音频 RMS 0.137、峰值 1.02，确认有声。
- 剪辑导出加了两层保险：① `VideoExporter.export(videoURL:trimRange:)`（单段 / macOS 用）和 `buildComposition` 都按音轨真实 `timeRange` 裁起止再插入——以前 `try? insertTimeRange` 吞掉「音轨比视频短 20ms」的插入失败，会直接导出一条没有音轨的片子；② `EditorViewModel.export()` 出片后自检：没有视频轨、时长读不出来，或源片有声音而成片没音轨，直接报错「导出的视频没有声音轨道，请重试」，不再把无声片存进相册 / 素材库。
- 素材库入库校验：没有视频轨、时长 ≤ 0.01s、或连封面都抽不出来的文件，一律拒绝（`VideoImportError.unsupported`），避免坏文件变成一条点开黑屏的记录。
- 回导实测（iPhone 15 Pro Max / iOS 17.2 模拟器）：剪辑导出（单段 / 两段 / 变速 / 混速 / 调音量）都能读、`dur` 正确、音频 RMS 0.08～0.14；增强成片 0.6s、音视频轨齐全、RMS 0.172；打码新成片 8s、音轨齐全、可入库并生成封面；打码旧成片（修复前）确认 audio=0；人为截断的坏 mp4 入库被拒（提示「无法读取该视频，请换一个文件试试」）。

### V4.0 · App Icon

- 有了正式图标（此前 `AppIcon.appiconset` 是空的，装到手机上就是白灰方块）：炭黑底 `#15171B` + 右上暖橙光晕，主体是主题色 `Theme.accent`（`#FF5C3D` → `#FF9A6B`）渐变的播放三角，中间被一道斜切缝劈开——一眼是「播放」，第二眼是「剪辑」，对应 Cut / List 两条主线。
- 只有一张 1024×1024 的源图 `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`，`Contents.json` 是 Xcode 15 的单尺寸（universal / ios / 1024x1024）写法，其余尺寸由 Xcode 自动出（构建产物里能看到 `AppIcon60x60@2x.png`）。
- 换图标只需替换这张 `AppIcon.png`（保持 1024×1024、不要预圆角、不要透明通道），改完重新 build 再 install，模拟器/真机桌面图标才会刷新。

### V4.0 · Cut 草稿

- 剪辑页离开（返回、切后台、关页）时把现场存成草稿：分段区间、每段倍速与音量、播放头位置，按视频 id 存在 `UserDefaults`（`leogotoplay.editor.drafts`，见 `EditorDraftStore`）。V3.6 起只要打开过一次就一定落一份草稿（不再判断「有没有真改过」，也不再因为退回原始整条而清掉旧草稿）。
- Cut 页「最近编辑」里，卡片一律当作草稿：右上角都带橙色「草稿 + 成片时长」角标（还没打开过的按原片时长显示）。点这张卡进剪辑页会直接还原上次现场（几段、从哪下刀、停在哪一帧），不是从头一条完整片段。
- 相册 / 文件临时导入的视频不留草稿（临时文件用完即删，没有稳定身份）。
- 「最近编辑」里长按卡片只有两项：「编辑」（进剪辑页，等同点卡片）和「删除」。删除会弹确认框「删除「标题」？」，确认后连素材库里的文件、缩略图、草稿一起删掉，相册里的原片不受影响，删完 toast「视频已删除」。

### V4.0 · Mine 功能完善

- Mine 页新增独立入口「功能选择」，排在「导出与播放设置」上面（不塞进设置页）：点进去只有一个分组、两个开关，显示英文名 `List` / `Cut`，可以二选一也可以都开。关掉的那个不再出现在底部 Tab 栏，Mine 恒定显示；两个至少保留一个（只剩一个时另一个开关置灰）。入口那一行的副标题实时反映当前选择（`List + Cut` / `List` / `Cut`）。开关值存 `UserDefaults`（`tab.list.visible` / `tab.cut.visible`，见 `TabPrefs`），冷启动仍然生效。
- 底部 Tab 栏由系统 `TabView` 改成自绘：iOS 17 的 `TabView` 在子页数量变化后会留下空白页，用 `.id` 强制重建又会把正在显示的设置弹窗一起关掉。新实现用 `VStack { 三个常驻页面 ZStack + 自绘 Tab 栏 }`，切 Tab 不丢各自的导航栈 / 滚动位置，拦腰关掉某个 Tab 时页面和弹窗都不受影响。
- 设置里关掉当前所在 Tab 时，自动落到第一个可见 Tab；深链（`leogotoplay://cut` 等）也会跳过已隐藏的 Tab。
- 「功能选择」页里 List / Cut 两行各加高 20pt（44pt → 64pt，实测行距 64.3pt），开关更好按。
- 关掉哪个 Tab，对应能力一起收口：List 关闭时，剪辑页导出的确认框里不再出现「存入素材库」，只剩「保存到相册」（素材库页都没了，没地方放）；Cut 关闭时，List 页（含文件夹页、全部视频页）长按视频的菜单里不再出现「剪辑」，播放页右上角「更多」里也不再出现「剪辑」（剪辑页入口已隐藏）。

### V3.2.1 · 播放页控制层

- 暂停态控制层常驻：`scheduleAutoHide` / `scheduleLockAutoHide` / `bumpActivity` 都先判断 `viewModel.isPlaying`，不播就不排 3 秒计时；新增 `.onChange(of: viewModel.isPlaying)`，暂停时取消计时并把控件（含锁模式按钮）重新显示出来，继续播放时才重新开始 3 秒倒计时。计时任务醒来后也会再查一次播放状态，避免暂停瞬间被旧计时误关。
- 从列表进入播放页默认直接播放：`PlayerViewModel.init` 里 `playImmediately(atRate: 1)` + `isPlaying = true`（以前是建好 `AVPlayer` 停在暂停态，等用户点播放），页面 `.task` 里再兜一次 `play()`。
- 两侧亮度 / 音量手势收紧：只在控制层可见时生效（`.allowsHitTesting(!isLocked && controlsVisible)`，`sideDrag` 里再 `guard controlsVisible`），并且必须先判定为竖直方向（`|Δy| > |Δx|` 且 > 4pt）才进入调整，横向划屏不再弹滑杆、不再误改亮度。
- 底部控制区整体上移 45pt：`bottomPanel` 的 `.padding(.bottom)` 20 → 50 → 65（两次分别上移 30pt、15pt）。

### V3.3 · 剪辑页交互打磨

- 时间轴改成「固定居中播放头 + 胶片可平移」：白色播放头固定在正中，胶片按 `stripX = width/2 - (成片时间/总时长)*width` 平移，两侧各留半个屏幕的滑动余量，滑空的区域铺淡色空轨道。拖动 = 平移 + 同步 scrub，松手保持位置不回弹（位移 < 6pt 的轻点才把被点时间送到播放头位置）。
- 整页比例按参考图重排：预览区按内容区高度取固定比例（`0.60 × 内容区高`，约 54% 屏高，原先是 58%），限宽 `0.68 × 屏宽`、水平居中，两侧留黑底；预览上方留 30pt 呼吸位（整体下移）；时间轴 `trackHeight` 64 → 84；时间轴与工具条之间固定 30pt（原先是弹性间隔约 80pt）；工具条高度 88 → 58（图标 24 → 22、文字 12 → 11、单元宽 68），整条靠底、距安全区约 30pt。
- 拖动 / 点按时间轴时自动暂停：`onScrub` 先调 `EditorViewModel.pauseForScrub()`（仅在 `isPlaying` 为真时 pause），避免边播边 seek 造成画面来回跳；停下的位置就是松手位置，再点预览即可从这里续播。

### V3.1 · 剪辑页重构（分段式编辑）

- 顶栏只留「关闭 / 导出」两项：去掉右上角的「剪辑」标题、视频名副标题、「重置」按钮，以及「导出」左边那个画面比例（填充↔适应）圆钮。
- 预览下方新增播放条：左边「当前时间 / 总时长」，中间「后退 1 秒 · 播放暂停 · 前进 1 秒」三个按钮。
- 页面纵向顺序按参考图定稿：预览 → 播放条（左侧成片时间 / 右侧撤销·重做）→ 时间轴 → 底部横向滚动工具条：分割 / 删除 / 变速 / 音量 已实现，动画 / 滤镜 / 字幕 / 贴纸 / 转场 点了只提示「xx · 开发中」，留给后续扩展。播放条去掉了倒退/前进两个步进键，也不再放播放按钮：点预览画面即播放/暂停（播放中画面中央不显示播放图标）。时间轴上方那行「成片 · 段数 · 当前段」也整行删除，时长改由播放条左侧和段内角标呈现。右侧是撤销（`arrow.uturn.backward`）和重做（`arrow.uturn.forward`）两个按钮，不可用时降到 25% 透明度并禁用；`EditorViewModel` 里维护 40 步快照历史，分割 / 删除 / 变速 / 音量都会入栈，新操作会清空重做栈。点时间轴选区以外的地方（预览画面、页面空白处）都会取消选中，白框和把手一起消失；整页加了 `contentShape` + 根级 tap，只是兜底，工具条按钮与时间轴手势优先级更高。变速改成滑杆（0.25x–5.0x、步长 0.05，实时显示倍速并附「恢复原速」），松手才重建 composition，拖动过程不卡。
- 时间轴改成「固定居中播放头 + 胶片条可平移」：播放头永远是屏幕正中那根白线，胶片按 `stripX = width/2 - (成片时间/总时长)*width` 绘制，所以时间轴两侧各留半个屏幕的滑动距离（总行程 = 一屏宽，起点（0s）左半屏是空轨道、往后拖胶片从中间往左滑），空出来的位置画成淡色空轨道，不会显得像被截断。拖动时间轴 = 平移胶片 + 同步 scrub（拖动时 `onChange(of: playhead)` 不抢状态），松手保持当时的位置（不会回弹：只有位移小于 6pt 的轻点才把被点的时间送到播放头位置），播放时胶片自动跟随播放头滑动。
- 时间轴从原来的「双柄裁剪滑块」换成 `EditTimelineView`：整段胶片 + 分段框 + 播放头；点或拖时间轴移动播放头、点在某一划段上就选中它；被删掉的空隙压暗。选中态按参考图做成白色 3.5pt 描边（框与胶片同高、同起点，像素级对齐），选中段左右各加一个白色夹持把手（白色圆角块 + 中间一根深色竖条，外侧圆角、内侧贴齐胶片），未选中的段只有淡淡的边；进页面默认不选中任何段，点时间轴或点功能键才出现选中态；每段左上角带时长角标（如 `12.0s`，变速后显示该段的成片时长），变速段再加一个橙色 `1.5x` 角标。裁剪手柄随之取消，裁剪靠「分割 + 删除」完成。
- 时间轴按「成片时间」铺：删掉的片段不再占位置，剩下的片段自动首尾相接（段间留 2pt 纯黑缝，与播放头同宽，3x 屏上量到 6px），所以时间轴宽度 = 成片总时长、播放头位置就是成片时间；胶片帧也按成片时间重新取图（Core 新增 `generateFramesStreaming(forVideoAt:times:)`），分割 / 删除 / 变速后自动重铺。播放条上的当前时间/总时长同样改成成片时间。
- 选中逻辑：点时间轴任意位置会同时移动播放头并选中该段；点下方任意功能键也会先把播放头所在（或最近）的段选中再执行；「分割」时若播放头没落在该段内，自动从该段中点下刀。
- 剪辑模型从单一裁剪区间升级为分段 `Clip(start, end, speed, volume)`：预览和导出共用同一条 `AVMutableComposition`——各段按顺序插入、倍速用 `scaleTimeRange`、分段音量用 `AVAudioMix`，时间轴上的成片时长按倍速换算。
- 时间轴缩略图加载改快：新增 `ThumbnailService.generateFramesStreaming`，走 `generateCGImagesAsynchronously` 批量并行、容差放到最大（直接取关键帧）、尺寸 160，出图即回调；时间轴先铺灰色占位，再逐格把真帧填进去，不用等整条胶片算完。
- 导出踩了一个 AVFoundation 的坑：同一条 composition 里「既有原速段又有变速段」时 `AVAssetExportSession` 必定失败（AVFoundationErrorDomain -11800、底层 -16364），而把整条 composition 统一缩放却是正常的。所以新增的 `VideoExporter.export(sourceURL:clips:quality:)` 在有变速时改走两遍：先按「相邻同倍速」分组逐组导出中间文件（组内整条缩放），最后用 `AVAssetExportPresetPassthrough` 无损拼接。实测 2 段（0–6s 原速 + 6–45.8s 2x）导出得到 25.88s、1080×1920、带音轨的 mp4。
- 导出失败时的报错信息补全为「AVFoundationErrorDomain -11800 · 描述」，方便定位。
- DEBUG 新增启动钩子 `-openEditorFirst YES`，素材库首页可直接进剪辑页方便验证。

### V3.0 · Cut 页入口调整

- 顶部深色卡片去掉「LEOGOTOPLAY CUT」标题和两段说明文案，改成「热门工具」四宫格：AI 画质增强 / 一键去水印 / 一键成片 / 智能字幕；四项都还没开发，点击只弹「xxx · 开发中」提示，留着后续接功能。
- 卡片里的两个胶囊按钮（从相册选片 / 从素材库选）随文案一起去掉，选片入口统一收敛到下面两块卡片。
- 原来的「导入到素材库」「素材管理」两块卡片去掉，只留一个「从相册选片」入口（图标 `photo.stack`，走系统相册）：卡片通栏、左右两边与上方「热门工具」卡对齐，高度收窄（上下内边距 11pt），卡片里只有图标 + 「从相册选片」一行字（去掉了原来的副标题「从系统相册挑视频」），两者都居中；图标是 30pt 圆角方块，底色为主色 32% 的橙（从 16% 加深到 32%，避免按钮感太弱）、加号本身用主色（表达“添加”语义，避免大块纯色色块显得突兀）；卡片底色是 `Theme.accentSoftGradient` 的淡橙渐变（左上浓、右下淡）加 1pt 淡橙描边，高度再 +5pt（上下内边距 16pt），选完直接进剪辑器。
- 页面底部的「剪辑流程」（1 选片 / 2 裁剪 / 3 导出·入库）整块卡片连同 `workflowCard`、`flowStep` 代码一并删除，Cut 页现在只有「热门工具」「从相册选片」「最近素材」三段。
- 「最近素材」这一段改名为「最近编辑」，下面那行说明「点一下就能继续剪」删掉，只留标题。
- 「导入到素材库」和「从 List 中选片」两条从 Cut 页移除后：文件 / 相册导入素材库仍走 List 页右上角入口，从 List 选片仍走播放器外的素材库列表，能力没有丢。

### V2.6 · 锁按钮左移与滑杆按需浮现

- 锁按钮从右侧音量滑杆下方挪到左侧、亮度滑杆下方。
- 亮度滑杆和音量滑杆默认完全不显示；只有手指在左 / 右两侧区域按下并滑动时才浮出来，松手 1 秒后自动消失。
- 两侧触控区大幅加宽（竖屏 96pt、横屏 132pt，竖直方向覆盖滑杆高度），不用瞄准那根 6pt 细条就能调；滑杆本身不可点击（`allowsHitTesting(false)`），只负责显示。
- 百分比数字常驻占位、只切透明度，浮现时滑杆长度不会跳。
- 顶栏整排（返回 / 标题 / 横屏 / 更多）整体下移到灵动岛下方：竖屏顶部留白 62pt、横屏 58pt（iPhone 15 Pro Max 安全区顶部 59pt、灵动岛占 11~48pt），标题和按钮不会再被灵动岛盖住。

### V2.5 · 锁定态控件的自动隐藏

- 锁按钮从 32pt 放大到 48pt，并整体下移一点，更好按。
- 进入锁定状态后不再一直亮着：3 秒没有任何操作，锁按钮一起淡出；此时点一下屏幕，锁按钮重新出现并重新计时。
- 锁定态下进度条仍然显示但不可拖动（滑杆手势禁用、运输控件整排隐藏），同样 3 秒后随着锁按钮一起淡出，点屏幕再次唤回。
- 解锁后恢复正常控制层并重新开始 3 秒计时。

### V2.4 · 播放器全屏按钮常驻与锁定

- 横屏（全屏）播放时不再自动收起顶栏：返回按钮和横屏按钮一直留着，点横屏按钮回到竖屏正常播放，点返回按钮直接退出视频；底栏进度与播放控制仍然 3 秒后自动隐藏。
- 横竖屏切换只切换布局分支：`onAppear` / `onDisappear` / `.task` 都挂在最外层，切换分支不会触发 `onDisappear` 把横屏状态清掉（修掉了「点一下横屏立刻弹回竖屏」）。
- 音量滑杆下方新增锁按钮（默认 `lock.fill`）：点一下变成开锁图标 `lock.open.fill` 并进入锁定状态——所有按钮、进度条、左右滑杆和画面点击手势全部失效，屏幕上只留这一个开锁按钮；再点它恢复成正常控制。
- 锁定时会飘一条「已锁定，点击锁图标解锁」提示，横屏下同样生效；V2.5 起锁定态的锁按钮与进度条也走 3 秒自动隐藏，详见下一节。

### V2.3 · 播放器画面与横屏 / 投屏

- 视频默认按原始宽高比完整显示（aspect fit，多出来的部分留黑边），不再默认裁切填满；需要填满时仍可从「⋯」里切到画面填充。
- 右上角「⋯」左边新增横屏按钮（`iphone.landscape` / `iphone` 图标切换），点一下把播放页转成横屏，再点回到竖屏；退出播放页时若仍是横屏会自动恢复竖屏。
- 「⋯」菜单新增「投屏」：弹出的面板里是系统 `AVRoutePickerView`（AirPlay 设备选择），选中后画面投到电视 / 音箱，手机上的进度条依旧可控。
- 横屏实现：播放页把整页旋转 90° 铺满横向画面（按 430×932 换算出 932×430 的横屏画布），不改设备方向，其它页面固定竖屏；左右滑杆在横屏下自动缩短，避免撑破横向布局。

### V2.2 · 播放器控制层

- 右上角收起为「⋯」更多：点开弹出底部操作面板，内含剪辑、画面填充/适应、投屏；实现上用 Button + `confirmationDialog` 而不是 `Menu`，因为 `Menu` 自带的图标内边距会让这个圆形按钮和左边的横屏按钮上下错位。
- 进播放页时控制层全部展示；3 秒无操作自动淡出（顶栏、底栏、左右滑杆一起隐藏）。点画面立刻隐藏，再点一次重新出现并重新计时；播放、拖动进度、切上下一个、改倍速/循环、拖亮度音量都会重置计时。
- 打开倍速面板期间不自动隐藏。

### V1.1.0 · 播放器

- 播放控制居中：上一个 / 倒退 10 秒 / 播放暂停 / 前进 10 秒 / 下一个，五个按钮同一排；「上一个 / 下一个」在同一个文件夹的视频队列里循环切换。
- 同排最左是循环模式菜单：单曲循环（默认）/ 文件夹循环 / 列表播放 / 单曲停止。
- 同排最右是倍速按钮，点开是 0.25x–5x 的滑块（步进 0.05），当前倍速在滑块标题和按钮上同步显示。
- 画面填充开关从底栏挪到顶栏（视频右上角圆形按钮），底栏位置让给三段式控制。
- 播放器左右两侧各有一条竖向滑杆：左侧亮度（`UIScreen.main.brightness`），右侧音量（`MPVolumeView` 写系统音量，取不到滑杆时退回 `AVPlayer.volume`）。在两侧区域上下拖动即调整，拖动时滑杆高亮并显示百分比，松手 1 秒后收起。

### V1.0.5 · 空态与标题

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
