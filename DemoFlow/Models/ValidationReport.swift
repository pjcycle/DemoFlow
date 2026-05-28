//
//  ValidationReport.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import Foundation

enum ValidationStatus: String, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case blocked = "BLOCKED"
}

struct ValidationItem: Codable, Identifiable {
    let id = UUID()
    let name: String
    let status: ValidationStatus
    let detail: String

    enum CodingKeys: String, CodingKey {
        case name
        case status
        case detail
    }
}

struct ValidationReport: Codable {
    let createdAt: Date
    let items: [ValidationItem]

    var summary: String {
        let passCount = items.filter { $0.status == .pass }.count
        let failCount = items.filter { $0.status == .fail }.count
        let blockedCount = items.filter { $0.status == .blocked }.count
        return "PASS:\(passCount) FAIL:\(failCount) BLOCKED:\(blockedCount)"
    }
}
