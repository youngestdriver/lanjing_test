import SwiftUI

/// 大类 list with per-category question counts from the local bank meta.
/// 更新题库 / 删除题库 live in 我的 (PracticeBankSettingsSection) — this
/// screen only shows crawl info in the footer.
struct PracticeCategoryListView: View {
    let vm: PracticeBankViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(BankLogic.categories, id: \.self) { category in
                    let count = vm.meta?.counts?[category] ?? 0
                    NavigationLink(value: PracticeRoute.subcategories(category: category)) {
                        HStack {
                            Text(category)
                            Spacer()
                            Text("\(count) 题")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(count == 0)
                }
            } header: {
                Text("题库分类")
            } footer: {
                Text("题目从蓝鲸平台实时爬取并保存在本机，可离线练习；首次进入本页会自动爬取，图片不缓存，展示时从网络加载。")
                if let meta = vm.meta {
                    Text("题库版本 round \(meta.round ?? 0) · 共 \(meta.totalCount) 题")
                }
            }
        }
        .navigationTitle("练习")
        // 我的 > 删除题库 triggered a re-crawl — pop back to the root so the
        // download progress gate is visible instead of a stale category list.
        .onChange(of: vm.phase) { _, newPhase in
            if case .downloading = newPhase {
                dismiss()
            }
        }
    }
}
