import SwiftUI

/// 大类 list with per-category counts from the bank meta, plus a footer with
/// version info and a manual 更新题库 action.
struct PracticeCategoryListView: View {
    let vm: PracticeBankViewModel

    var body: some View {
        List {
            Section("题库分类") {
                ForEach(BankLogic.categories, id: \.self) { category in
                    let count = vm.meta?.counts?[category] ?? 0
                    Button {
                        Task { await vm.openCategory(category) }
                    } label: {
                        HStack {
                            Text(category)
                            Spacer()
                            Text("\(count) 题")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(count == 0)
                }
            }
            if let meta = vm.meta {
                Section {
                    Button("更新题库") {
                        Task { await vm.updateBank() }
                    }
                } footer: {
                    Text("题库版本 round \(meta.round ?? 0) · 共 \(meta.totalCount) 题。首次进入本页会自动下载；图片不缓存，展示时从网络加载。")
                }
            }
        }
        .navigationTitle("练习")
    }
}
