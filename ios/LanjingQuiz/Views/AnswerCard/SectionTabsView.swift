import SwiftUI

/// Section tabs for the answer card; hidden when there is only one section.
/// Tab label = title truncated before the first "(" (SPA renderSectionTabs).
struct SectionTabsView: View {
    let vm: QuizViewModel

    var body: some View {
        let titles = vm.sectionTitles
        if titles.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tab("全部", nil)
                    ForEach(titles, id: \.self) { title in
                        tab(Self.shortLabel(title), title)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
    }

    private func tab(_ label: String, _ section: String?) -> some View {
        Button {
            vm.selectSectionTab(section)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(vm.selectedSection == section ? DS.accent : Color(.systemGray5))
                .foregroundStyle(vm.selectedSection == section ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Port of the SPA's tab label: title truncated before the first "(".
    /// omittingEmptySubsequences: false keeps JS split semantics (leading "(" → "").
    static func shortLabel(_ title: String) -> String {
        title.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? title
    }
}
