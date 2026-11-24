import SwiftUI
import LeogotoPlayCore

/// 设置页：导出清晰度、循环播放、缓存清理。
struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ExportSettings.qualityKey) private var qualityRaw = VideoExporter.Quality.p1080.rawValue
    @AppStorage(ExportSettings.autoLoopKey) private var autoLoop = true

    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("导出清晰度", selection: $qualityRaw) {
                        ForEach(VideoExporter.Quality.allCases) { quality in
                            Text(quality.title).tag(quality.rawValue)
                        }
                    }
                } header: {
                    Text("导出")
                } footer: {
                    Text("清晰度越高文件越大。")
                }

                Section {
                    Toggle("默认循环播放", isOn: $autoLoop)
                } header: {
                    Text("播放")
                }

                Section {
                    HStack {
                        Text("素材占用")
                        Spacer()
                        Text(library.totalSize.fileSizeText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button {
                        library.clearThumbnailCache()
                        ImageCache.clear()
                        toastMessage = "缩略图缓存已清理"
                    } label: {
                        Text("清理缩略图缓存")
                    }
                } header: {
                    Text("存储")
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("环境")
                        Spacer()
                        Text("本地基础架构")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .toast($toastMessage)
        }
    }
}
