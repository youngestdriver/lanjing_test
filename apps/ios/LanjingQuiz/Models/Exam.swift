import Foundation

struct Exam: Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let style: String
    let practiceMode: Int
    let examMode: String
    let totalTime: Int
    let paperInfoId: Int
    let examTimes: Int
    let examTimesRestrict: String
    let paid: Bool
    let timeRestrict: String
    let wfs: Int
    let timeLeft: Int

    init(dto: ExamListResponse.BizContent.ExamDTO, styleName: String) {
        self.id = dto.id
        self.name = dto.examName
        self.style = styleName
        self.practiceMode = dto.practiceMode ?? 0
        self.examMode = dto.examMode ?? ""
        self.totalTime = dto.examTime ?? 0
        self.paperInfoId = dto.paperInfoId ?? 0
        self.examTimes = dto.examTimesNum ?? 0
        self.examTimesRestrict = dto.examTimesRestrict ?? "0"
        self.paid = dto.paid ?? false
        self.timeRestrict = dto.examTimeRestrict ?? "0"
        self.wfs = dto.wfs ?? 0
        self.timeLeft = dto.timeLeft ?? 0
    }

    var isNew: Bool { wfs == 1 }
    var timeLabel: String { totalTime == 0 ? "不限时" : "\(totalTime)分钟" }
    var modeLabel: String {
        switch practiceMode {
        case 0: "模拟考试"
        case 1: "MOCK"
        case 2: "练习"
        default: "?"
        }
    }
}

struct ExamListData {
    let total: Int
    let styles: [String: String]
    let exams: [Exam]
}
