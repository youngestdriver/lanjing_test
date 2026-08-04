import Foundation

struct ExamParseResult: Equatable {
    let examResultsId: String?
    let examInfoId: String
    let uuid: String?
    let testIds: [String]
    let questionStates: [QuestionState]
    let sectionMap: [String: SectionStats]
    let sectionOrder: [String]
}

/// Port of server.js parseExamHtml. Works on NSString so all match ranges are
/// UTF-16 — identical indexing semantics to the JS string operations.
enum ExamHTMLParser {

    static func parse(_ html: String, fallbackExamInfoId: String, knownResultsId: String? = nil) -> ExamParseResult {
        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        func extractVar(_ name: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "var\\s+\(name)\\s*=\\s*['\"]([^'\"]+)['\"]"),
                  let match = regex.firstMatch(in: html, range: fullRange)
            else { return nil }
            return ns.substring(with: match.range(at: 1))
        }

        let examResultsId = knownResultsId ?? extractVar("exam_results_id")
        let examInfoId = extractVar("exam_info_id") ?? fallbackExamInfoId

        // Section titles with their positions (server: sectionMatches)
        let sectionBounds: [(title: String, pos: Int)] = {
            guard let regex = try? NSRegularExpression(pattern: "<div class=\"card-content-title\">([^<]+)</div>") else { return [] }
            return regex.matches(in: html, range: fullRange).map { match in
                (title: ns.substring(with: match.range(at: 1)), pos: match.range.location)
            }
        }()

        // Card chunks = text between consecutive anchors (server: html.split(/<a\s+href="#[^"]*">\s*/), skipping chunk 0)
        guard let anchorRegex = try? NSRegularExpression(pattern: "<a\\s+href=\"#[^\"]*\">\\s*") else {
            return ExamParseResult(examResultsId: examResultsId, examInfoId: examInfoId, uuid: nil,
                                   testIds: [], questionStates: [], sectionMap: [:], sectionOrder: [])
        }
        let anchors = anchorRegex.matches(in: html, range: fullRange)

        var states: [QuestionState] = []
        var seen = Set<String>()

        for (i, anchor) in anchors.enumerated() {
            let chunkStart = anchor.range.location + anchor.range.length
            let chunkEnd = (i + 1 < anchors.count) ? anchors[i + 1].range.location : ns.length
            guard chunkStart < chunkEnd else { continue }
            let chunk = ns.substring(with: NSRange(location: chunkStart, length: chunkEnd - chunkStart)) as NSString
            let chunkRange = NSRange(location: 0, length: chunk.length)

            guard let qIdMatch = firstMatch("questionsId=\"([^\"]+)\"", in: chunk, range: chunkRange) else { continue }
            let qId = chunk.substring(with: qIdMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if qId.isEmpty || seen.contains(qId) { continue }
            seen.insert(qId)

            let uId = firstMatch("uuId=\"([^\"]+)\"", in: chunk, range: chunkRange)
                .map { chunk.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }

            let num: Int = {
                guard let match = firstMatch(">\\s*(\\d+)\\s*</span>", in: chunk, range: chunkRange) else { return 0 }
                return Int(chunk.substring(with: match.range(at: 1))) ?? 0
            }()

            let (state, marked): (QuestionState.State, Bool) = {
                guard let match = firstMatch("<div\\b[^>]*class=[\"']([^\"']*\\bquestion_cbox\\b[^\"']*)[\"'][^>]*>", in: chunk, range: chunkRange)
                else { return (.unanswered, false) }
                let classes = Set(chunk.substring(with: match.range(at: 1)).split(separator: " ").map(String.init))
                let state: QuestionState.State = classes.contains("right") ? .right : classes.contains("error") ? .error : .unanswered
                return (state, classes.contains("marked"))
            }()

            // Section attribution: server uses html.indexOf on the full string
            let cardPos = (html as NSString).range(of: "questionsId=\"\(qId)\"").location
            var section = ""
            for bound in sectionBounds.reversed() where cardPos > bound.pos {
                section = bound.title
                break
            }

            states.append(QuestionState(questionsId: qId, uuId: uId, num: num, section: section, state: state, marked: marked))
        }

        let testIds = states.map(\.questionsId)
        let uuid = states.first?.uuId ?? extractVar("uuId")

        // Per-section breakdown (server: sectionMap), "(无分类)" for empty section
        var sectionMap: [String: SectionStats] = [:]
        var sectionOrder: [String] = []
        for q in states {
            let key = q.section.isEmpty ? "(无分类)" : q.section
            if sectionMap[key] == nil { sectionOrder.append(key) }
            var stats = sectionMap[key] ?? SectionStats()
            stats.total += 1
            switch q.state {
            case .right: stats.right += 1
            case .error: stats.error += 1
            case .unanswered: stats.unanswered += 1
            }
            sectionMap[key] = stats
        }

        return ExamParseResult(
            examResultsId: examResultsId,
            examInfoId: examInfoId,
            uuid: uuid,
            testIds: testIds,
            questionStates: states,
            sectionMap: sectionMap,
            sectionOrder: sectionOrder
        )
    }

    private static func firstMatch(_ pattern: String, in string: NSString, range: NSRange) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: string as String, range: range)
    }
}
