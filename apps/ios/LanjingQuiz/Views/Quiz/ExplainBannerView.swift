import SwiftUI

/// Shared answer-reveal banner: verdict, correct answer letters, analysis.
/// `correct == nil` marks a question with no known answer ("本题暂无标准答案").
struct ExplainBannerView: View {
    let correct: Bool?
    let answerLabel: String
    let analysis: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(correct == true ? "棒极了！回答正确！" : "加油！再接再厉！")
                .font(.system(size: 15, weight: .heavy))
            if correct == false {
                Text("正确答案：\(answerLabel)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.accent)
            } else if correct == nil {
                Text("本题暂无标准答案")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.orange)
            }
            if let analysis, !analysis.isEmpty {
                RichHTMLContent(html: analysis, fontSize: 14)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((correct == true ? DS.accent : DS.red).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusMD))
    }
}
