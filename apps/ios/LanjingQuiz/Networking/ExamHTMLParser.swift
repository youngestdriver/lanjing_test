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

/// Port of apps/web/server.js parseExamHtml. Works on NSString so all match ranges are
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

        // Section titles with their positions (server: sectionMatches). The
        // class attr tolerates a trailing space / extra classes (资料分析 comb
        // sections are emitted as `<div class="card-content-title ">`).
        let sectionBounds: [(title: String, pos: Int)] = {
            guard let regex = try? NSRegularExpression(pattern: "<div class=\"([^\"]*card-content-title[^\"]*)\">([^<]+)</div>") else { return [] }
            return regex.matches(in: html, range: fullRange).map { match in
                (title: ns.substring(with: match.range(at: 2)), pos: match.range.location)
            }
        }()

        // Comb (资料分析) groups: an insert-list div wraps several sub-questions
        // and carries the combId in its own questionsId attribute — the payload
        // /exam/get_question_info/ needs per question to fetch the shared
        // parent_info. Depth-tracking finds where each insert-list div closes,
        // so only cards actually inside a comb inherit its combId (regular
        // cards that follow a comb section must not) — server: combBounds.
        let combBounds: [(combId: String, pos: Int, end: Int)] = {
            guard let openRegex = try? NSRegularExpression(pattern: "<div class=\"([^\"]*insert-list[^\"]*)\"[^>]*questionsId=\"([^\"]+)\""),
                  let tagRegex = try? NSRegularExpression(pattern: "<div\\b[^>]*>|</div>")
            else { return [] }
            let opens = openRegex.matches(in: html, range: fullRange).map { match in
                (combId: ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines),
                 pos: match.range.location,
                 end: match.range.location)
            }
            guard !opens.isEmpty else { return [] }
            var combs = opens
            let indexByPos = Dictionary(uniqueKeysWithValues: combs.enumerated().map { ($0.element.pos, $0.offset) })
            var depth = 0
            var pendingIndex: Int?
            var pendingDepth = 0
            for tag in tagRegex.matches(in: html, range: fullRange) {
                let text = ns.substring(with: tag.range)
                if text.hasPrefix("</") {
                    depth -= 1
                    if let pending = pendingIndex, depth == pendingDepth {
                        combs[pending].end = tag.range.location + tag.range.length
                        pendingIndex = nil
                    }
                } else {
                    if let index = indexByPos[tag.range.location] {
                        pendingIndex = index
                        pendingDepth = depth
                    }
                    depth += 1
                }
            }
            return combs
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

            // Raw number text: comb sub-questions use "1.1"…"15.5" style labels,
            // ordinary questions a plain integer — keep the string as-is.
            let num: String = {
                guard let match = firstMatch(">\\s*(\\d+(?:\\.\\d+)?)\\s*</span>", in: chunk, range: chunkRange) else { return "" }
                return chunk.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
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

            // The card belongs to the comb whose insert-list div actually
            // wraps it (regular cards after a comb section are outside every
            // comb range).
            var combId: String?
            for bound in combBounds where cardPos > bound.pos && cardPos < bound.end {
                combId = bound.combId
                break
            }

            states.append(QuestionState(
                questionsId: qId, uuId: uId, num: num, combId: combId, section: section,
                state: state, marked: marked
            ))
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
