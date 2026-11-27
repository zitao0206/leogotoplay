import SwiftUI
import LeogotoPlayCore

/// V4.0：功能选择（List / Cut 显隐，二选一或都开）。
/// 从 Mine 页单独的「功能选择」入口进来，页内只放 List / Cut 两个开关。
struct TabLayoutView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(TabPrefs.showListKey) private var showList = true
    @AppStorage(TabPrefs.showCutKey) private var showCut = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Library", isOn: $showList)
                        .disabled(!showCut)
                        .padding(.vertical, 5.5)
                    Toggle("Cut", isOn: $showCut)
                        .disabled(!showList)
                        .padding(.vertical, 5.5)
                }
            }
            .navigationTitle("功能选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
