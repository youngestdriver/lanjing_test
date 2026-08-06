import SwiftUI

/// 子类 (subCategory 题型细分) list for one category, with a shuffle toggle.
struct PracticeSubcategoryListView: View {
    @Bindable var vm: PracticeBankViewModel
    let category: String

    var body: some View {
        List {
            Section {
                Toggle("随机顺序", isOn: $vm.isShuffleEnabled)
            } footer: {
                Text("开启后每次练习按随机顺序出题")
            }
            Section("题型") {
                ForEach(vm.subcategories, id: \.name) { group in
                    Button {
                        vm.startSession(category: category, subCategory: group.name)
                    } label: {
                        HStack {
                            Text(group.name)
                            Spacer()
                            Text("\(group.count) 题")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(group.count == 0)
                }
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
    }
}
