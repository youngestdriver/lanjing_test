import Foundation

/// Port of the score / beatRate / rank regexes in server.js /api/exams/:id/submit.
enum ResultPageParser {

    static func parse(_ html: String) -> ExamResult {
        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        let score: String
        if let regex = try? NSRegularExpression(pattern: "class=\"score\"[^>]*>\\s*([\\d.]+)\\s*<"),
           let match = regex.firstMatch(in: html, range: fullRange) {
            score = ns.substring(with: match.range(at: 1))
        } else {
            score = "0"
        }

        var nums: [String] = []
        if let regex = try? NSRegularExpression(pattern: "exam-result-percentage[^>]*>\\s*(\\d+)") {
            nums = regex.matches(in: html, range: fullRange).map { ns.substring(with: $0.range(at: 1)) }
        }
        let beatRate = nums.first ?? "?"
        let rank = nums.count > 1 ? nums[1] : nums.first ?? "?"

        return ExamResult(score: score, beatRate: beatRate, rank: rank)
    }
}
