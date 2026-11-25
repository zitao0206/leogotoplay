# LeogotoPlay

`LeogotoPlay` 是一个视频工具 App 的双端工程：**iOS 版 + macOS 版**，共用一层端无关的 `LeogotoPlayCore`（Swift Package）。

两边都是同一套产品能力：

1. **素材库管理**：根目录直接导入 / 展示视频（与文件夹同一套列表 cell，含缩略图、名称.mp4、大小、添加日期、时长）→ 文件夹收纳（V1.0.3 支持多级子文件夹，V1.0.4 固定列表视图）→ 搜索 / 排序 / 移动 / 重命名 / 删除
2. **播放器**：进度拖动、倍速、循环、画面填充
3. **基础剪辑**：相簿 / 素材库视频 → 裁剪（时间轴双手柄）、静音 → 存回相簿或存入素材库，也可导出到用户指定的位置
4. **账号体系**：登录 / 注册 / 登录态持久化（本地演示实现，接口已抽象，方便接后端）

iOS 首页是 `Cut / List / Mine` 三个 Tab，结构由 `AppConfig` 驱动，可增删改序；macOS 用侧栏对应 `剪辑台 / 素材库 / 我的` 三个入口。

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
