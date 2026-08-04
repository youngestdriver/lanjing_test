import Foundation

enum Formatters {
    /// Port of formatQuestionTimer: "01:00"
    static func mmss(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
