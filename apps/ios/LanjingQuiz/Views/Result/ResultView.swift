import SwiftUI

struct ResultView: View {
    let result: ExamResult
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("🦉")
                .font(.system(size: 80))
            Text("单元挑战完成！")
                .displayFont(24)
            Text("\(result.score) 分")
                .displayFont(64)
                .foregroundStyle(DS.orange)
            Text("击败全国 \(result.beatRate)% 的考生")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DS.accent)
            Text("当前排名 #\(result.rank)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DS.blue)
            Spacer()
            Button("返回路线图") {
                appState.route = .examList
            }
            .buttonStyle(KeycapButtonStyle(color: DS.accent))
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
}
