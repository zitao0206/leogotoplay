import Foundation

// MARK: - Language

enum MacLanguage: String, CaseIterable, Identifiable {
    case en
    case zh

    var id: String { rawValue }
    var displayName: String { self == .zh ? "中文" : "English" }
}

/// Thread-safe current language, readable from any thread / background task.
enum MacLang {
    private static let lock = NSLock()
    private static var raw: String = UserDefaults.standard.string(forKey: MacLangKey) ?? MacLanguage.en.rawValue

    static var current: MacLanguage {
        get {
            lock.lock(); defer { lock.unlock() }
            return MacLanguage(rawValue: raw) ?? .en
        }
        set {
            lock.lock(); raw = newValue.rawValue; lock.unlock()
            UserDefaults.standard.set(newValue.rawValue, forKey: MacLangKey)
        }
    }

    static func toggle(to lang: MacLanguage) { current = lang }
}

let MacLangKey = "app.language"

/// Observable wrapper for views (drives live refresh).
final class MacLanguageStore: ObservableObject {
    static let shared = MacLanguageStore()
    @Published var current: MacLanguage = MacLang.current

    func set(_ lang: MacLanguage) {
        guard lang != current else { return }
        MacLang.current = lang
        current = lang
    }
}

// MARK: - Translation lookup

/// Localized string. `key` is the Chinese source text with `{1}`, `{2}`… placeholders.
func T(_ key: String, _ args: Any...) -> String {
    let template: String
    if MacLang.current == .en, let english = macStringsEN[key] {
        template = english
    } else {
        template = key
    }
    let text = macFill(template, args)
    return MacLang.current == .en ? macSingularize(text) : text
}

/// 英文里 1 后面接复数很扎眼，这里把 "1 videos" 之类的统一改单数。
private func macSingularize(_ text: String) -> String {
    guard text.contains("1 ") else { return text }
    let forms = [
        "videos": "video", "folders": "folder", "parts": "part", "images": "image",
        "clips": "clip", "projects": "project", "results": "result", "people": "person",
        "files": "file", "items": "item", "lines": "line"
    ]
    var out = text
    for (plural, singular) in forms {
        out = out.replacingOccurrences(of: "1 \(plural)", with: "1 \(singular)")
    }
    return out
}

private func macFill(_ template: String, _ args: [Any]) -> String {
    guard !args.isEmpty, template.contains("{") else { return template }
    var result = ""
    var index = template.startIndex
    while let open = template[index...].firstIndex(of: "{") {
        let afterOpen = template.index(after: open)
        guard afterOpen < template.endIndex, template[afterOpen].isNumber else {
            result += template[index...open]
            result.append("{")
            index = afterOpen
            continue
        }
        var digits = ""
        var cursor = afterOpen
        while cursor < template.endIndex, template[cursor].isNumber {
            digits.append(template[cursor])
            cursor = template.index(after: cursor)
        }
        guard cursor < template.endIndex, template[cursor] == "}", let n = Int(digits),
              n >= 1, n <= args.count else {
            result += template[index...open]
            result.append("{")
            index = afterOpen
            continue
        }
        result += template[index..<open]
        result += macArgText(args[n - 1])
        index = template.index(after: cursor)
    }
    result += template[index...]
    return result
}

private func macArgText(_ value: Any) -> String {
    if let s = value as? String { return s }
    return String(describing: value)
}

let macStringsEN: [String: String] = [
    "语言": "Language",
    "%.1f 倍": "%.1f×",
    "%.1f 秒": "%.1f s",
    "0 秒": "0 s",
    "1 秒取 1 帧最不容易漏掉人脸，耗时也最长；往后每加 1 秒，抽检帧数和耗时约少一成，一闪而过的脸就更容易漏。": "One frame per second is the safest for missing faces, and also the slowest; each extra second drops sampled frames and time by roughly 10%, so quick faces are easier to miss.",
    "1 秒（最细）": "1 s (finest)",
    "10 秒（最省）": "10 s (fastest)",
    "3:4 裁切": "3:4 crop",
    "Cut · 剪辑台": "Cut · Editor",
    "LeogotoPlay 反馈（{1}）": "LeogotoPlay feedback ({1})",
    "Library · 视频库": "Library · Video Library",
    "{1} · macOS 端开发中": "{1} · coming soon on macOS",
    "{1} · {2} 帧": "{1} · {2} frames",
    "{1} 个 · {2}": "{1} items · {2}",
    "{1} 个文件夹": "{1} folders",
    "{1} 个结果": "{1} results",
    "{1} 个视频": "{1} videos",
    "{1} 个视频 · {2}": "{1} videos · {2}",
    "{1} 个视频 · {2} 个文件夹": "{1} videos · {2} folders",
    "{1} 个视频导入失败": "{1} video(s) failed to import",
    "{1} 个视频文件会一并从磁盘删除，不可恢复": "{1} video files will be deleted from disk and can't be recovered.",
    "{1} 个项目": "{1} projects",
    "{1} 份": "{1} parts",
    "{1} 分 {2} 秒": "{1}m {2}s",
    "{1} 分钟": "{1} min",
    "{1} 时 {2} 分 {3} 秒": "{1}h {2}m {3}s",
    "{1} 段": "{1} clips",
    "{1} 秒": "{1} s",
    "{1}-打码": "{1}-masked",
    "{1}-打码.mp4": "{1}-masked.mp4",
    "「原始」档不重编码，帧率与码率直接沿用源片，上面两项不生效": "The Original preset doesn't re-encode: frame rate and bitrate follow the source, so the two options above don't apply.",
    "一秒允许编码器写多少数据，同时决定清晰度和文件大小。\n· 体积 = 码率 × 时长 ÷ 8，码率翻倍，文件就翻倍。\n· 推荐档：按源片码率 × 目标像素比例折算，并且不超过源片码率。\n· 更低（0.6×）更省空间，细节略减；更高（1.6×）细节更足，但超过源片码率也不会真的变清晰；自定义直接填 Mbps。\n· 码率给太少时，运动段和大面积纹理先出块、发糊。": "How much data the encoder may write per second — this sets both sharpness and file size.\n· Size = bitrate × duration ÷ 8. Double the bitrate and the file doubles.\n· Recommended: derived from the source bitrate by target pixel ratio, capped at the source rate.\n· Lower (0.6×) saves space with slightly less detail; higher (1.6×) keeps more detail, though going above the source rate won't add real sharpness. Custom takes Mbps directly.\n· Too little bitrate shows blocking in motion and large flat areas first.",
    "一秒记录多少张画面，管的是动作顺不顺，不管清晰度。\n· 提高帧率不会直接把文件变大：码率固定时帧率翻倍，每帧分到的数据减半，快速运动处更容易糊。\n· 只能往下选：不插帧，选比源片更高的档位没有实际意义。\n· 取舍：社交发布 30 一般够用；运动、游戏、要做慢动作才需要 60。": "How many frames are recorded per second — this controls motion smoothness, not sharpness.\n· A higher frame rate doesn't inflate the file: with a fixed bitrate, doubling the rate halves the data per frame, so fast motion blurs more easily.\n· You can only pick lower values: there is no frame interpolation, so anything above the source is pointless.\n· Trade-off: 30 is fine for social posts; 60 matters for sports, games and slow motion.",
    "一键人脸打码": "Blur Faces",
    "一键分割视频": "Split Video",
    "一键提取人脸": "Extract Faces",
    "一键提取文字": "Extract Text",
    "上一个": "Previous",
    "下一个": "Next",
    "两种来源可以只取一种，也可以都要": "Pick either source, or both",
    "人脸打码中 {1}%": "Blurring faces {1}%",
    "人脸提取-{1}": "Faces-{1}",
    "人脸提取中 {1}%": "Extracting faces {1}%",
    "从本地导入": "Import from Mac",
    "从相册导入": "Import from Photos",
    "会记住上次的选择": "Your last choice is remembered",
    "会连同项目里导入的素材文件、缩略图和整条时间轴现场一起删掉。": "This also deletes the project's imported media, thumbnails and full timeline state.",
    "例如：旅行片段": "e.g. Trip clips",
    "侧脸、被手挡住的脸、画面里很小的路人脸可能抓不到。视频里出现的人越多、换人越频繁，提取出来的张数越多，最多保留 80 张；同一张脸只留质量最好的一帧。原视频不会被修改。提取完可以导出到一个文件夹里。": "Profile faces, faces covered by hands and tiny background faces may be missed. More people and more cuts mean more images — up to 80 are kept, one best frame per face. The original video is never modified, and results can be exported to a folder.",
    "保存": "Save",
    "保存中…": "Saving…",
    "保存失败：{1}": "Save failed: {1}",
    "保存导出视频": "Save exported video",
    "停止分割": "Stop",
    "停止分割？": "Stop splitting?",
    "停止打码": "Stop",
    "停止打码？": "Stop blurring?",
    "停止提取": "Stop",
    "停止提取？": "Stop extracting?",
    "先选一个视频，这里会列出切完的每一段。": "Pick a video first — the finished parts will be listed here.",
    "全程在本机处理，原视频不动，也不会上传": "Everything runs on this Mac; the original stays untouched and is never uploaded.",
    "共 {1} 张": "{1} images",
    "共 {1} 条": "{1} lines",
    "共 {1} 段": "{1} parts",
    "关于 LeogotoPlay": "About LeogotoPlay",
    "关闭": "Close",
    "再打一次": "Blur again",
    "再提一次": "Extract again",
    "写入未完成": "Write didn't finish",
    "写出视频失败：{1}": "Writing the video failed: {1}",
    "准备中…": "Preparing…",
    "几秒": "seconds",
    "分割": "Split",
    "分割失败": "Split failed",
    "分割失败：{1}": "Split failed: {1}",
    "分割完成": "Split finished",
    "分割结果": "Split result",
    "分成 {1} 段？": "Split into {1} parts?",
    "分成几份": "How many parts",
    "分段预览": "Part preview",
    "分辨率": "Resolution",
    "分辨率：{1}，帧率：{2}，码率：{3}，格式：{4}": "Resolution: {1} · Frame rate: {2} · Bitrate: {3} · Format: {4}",
    "切割按关键帧对齐，个别位置会差一两帧（0.1 秒以内）；每段都会保留原片的画面和声音。切完的文件要「存入视频库」或「导出到文件夹」才会留下来。": "Cuts land on keyframes, so a few spots may be off by a frame or two (under 0.1 s). Every part keeps the original picture and audio. Parts stay only if you save them to the Video Library or export to a folder.",
    "切换宫格 / 列表": "Grid / list view",
    "创建": "Create",
    "删除": "Delete",
    "删除 {1}": "Delete {1}",
    "删除…": "Delete…",
    "删除「{1}」？": "Delete “{1}”?",
    "删除文件夹": "Delete folder",
    "删除文件夹「{1}」": "Delete folder “{1}”",
    "删除文件夹和里面的视频": "Delete folder and its videos",
    "删除选中的素材（也可以按 Delete 键）": "Delete selected media (or press Delete)",
    "剪辑": "Edit",
    "剪辑台": "Editor",
    "功能选择": "Sections",
    "半径同样跟脸宽走，观感更像新闻里的处理方式。": "The radius also scales with face width — closer to how news broadcasts handle it.",
    "单击播放": "Click to play",
    "单击播放，右键更多操作": "Click to play · right-click for more",
    "单击看大图": "Click to enlarge",
    "占用空间": "Space used",
    "原始（{1}×{2}）": "Original ({1}×{2})",
    "原样切割：不重新编码，画质和清晰度不变": "Straight cut: no re-encode, identical quality",
    "原片 {1}": "Source {1}",
    "原视频不会被改动，分段先落在临时目录。": "The original stays untouched; parts land in a temporary folder first.",
    "去评分": "Rate now",
    "双击打开文件夹": "Double-click to open folder",
    "取帧间隔": "Frame interval",
    "取消": "Cancel",
    "取消最前": "Unpin",
    "另存为…": "Save as…",
    "只做识别，不改动原视频，也不会上传": "Recognition only — the original isn't modified or uploaded",
    "只删文件夹，视频移到根目录": "Delete the folder only; videos move to the root",
    "只取画面文字": "On-screen text only",
    "只认画面里看得见的字，视频自带的独立字幕轨道读不到；音乐、多人抢话、方言会降低声音转写的准确度，结果建议再核对一遍。声音转写要重新导出音轨，长片会等得久一些。": "Only visible on-screen text is read; separate subtitle tracks can't be reached. Music, overlapping speakers and dialects reduce speech accuracy, so check the results. Speech needs the audio track re-exported, which takes longer on long videos.",
    "只读取，不改动原视频": "Read-only; the original is untouched",
    "只转写声音": "Speech only",
    "名称": "Name",
    "向右旋转": "Rotate right",
    "向右裁剪": "Crop right",
    "向左旋转": "Rotate left",
    "向左裁剪": "Crop left",
    "四种遮挡方式，块大小和模糊半径都跟着脸宽走": "Four styles; block size and blur radius both scale with face width",
    "回到开头": "Go to start",
    "在当前文件夹下新建一个子文件夹": "Create a subfolder inside the current folder",
    "在最前": "Pin to front",
    "在访达中显示": "Show in Finder",
    "块大小跟着脸宽走（约脸宽 1/12），大脸不会糊成一片，小脸也不会等于没打。": "Block size scales with face width (about 1/12 of it): big faces don't turn to mush, and small faces still get blurred.",
    "垂直翻转": "Flip vertical",
    "声音按 30 秒切片转写，分出句子并带上时间码": "Audio is transcribed in 30-second slices, split into sentences with timecodes",
    "声音转写要用系统语音识别，第一次会弹权限请求。": "Speech transcription uses the system recognizer; macOS asks for permission the first time.",
    "声音转文字": "Speech to text",
    "复制全部文字": "Copy all text",
    "复制文件夹路径": "Copy folder path",
    "复制这一条": "Copy this line",
    "好": "OK",
    "存入视频库": "Save to Video Library",
    "完成": "Done",
    "密码（至少 6 位）": "Password (6+ characters)",
    "导入一条本地视频": "Import a local video",
    "导入失败：{1}": "Import failed: {1}",
    "导入视频": "Import video",
    "导入视频…": "Import video…",
    "导出": "Export",
    "导出 txt…": "Export txt…",
    "导出中…": "Exporting…",
    "导出到文件夹…": "Export to folder…",
    "导出到这里": "Export here",
    "导出失败": "Export failed",
    "导出失败，请稍后再试": "Export failed, please try again later",
    "导出完成": "Export finished",
    "导出打码视频": "Export blurred video",
    "导出文字": "Export text",
    "导出没有完成": "Export didn't finish",
    "导出至": "Export to",
    "封装容器，决定哪些平台和软件认它": "Container format — decides which platforms and apps accept it",
    "封装容器，画面编码都是 H.264，两者画质与体积基本一致，差别在\"外壳\"。\n· MP4：通用性最好，微信、抖音、B 站、网页、Windows 播放器都直接认。\n· MOV：苹果生态顺手，Final Cut / QuickTime 更友好，但部分平台或网页不认。\n· 需要上传或发给别人，选 MP4；只在 Mac 上留着继续剪，MOV 更顺。": "Container format: both use H.264, so picture quality and file size are nearly identical — only the \"wrapper\" differs.\n· MP4: the widest compatibility — WeChat, Douyin, Bilibili, web pages and Windows players all open it.\n· MOV: native to Apple, friendlier for Final Cut / QuickTime, but some platforms and web pages reject it.\n· Uploading or sharing? Pick MP4. Keeping it on the Mac for more editing? MOV is smoother.",
    "已保存到 图片/LeogotoPlay/{1}": "Saved to Photos/LeogotoPlay/{1}",
    "已创建文件夹「{1}」": "Created folder “{1}”",
    "已删除文件夹「{1}」及其中的视频": "Deleted folder “{1}” and its videos",
    "已删除文件夹「{1}」，视频已移到根目录": "Deleted folder “{1}”; its videos moved to the root",
    "已取消": "Canceled",
    "已复制 {1} 条文字": "Copied {1} lines",
    "已复制这一条": "Line copied",
    "已存入视频库": "Added to Video Library",
    "已存入视频库 {1} 段": "Added {1} parts to Video Library",
    "已导入「{1}」": "Imported “{1}”",
    "已导出": "Exported",
    "已导出 {1} 个文件": "Exported {1} files",
    "已导出 {1} 张到 {2}": "Exported {1} images to {2}",
    "已导出 {1} 张到「{2}」": "Exported {1} images to “{2}”",
    "已导出到 {1}": "Exported to {1}",
    "已添加 1 个视频，拖到时间轴即可": "1 video added — drag it to the timeline",
    "已移动文件夹「{1}」": "Moved folder “{1}”",
    "已经切好的片段会一并丢掉，原视频不受影响。": "Finished parts are discarded too; the original is unaffected.",
    "已经扫过的部分会丢弃，原视频不受影响。": "Scan progress is discarded; the original is unaffected.",
    "已经识别出来的文字会一并丢弃，视频本身不受影响。": "Recognized text is discarded; the video itself is unaffected.",
    "已重命名": "Renamed",
    "布局": "Layout",
    "帧率": "Frame rate",
    "帧率（fps）": "Frame rate (fps)",
    "开始分割": "Start splitting",
    "开始打码": "Start blurring",
    "开始打码？": "Start blurring?",
    "开始提取": "Start extracting",
    "开始提取人脸？": "Start extracting faces?",
    "开始提取？": "Start extracting?",
    "开始编辑": "Start editing",
    "当前为本地账号实现（密码加盐哈希 + Keychain 保存登录态），接入后端只需替换 AuthServicing 实现。": "Accounts are local-only for now (salted password hash + Keychain session). Connect a backend by swapping the AuthServicing implementation.",
    "当前已是最新版本 {1}": "You're on the latest version {1}",
    "当前机器没有可用的语音识别语种": "No speech recognition language is available on this Mac",
    "循环播放": "Loop playback",
    "总时长": "Total duration",
    "我的": "Me",
    "截取当前帧": "Capture current frame",
    "截图-{1}.png": "Screenshot-{1}.png",
    "截帧失败：{1}": "Frame capture failed: {1}",
    "手动份数": "Custom parts",
    "打开": "Open",
    "打码失败": "Blur failed",
    "打码完成": "Blur finished",
    "打码方式": "Blur style",
    "打码要重新编码整段视频，画质会有轻微损失。侧脸、被手挡住的脸、画面里很小的人脸可能漏检，重要素材建议先看一遍结果。处理期间窗口不要关，关了会中断。": "Blurring re-encodes the whole video, so quality drops slightly. Profile faces, covered faces and very small faces may be missed — review the result for important footage. Keep this window open while it runs; closing interrupts it.",
    "扫完一段视频，按人分好，裁成可以直接用的图片": "Scans a video, groups faces by person and crops images ready to use",
    "把一条长视频切成几段": "Cut one long video into several parts",
    "把左侧素材拖到这条时间轴上，开始你的大作吧～": "Drag media from the left onto this timeline and start creating.",
    "把视频里的文字全拿出来": "Pull all the text out of a video",
    "把视频里的每张脸单独挑出来": "Pick out every face in the video",
    "把说话内容转写出来，带时间码": "Transcribe speech with timecodes",
    "拖到时间轴添加；选中后按 Delete 键删除": "Drag to the timeline to add; select and press Delete to remove",
    "拖动可调整这段在时间轴上的顺序": "Drag to reorder this clip on the timeline",
    "按 3:4 竖图裁切，自带一点额头和头发，可以直接当头像用": "Cropped as a 3:4 portrait with a bit of forehead and hair — ready to use as an avatar",
    "按时长均分，每段都是能单独播放的文件": "Split evenly by duration; each part plays on its own",
    "按本机速度预计需要": "Estimated on this Mac",
    "按设定的取帧间隔扫完整段视频，同一张脸只留最清楚的一张": "Scans the whole video at the chosen interval, keeping one sharp frame per face",
    "推荐": "Recommended",
    "推荐（{1}）": "Recommended ({1})",
    "提取内容": "Extract from",
    "提取失败": "Extraction failed",
    "提取完成": "Extraction finished",
    "提取结果": "Extraction result",
    "提示": "Note",
    "搜索": "Search",
    "搜索视频库视频": "Search video library",
    "搜索视频库里的视频": "Search videos in the library",
    "搜索视频标题": "Search video titles",
    "撤销": "Undo",
    "播放": "Play",
    "播放 / 暂停（空格键）": "Play / pause (Space)",
    "播放列表": "Playlist",
    "播放设置": "Playback settings",
    "支持从本地文件、系统相册导入；导入后即可播放、剪辑、分文件夹管理。": "Import from local files or Photos; then play, edit and organize into folders.",
    "整段视频没有检测到人脸": "No faces detected in the whole video",
    "整段视频没有检测到清晰的人脸": "No clear faces detected in the whole video",
    "文件位置：{1}": "File location: {1}",
    "文件夹": "Folders",
    "文件夹删掉，{1} 个视频保留在未分类里": "Folder removed; {1} videos stay in Unsorted",
    "文件夹本身删除，不可恢复": "The folder itself is deleted and can't be recovered",
    "文字提取.txt": "Text extract.txt",
    "文字提取中 {1}%": "Extracting text {1}%",
    "新建": "New",
    "新建文件夹": "New folder",
    "新建第一个文件夹，把视频分类管理": "Create your first folder to organize videos",
    "旋转": "Rotate",
    "无法写入视频轨道": "Can't write the video track",
    "无法创建封装会话": "Can't create a muxing session",
    "无法封装视频轨": "Can't mux the video track",
    "无法开始": "Can't start",
    "无法开始读取": "Can't start reading",
    "无法读取视频轨道": "Can't read the video track",
    "时长 {1}": "Duration {1}",
    "时长 {1} · {2}": "Duration {1} · {2}",
    "时长 {1} · 每段约 {2}": "Duration {1} · about {2} per part",
    "时长 {1} · 点一下换别的视频": "Duration {1} · click to pick another video",
    "时长：{1} ｜ 大小：{2}（估计）": "Duration: {1}  |  Size: {2} (estimated)",
    "时间轴放大": "Zoom timeline in",
    "时间轴缩小": "Zoom timeline out",
    "时间轴里没有可导出的片段": "No clips on the timeline to export",
    "昵称（可留空）": "Nickname (optional)",
    "暂停": "Pause",
    "更低": "Lower",
    "更高": "Higher",
    "最保险，但不好看，适合正式场合。": "Safest but least pretty — good for formal material.",
    "最多 {1} 份": "Up to {1} parts",
    "最近编辑": "Recent",
    "未分类": "Unsorted",
    "未命名项目": "Untitled project",
    "本地缓存": "Local cache",
    "本地视频管理与剪辑 · macOS": "Local video library & cutter · macOS",
    "查看": "View",
    "标题": "Title",
    "根目录": "Root",
    "格式": "Format",
    "检查更新": "Check for updates",
    "检测到 {1} 个人": "{1} people detected",
    "模糊 + 轻噪点": "Blur + light grain",
    "模糊再叠一层轻噪点，抗「人脸还原」工具的效果稍好一点。": "Blur plus a light grain layer resists face-restoration tools a bit better.",
    "正在切第 {1} / {2} 段": "Splitting part {1} of {2}",
    "正在存入视频库 {1} / {2}": "Saving part {1} of {2} to the library",
    "正在定位人脸": "Locating faces",
    "正在定位并遮挡人脸": "Locating and covering faces",
    "正在导出": "Exporting",
    "正在渲染时间轴…": "Rendering timeline…",
    "正在评估耗时…": "Estimating time…",
    "正在识别画面文字": "Reading on-screen text",
    "正在读取…": "Reading…",
    "正在转写声音": "Transcribing audio",
    "正在逐帧扫描人脸": "Scanning faces frame by frame",
    "正在重新编码画面": "Re-encoding video",
    "段 {1}/{2} · {3}": "Part {1}/{2} · {3}",
    "每 {1} 秒 1 帧": "1 frame every {1}s",
    "每段不到 1 秒时会拦住，建议去剪辑页面手动改": "Parts under 1 s are blocked; fine-tune them manually in the Editor",
    "每段约 {1}": "About {1} per part",
    "每秒画多少张，影响动作流畅度": "Frames per second; affects motion smoothness",
    "每秒给多少数据，影响清晰度和文件大小": "Data per second; affects sharpness and file size",
    "水平翻转": "Flip horizontal",
    "没提取到文字": "No text found",
    "没有可保存的图片": "No images to save",
    "没有可用的邮件客户端，请直接发到 {1}": "No mail app available — please email {1} directly",
    "没有找到匹配的视频": "No matching videos",
    "没有标题包含「{1}」的视频，换个关键词或检查拼写。": "No video title contains “{1}”. Try another keyword or check the spelling.",
    "注册": "Sign up",
    "注册并登录": "Sign up & sign in",
    "添加视频": "Add video",
    "清理缓存": "Clear cache",
    "清空": "Clear",
    "点上面的「开始编辑」，把素材拖进时间轴，剪完就会留在这里。": "Click “Start editing” above and drag media to the timeline — finished edits show up here.",
    "热门工具": "Popular tools",
    "片段 {1} · {2}": "Clip {1} · {2}",
    "版本号": "Version",
    "用户协议": "Terms of Use",
    "画面 + 声音": "Picture & sound",
    "画面 {1}": "Video {1}",
    "画面字幕 + 说话内容，一次转成可以复制的文本": "On-screen text plus speech, turned into copyable text in one go",
    "画面字幕文字": "On-screen text",
    "画面尺寸，决定清晰度的上限和文件大小": "Output size — sets the sharpness ceiling and file size",
    "画面文字": "On-screen text",
    "登录": "Sign in",
    "登录后同步你的账号状态": "Sign in to sync your account state",
    "登录时间 {1}": "Signed in {1}",
    "知道了": "Got it",
    "码率": "Bitrate",
    "码率值": "Bitrate value",
    "确定": "OK",
    "移动": "Move",
    "移动到文件夹": "Move to folder",
    "移动文件夹": "Move folder",
    "空白项目": "Blank project",
    "第 {1} 段": "Part {1}",
    "第 {1} 段存入失败：{2}": "Part {1} failed to save: {2}",
    "第 {1} 段导出失败：{2}": "Part {1} failed to export: {2}",
    "第 {1} 段预览": "Part {1} preview",
    "系统里没有允许语音识别（可在 系统设置 › 隐私与安全性 › 语音识别 里打开）": "Speech recognition isn't allowed (enable it in System Settings › Privacy & Security › Speech Recognition)",
    "素材": "Media",
    "约 {1} 分 {2} 秒": "about {1} min {2} s",
    "约 {1} 分钟": "about {1} min",
    "约 {1} 秒": "about {1} s",
    "纯色 / 黑块": "Solid / black block",
    "给 App 评分": "Rate this app",
    "继续": "Continue",
    "继续上次的时间轴现场": "Resume last timeline",
    "联系我们": "Contact us",
    "自动把画面里的人脸遮住": "Blur every face on screen automatically",
    "自定义": "Custom",
    "自定义…": "Custom…",
    "自定义（{1}）": "Custom ({1})",
    "至少保留一个功能；关掉的那个不会出现在左侧栏。": "Keep at least one section; the one you turn off disappears from the sidebar.",
    "至少保留一项": "Keep at least one",
    "要重新编码整段视频，越长的片子越久。": "The whole video is re-encoded; longer videos take longer.",
    "视频": "Videos",
    "视频 {1} · {2} · {3} 帧": "Video {1} · {2} · {3} frames",
    "视频分割中 {1}%": "Splitting video {1}%",
    "视频原始参数：": "Source video specs:",
    "视频太短，不能这么分": "The video is too short to split this way",
    "视频太短，分出来每段不到 1 秒了": "The video is too short — parts would be under 1 s",
    "视频库": "Video Library",
    "视频文件会从视频库中移除，且不可恢复。": "The video file is removed from the library and can't be recovered.",
    "视频格式": "Video format",
    "视频码率": "Video bitrate",
    "视频长度太短：{1} 分成 {2} 份，每段不到 1 秒。建议去剪辑页面手动编辑。": "Video too short: {1} split into {2} parts would be under 1 s each. Fine-tune it manually in the Editor.",
    "设置": "Settings",
    "识别画面里出现的字幕与贴片文字": "Read subtitles and burned-in text on screen",
    "语音 {1}": "Speech {1}",
    "语音识别不可用：{1}": "Speech recognition unavailable: {1}",
    "语音转写": "Speech transcription",
    "说明": "About",
    "读取中断": "Reading interrupted",
    "读取视频中…": "Reading video…",
    "读取视频失败：{1}": "Failed to read the video: {1}",
    "谢谢支持！如果没弹出评分框，说明当前是开发版，上架 App Store 后才会出现。": "Thanks for the support! If no rating prompt appeared, this is a development build — it shows up once the app is on the App Store.",
    "跟随源（{1}）": "Match source ({1})",
    "路径已复制": "Path copied",
    "输入片名关键词即可，文件夹里的视频也能搜到。": "Type a title keyword — videos inside folders are searched too.",
    "输出画面的像素尺寸（宽×高），是清晰度的天花板。\n· 只能缩不能提：放大会靠插值补像素，画面只会更软，不会更清晰；选比源大的档位没有意义。\n· 体积大致随像素数线性涨：1080p 的面积是 720p 的 2.25 倍。\n· 取舍：要存档或留剪辑余量选「原始」或 1080p；只发社交平台，720p 也够。": "Pixel dimensions of the output (width×height) — the ceiling on sharpness.\n· Down only: upscaling interpolates pixels, so the picture gets softer, never sharper; picking anything above the source is pointless.\n· Size scales roughly with pixel count: 1080p covers 2.25× the area of 720p.\n· Trade-off: choose Original or 1080p for archiving and more editing; 720p is enough for social platforms.",
    "返回视频库": "Back to library",
    "还没有编辑过的项目": "No edited projects yet",
    "还没有视频": "No videos yet",
    "还没有载入视频": "No video loaded yet",
    "这一段处理进度会丢弃，原视频不受影响。": "Progress for this part is discarded; the original is unaffected.",
    "这个文件夹还是空的": "This folder is still empty",
    "这个文件夹里有 {1} 个视频，选择怎么处理：": "This folder holds {1} videos. Choose what to do:",
    "这个文件夹里没有视频，删除后不可恢复。": "No videos in this folder; deleting can't be undone.",
    "这个文件里没有视频画面": "This file has no video track",
    "这个视频没有可分割的画面轨道": "This video has no splittable video track",
    "这个视频没有可识别的画面轨道": "This video has no readable video track",
    "这个视频没有音轨，无法做声音转文字": "This video has no audio track, so speech can't be transcribed",
    "这个视频里没有识别到可见的字幕，声音也没转出内容。": "No visible subtitles were found, and speech produced nothing either.",
    "这个设置会记在这台 Mac 上，下次进来还是这次的选择。": "This setting is stored on this Mac and remembered next time.",
    "这台机器不支持这种编码": "This Mac doesn't support that codec",
    "退出登录": "Sign out",
    "选一个文件夹，人脸图会放进里面的子文件夹": "Pick a folder; face images go into a subfolder inside it",
    "选择": "Choose",
    "选择一个视频文件": "Choose a video file",
    "选择保存文件夹": "Choose a save folder",
    "选择导出目录": "Choose an export folder",
    "选择导出视频保存的位置": "Choose where to save the exported video",
    "选择要导入的视频": "Choose videos to import",
    "选本地视频，处理好后把每张脸列出来": "Pick a local video; every face is listed afterwards",
    "选本地视频，处理好后生成一个打了码的新片": "Pick a local video; a blurred copy is produced",
    "逐 0.5 秒抽帧，识别画面里出现的字幕与贴片文字": "Samples every 0.5 s to read subtitles and burned-in text",
    "逐帧找人脸，整段重新编码，出一个打码新片": "Finds faces frame by frame, re-encodes the whole video and outputs a blurred copy",
    "逐帧检测人脸位置，整段视频里的人都会被遮住": "Detects face positions frame by frame; everyone in the video gets covered",
    "速度": "Speed",
    "邮件反馈": "Email feedback",
    "邮箱": "Email",
    "重命名": "Rename",
    "重命名 / 删除": "Rename / delete",
    "重命名文件夹": "Rename folder",
    "重命名视频": "Rename video",
    "重命名项目": "Rename project",
    "重新分割": "Split again",
    "重置": "Reset",
    "隐私政策": "Privacy Policy",
    "音轨导出失败": "Audio track export failed",
    "音频封装失败": "Audio muxing failed",
    "项目名称": "Project name",
    "项目已删除": "Project deleted",
    "预览这一段": "Preview this part",
    "预计需要": "Estimated",
    "马赛克": "Mosaic",
    "高斯模糊": "Gaussian blur",
    "默认切 2–6 份，也可以手动分到 20 份": "Splits into 2–6 by default; you can go up to 20",
    "默认导出到「下载」文件夹：{1}": "Exports to the Downloads folder by default: {1}",
]
