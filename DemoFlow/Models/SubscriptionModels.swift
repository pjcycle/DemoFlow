//
//  SubscriptionModels.swift
//  DemoFlow
//
//  2026-07-11 新增：订阅与买断商业化模型。
//

import Foundation

enum SubscriptionMembershipLevel: String, CaseIterable, Identifiable, Codable {
    case free
    case vip
    case svip

    var id: String { rawValue }

    init(activePlan: SubscriptionPlan?) {
        switch activePlan {
        case .monthly, .yearly:
            self = .vip
        case .lifetime:
            self = .svip
        case .none:
            self = .free
        }
    }

    var badgeTextKey: String? {
        switch self {
        case .free:
            return nil
        case .vip:
            return "subscription.membership.vip"
        case .svip:
            return "subscription.membership.svip"
        }
    }

    var isPaid: Bool {
        self != .free
    }
}

enum SubscriptionPlan: String, CaseIterable, Identifiable, Codable {
    case monthly
    case yearly
    case lifetime

    var id: String { rawValue }

    init?(productID: String) {
        switch productID {
        case Self.monthly.productID:
            self = .monthly
        case Self.yearly.productID:
            self = .yearly
        case Self.lifetime.productID:
            self = .lifetime
        default:
            return nil
        }
    }

    var productID: String {
        switch self {
        case .monthly:
            return "pjln.top.demoflow.pro.monthly"
        case .yearly:
            return "pjln.top.demoflow.pro.yearly"
        case .lifetime:
            return "pjln.top.demoflow.pro.lifetime"
        }
    }

    var titleKey: String {
        switch self {
        case .monthly:
            return "subscription.plan.monthly.title"
        case .yearly:
            return "subscription.plan.yearly.title"
        case .lifetime:
            return "subscription.plan.lifetime.title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .monthly:
            return "subscription.plan.monthly.subtitle"
        case .yearly:
            return "subscription.plan.yearly.subtitle"
        case .lifetime:
            return "subscription.plan.lifetime.subtitle"
        }
    }

    var highlightKey: String {
        switch self {
        case .monthly:
            return "subscription.plan.monthly.highlight"
        case .yearly:
            return "subscription.plan.yearly.highlight"
        case .lifetime:
            return "subscription.plan.lifetime.highlight"
        }
    }

    var badgeTextKey: String? {
        switch self {
        case .monthly:
            return "subscription.plan.monthly.badge"
        case .yearly:
            return "subscription.plan.yearly.badge"
        case .lifetime:
            return "subscription.plan.lifetime.badge"
        }
    }

    var priceText: String {
        switch self {
        case .monthly:
            return "$1.99"
        case .yearly:
            return "$19.99"
        case .lifetime:
            return "$49.99"
        }
    }

    var compareAtPriceText: String {
        switch self {
        case .monthly:
            return "$4.99"
        case .yearly:
            return "$39.99"
        case .lifetime:
            return "$99.99"
        }
    }

    var isRecommended: Bool {
        self == .yearly
    }

    var sortPriority: Int {
        switch self {
        case .lifetime:
            return 3
        case .yearly:
            return 2
        case .monthly:
            return 1
        }
    }
}

enum SubscriptionPresentationSource: String, CaseIterable, Codable {
    case settings
    case lockedFeature
    case renewalPrompt
    case upgradePrompt
}

enum SubscriptionEntitlementStatus: String, CaseIterable, Codable {
    case free
    case monthly
    case yearly
    case lifetime

    init(plan: SubscriptionPlan?) {
        switch plan {
        case .monthly:
            self = .monthly
        case .yearly:
            self = .yearly
        case .lifetime:
            self = .lifetime
        case .none:
            self = .free
        }
    }

    var isPro: Bool {
        self != .free
    }

    var titleKey: String {
        switch self {
        case .free:
            return "subscription.status.free"
        case .monthly:
            return "subscription.status.monthly"
        case .yearly:
            return "subscription.status.yearly"
        case .lifetime:
            return "subscription.status.lifetime"
        }
    }
}

enum SubscriptionPurchaseOutcome: Equatable {
    case success
    case pending
    case cancelled
    case failed(String)
}

enum SubscriptionLockedFeature: String, CaseIterable, Identifiable, Codable {
    case recordingQuality
    case pipQuality
    case videoExport
    case audioExtract
    case audioTranscode
    case audioTrimExport
    case subDubVideoExport
    case subDubAI
    case subDubSubtitle

    var id: String { rawValue }

    var statusMessageKey: String {
        switch self {
        case .recordingQuality:
            return "subscription.lock.recording_quality"
        case .pipQuality:
            return "subscription.lock.pip_quality"
        case .videoExport:
            return "subscription.lock.video_export"
        case .audioExtract:
            return "subscription.lock.audio_extract"
        case .audioTranscode:
            return "subscription.lock.audio_transcode"
        case .audioTrimExport:
            return "subscription.lock.audio_trim_export"
        case .subDubVideoExport:
            return "subscription.lock.subdub_video_export"
        case .subDubAI:
            return "subscription.lock.subdub_ai"
        case .subDubSubtitle:
            return "subscription.lock.subdub_subtitle"
        }
    }
}
