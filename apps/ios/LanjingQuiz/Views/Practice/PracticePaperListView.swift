import SwiftUI

/// 试卷 list for one category. Each row shows the paper's upstream attempt
/// state: 新开 (wfs=1, entering creates a fresh attempt) or 进行中 (wfs=0,
/// an existing attempt entered read-only).
struct PracticePaperListView: View {
    let vm: PracticeBankViewModel
    let category: String

    var body: some View {
        List {
            Section {
                ForEach(vm.papers(for: category)) { paper in
                    NavigationLink(value: PracticeRoute.subcategories(paper: paper)) {
                        HStack {
                            Text(paper.name)
                                .lineLimit(1)
                            Spacer()
                            Text(paper.isNew ? "新开" : "进行中")
                                .font(.footnote)
                                .foregroundStyle(paper.isNew ? DS.accent : .secondary)
                        }
                    }
                }
            } header: {
                Text("试卷")
            } footer: {
                Text("“新开”将创建一次新的上游作答记录；“进行中”只读进入已有作答。进入试卷后题目从蓝鲸平台实时获取。")
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
    }
}
