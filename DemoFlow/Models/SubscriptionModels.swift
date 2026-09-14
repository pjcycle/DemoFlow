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

    /// 订阅时长文案（用于在订阅页明确告知时长 / 是否自动续订，满足 App Store Review
    /// Guideline 3.1.2(c) 对"Length of subscription"的强制展示要求）。
    var lengthKey: String {
        switch self {
        case .monthly:
            return "subscription.plan.monthly.length"
        case .yearly:
            return "subscription.plan.yearly.length"
        case .lifetime:
            return "subscription.plan.lifetime.length"
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

    /// 用于真实 SKU 对比的参考方案。无更便宜 SKU 可对比时返回 nil。
    var comparisonReferencePlan: SubscriptionPlan? {
        switch self {
        case .monthly:
            return nil
        case .yearly:
            return .monthly
        case .lifetime:
            return .yearly
        }
    }

    /// 对比金额的倍数。
    /// yearly 的对比基准 = 12 个月月付总额（年付 vs 付 12 个月月付）；
    /// lifetime 的对比基准 = 3 年年付总额（买断 vs 付 3 年年付）。
    var comparisonMultiplier: Int {
        switch self {
        case .monthly:
            return 1
        case .yearly:
            return 12
        case .lifetime:
            return 3
        }
    }

    /// 划线价前缀的 L10n key（如终身卡的"3 年"）。
    /// 返回 nil 表示不添加前缀。
    var comparisonPrefixKey: String? {
        switch self {
        case .monthly, .yearly:
            return nil
        case .lifetime:
            return "subscription.plan.lifetime.comparison_prefix"
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
    case subDubVideoConversion
    case subDubAI
    case subDubSubtitle
    case subDubAudioReplacement

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
        case .subDubVideoConversion:
            return "subscription.lock.subdub_video_conversion"
        case .subDubAI:
            return "subscription.lock.subdub_ai"
        case .subDubSubtitle:
            return "subscription.lock.subdub_subtitle"
        case .subDubAudioReplacement:
            return "subscription.lock.subdub_audio_replacement"
        }
    }
}
