import Foundation

/// Upstream JSON sometimes sends stringly numbers; this decodes either form.
struct StringValue: Decodable, Equatable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else {
            value = ""
        }
    }
}

struct LoginResponse: Decodable {
    let success: Bool
    let desc: String?
}

struct ExamListResponse: Decodable {
    let success: Bool
    let desc: String?
    let bizContent: BizContent?

    struct StyleDTO: Decodable {
        let id: StringValue
        let name: String
    }

    struct BizContent: Decodable {
        struct ExamDTO: Decodable {
            let id: Int
            let examName: String
            let examStyle: StringValue?
            let examStyleName: String?
            let practiceMode: Int?
            let examMode: String?
            let examTime: Int?
            let paperInfoId: Int?
            let examTimesNum: Int?
            let examTimesRestrict: String?
            let paid: Bool?
            let examTimeRestrict: String?
            let wfs: Int?
            let timeLeft: Int?
        }

        let total: Int?
        let styles: [StyleDTO]
        let examInfoModelList: [ExamDTO]
    }
}

struct QuestionDTO: Decodable {
    let _id: String
    let question: String
    let answer1: String?
    let answer2: String?
    let answer3: String?
    let answer4: String?
    let key1: String?
    let key2: String?
    let key3: String?
    let key4: String?
    let test_ans_right: String?
    let analysis: String?
}

/// Response of /exam/start_exam_queue and /exam/check_queue_status.
struct QueueResponse: Decodable {
    struct BizContent: Decodable {
        let isOk: Bool?
    }

    let bizContent: BizContent?
    let code: StringValue?
}
