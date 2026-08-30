//
//  SubscriptionViewModel.swift
//  DemoFlow
//
//  2026-07-11 新增：订阅商品加载、购买、恢复与权益判断。
//

import Combine
import Foundation
import StoreKit

#if DEBUG
/// Synthetic product parsed directly from a bundled `.storekit` JSON file.
/// Used as a fallback when real StoreKit 2 products cannot be loaded
/// (e.g., when running outside of Xcode IDE's StoreKit Test daemon).
struct SyntheticStoreKitProduct {
    let id: String
    let displayPrice: String
    let displayName: String
    let description: String
    let typeRaw: String
    let subscriptionPeriod: String?
}
#endif

@MainActor
final class SubscriptionViewModel: ObservableObject {
#if DEBUG
    private static let debugFallbackPlanDefaultsKey = "demoflow.subscription.debug.plan"
    private static let debugFallbackExpirationDefaultsKey = "demoflow.subscription.debug.expiration"
    private static let legacyDebugBypassEnabledDefaultsKey = "demoflow.subscription.debug.bypass.enabled"
#endif
#if DEBUG || DEMOFLOW_EXTERNAL_CHANNEL
    private static let diagnosticsVisibilityDefaultsKey = "demoflow.subscription.diagnostics.visible"
#endif

    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isSubscriptionDiagnosticsVisible = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var activePlan: SubscriptionPlan?
    @Published private(set) var activeExpirationDate: Date?
    @Published private(set) var activeEntitlement: SubscriptionEntitlementStatus = .free
    @Published private(set) var membershipLevel: SubscriptionMembershipLevel = .free
    @Published private(set) var products: [SubscriptionPlan: Product] = [:]
#if DEBUG
    @Published private(set) var syntheticProducts: [SubscriptionPlan: SyntheticStoreKitProduct] = [:]
    @Published private(set) var debugClearMessage: String?
    #endif
    @Published private(set) var isUsingDebugFallback = false
    @Published private(set) var isUsingFreeTrial = false
    @Published var selectedPlan: SubscriptionPlan = .yearly

    private let freeTrialStore = SubscriptionFreeTrialStore.shared

    init() {
#if DEBUG || DEMOFLOW_EXTERNAL_CHANNEL
        isSubscriptionDiagnosticsVisible =
            UserDefaults.standard.bool(forKey: Self.diagnosticsVisibilityDefaultsKey) ||
            ProcessInfo.processInfo.arguments.contains("-DemoFlowEnableSubscriptionDiagnostics")
#endif
    }

    private var hasBootstrapped = false
    private var transactionObserverTask: Task<Void, Never>?
    private var automaticProductRetryTask: Task<Void, Never>?
    private var automaticProductRetryIndex = 0
    private var lastProductLoadDiagnostics: String?
    private var lastProductLoadAttemptCount = 0
    private var lastProductLoadDate: Date?
    private var lastTransactionEnvironment: String?

    // StoreKit can become available a few seconds after a fresh install or a
    // network transition. Retry the catalogue a limited number of times so a
    // transient empty response does not leave the purchase window stranded.
    private var automaticProductRetryDelays: [UInt64] {
#if DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
        // TestFlight needs a short feedback loop while retaining the existing
        // local/App Store timing for the other build channels.
        return [
            1_000_000_000,
            3_000_000_000,
            8_000_000_000
        ]
#else
        return [
            2_000_000_000,
            6_000_000_000,
            15_000_000_000
        ]
#endif
    }
#if DEBUG
    private var localStoreKitSessionStatus: String {
        let hasInjectedURL = ProcessInfo.processInfo.environment["STOREKIT_CONFIGURATION_URL"] != nil
        if hasInjectedURL {
            return "xcode-injected"
        }
        return isLocalStoreKitRequested
            ? "xcode-scheme-requested-without-injected-url"
            : "not-requested"
    }
#endif

    private var isLocalStoreKitRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-DemoFlowLocalStoreKit")
    }
#if DEBUG
    private var debugBuildMarker: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let builtAt: String
        if let executableURL = Bundle.main.executableURL,
           let values = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            builtAt = formatter.string(from: date)
        } else {
            builtAt = "unknown"
        }
        return "version=\(version) build=\(build) executableBuiltAt=\(builtAt)"
    }

    var debugRunMarkerMessage: String {
        let bundlePath = Bundle.main.bundleURL.path
        let realCount = products.count
        #if DEBUG
        let syntheticCount = syntheticProducts.count
        #else
        let syntheticCount = 0
        #endif
        let bundledCount = bundledStoreKitProductCount
        return "\(debugBuildMarker) | app=\(bundlePath) | bundledConfig=\(bundledCount)/\(SubscriptionPlan.allCases.count) | realProducts=\(realCount)/\(SubscriptionPlan.allCases.count) | syntheticProducts=\(syntheticCount)/\(SubscriptionPlan.allCases.count) | localRequested=\(isLocalStoreKitRequested) | scheme=DemoFlow.storekit"
    }

    var storeKitDebugSummary: String {
        let injectedURL = ProcessInfo.processInfo.environment["STOREKIT_CONFIGURATION_URL"] ?? "<none>"
        let bundledURL = Bundle.main.url(forResource: "DemoFlow", withExtension: "storekit")?.path ?? "<none>"
        var lines = [
            "bundledConfig=\(bundledStoreKitProductCount)/\(SubscriptionPlan.allCases.count)   realProducts=\(products.count)/\(SubscriptionPlan.allCases.count)   syntheticProducts=\(syntheticProducts.count)/\(SubscriptionPlan.allCases.count)",
            "injectedURL=\(injectedURL)   bundledURL=\(bundledURL)",
            "localRequested=\(isLocalStoreKitRequested)   localSession=\(localStoreKitSessionStatus)   runtime=\(debugBuildMarker)"
        ]
        if let lastProductLoadDiagnostics, !lastProductLoadDiagnostics.isEmpty {
            lines.append(lastProductLoadDiagnostics)
        }
        return lines.joined(separator: "\n")
    }

    private var bundledStoreKitProductCount: Int {
        guard let url = Bundle.main.url(forResource: "DemoFlow", withExtension: "storekit"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }

        let directProducts = object["products"] as? [[String: Any]] ?? []
        let groups = object["subscriptionGroups"] as? [[String: Any]] ?? []
        let subscriptions = groups.reduce(0) { count, group in
            count + ((group["subscriptions"] as? [[String: Any]])?.count ?? 0)
        }
        return directProducts.count + subscriptions
    }

    #if DEBUG
    private func parseBundledStoreKitSyntheticProducts() -> [SubscriptionPlan: SyntheticStoreKitProduct] {
        guard let url = Bundle.main.url(forResource: "DemoFlow", withExtension: "storekit"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var result: [SubscriptionPlan: SyntheticStoreKitProduct] = [:]

        for product in object["products"] as? [[String: Any]] ?? [] {
            guard let id = product["productID"] as? String,
                  let plan = SubscriptionPlan(productID: id),
                  let displayPrice = product["displayPrice"] as? String else { continue }
            let localizations = product["localizations"] as? [[String: Any]] ?? []
            result[plan] = SyntheticStoreKitProduct(
                id: id,
                displayPrice: displayPrice,
                displayName: pickStoreKitLocalization(localizations: localizations, key: "displayName") ?? "",
                description: pickStoreKitLocalization(localizations: localizations, key: "description") ?? "",
                typeRaw: product["type"] as? String ?? "NonConsumable",
                subscriptionPeriod: nil
            )
        }

        for group in object["subscriptionGroups"] as? [[String: Any]] ?? [] {
            for subscription in group["subscriptions"] as? [[String: Any]] ?? [] {
                guard let id = subscription["productID"] as? String,
                      let plan = SubscriptionPlan(productID: id),
                      let displayPrice = subscription["displayPrice"] as? String else { continue }
                let localizations = subscription["localizations"] as? [[String: Any]] ?? []
                result[plan] = SyntheticStoreKitProduct(
                    id: id,
                    displayPrice: displayPrice,
                    displayName: pickStoreKitLocalization(localizations: localizations, key: "displayName") ?? "",
                    description: pickStoreKitLocalization(localizations: localizations, key: "description") ?? "",
                    typeRaw: subscription["type"] as? String ?? "RecurringSubscription",
                    subscriptionPeriod: subscription["recurringSubscriptionPeriod"] as? String
                )
            }
        }

        return result
    }

    private func pickStoreKitLocalization(localizations: [[String: Any]], key: String) -> String? {
        // Match locales case-insensitively so files using either "zh-Hans"/"zh_Hans"/"zh_CN"
        // can still surface Chinese copy on a Chinese-locale device.
        let preferredLocales = ["zh-Hans", "zh_CN", "en_US", "en"]
        for preferred in preferredLocales {
            if let entry = localizations.first(where: { ($0["locale"] as? String)?.lowercased() == preferred.lowercased() }),
               let value = entry[key] as? String {
                return value
            }
        }
        return localizations.first?[key] as? String
    }
    #endif

    var productLoadDiagnosticsMessage: String? {
        guard !hasLoadedAllProducts,
              let lastProductLoadDiagnostics,
              !lastProductLoadDiagnostics.isEmpty else {
            return nil
        }
        return L10n.f(
            "subscription.status.debug_fallback_diagnostics",
            lastProductLoadDiagnostics
        )
    }
#endif

    var isProUnlocked: Bool { activeEntitlement.isPro }

    var isFreeTrialAvailable: Bool {
        !isProUnlocked && freeTrialStore.canClaimTrial
    }

    @discardableResult
    func activateFreeTrial() -> Bool {
        guard !isProUnlocked else {
            statusMessage = L10n.tr("subscription.status.already_owned")
            return false
        }

        guard let expirationDate = freeTrialStore.claim() else {
            statusMessage = freeTrialStore.hasClaimedTrial()
                ? L10n.tr("subscription.status.free_trial_already_used")
                : L10n.tr("subscription.status.free_trial_unavailable")
            return false
        }

        isUsingFreeTrial = true
        applyActivePlan(.monthly, expirationDate: expirationDate)
        statusMessage = L10n.tr("subscription.status.free_trial_activated")
        diagnosticsLog(
            "public free trial activated; days=\(SubscriptionFreeTrialStore.trialDays); expiration=\(expirationDate)"
        )
        return true
    }

#if DEBUG
    var isDebugSubscriptionInfoClearAvailable: Bool { true }
#endif

    func toggleSubscriptionDiagnosticsVisibility() {
#if DEBUG || DEMOFLOW_EXTERNAL_CHANNEL
        isSubscriptionDiagnosticsVisible.toggle()
        UserDefaults.standard.set(
            isSubscriptionDiagnosticsVisible,
            forKey: Self.diagnosticsVisibilityDefaultsKey
        )
        diagnosticsLog(
            "subscription diagnostics visibility changed; visible=\(isSubscriptionDiagnosticsVisible)"
        )
#endif
    }

    var shouldOfferProductReload: Bool {
#if DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
        return !isProUnlocked &&
        !isLoadingProducts &&
        !isPurchasing &&
        products.count < SubscriptionPlan.allCases.count &&
        automaticProductRetryTask == nil
#else
        return !isProUnlocked && !isLoadingProducts && !isPurchasing && products.isEmpty
#endif
    }

#if DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
    /// TestFlight-only product diagnostics. The local Debug UI keeps its
    /// existing StoreKit diagnostics and fallback flow. Display is opt-in.
    var externalBuildMarker: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return L10n.f("subscription.debug.external_build_marker", version, build)
    }

    var subscriptionDiagnosticsSummary: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let requestedIDs = SubscriptionPlan.allCases.map(\.productID).joined(separator: ", ")
        let attemptText = lastProductLoadAttemptCount == 0
            ? "none"
            : "\(lastProductLoadAttemptCount)"
        let timeText: String
        if let lastProductLoadDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timeText = formatter.string(from: lastProductLoadDate)
        } else {
            timeText = "none"
        }

        return [
            "channel=external/testflight bundleID=\(Bundle.main.bundleIdentifier ?? "<missing>") version=\(version) build=\(build)",
            "storeKitEnvironment=\(storeKitEnvironmentDiagnostic) canMakePayments=\(AppStore.canMakePayments)",
            "requested=[\(requestedIDs)]",
            "realProducts=\(products.count)/\(SubscriptionPlan.allCases.count) attempt=\(attemptText) autoRetry=\(automaticProductRetryIndex)/\(automaticProductRetryDelays.count) last=\(timeText)",
            lastProductLoadDiagnostics ?? "returned=<not-started> missing=<not-started> error=<none>"
        ].joined(separator: "\n")
    }

    func openSubscriptionDiagnosticsLog() {
        SubscriptionDiagnosticsStore.shared.openLogFile()
    }
#endif

    var membershipBadgeText: String? {
        membershipLevel.badgeTextKey.map { L10n.tr($0) }
    }

    var membershipValidityText: String? {
        guard let activePlan else { return nil }

        if activePlan == .lifetime {
            return L10n.tr("subscription.membership.lifetime_svip")
        }

        guard let activeExpirationDate else { return nil }
        let remainingDays = max(
            0,
            Int(ceil(activeExpirationDate.timeIntervalSinceNow / (24 * 60 * 60)))
        )
        return L10n.f("subscription.membership.days_remaining", remainingDays)
    }

    var purchaseActionTitle: String {
        if let activePlan {
            if activePlan == .lifetime {
                return L10n.tr("subscription.paywall.already_lifetime")
            }

            guard selectedPlan.sortPriority > activePlan.sortPriority else {
                return L10n.tr("subscription.paywall.current_plan")
            }
            return L10n.tr("subscription.paywall.upgrade")
        }

        return L10n.tr("subscription.paywall.purchase")
    }

    var canPurchaseSelectedPlan: Bool {
        guard !isLoadingProducts, !isPurchasing else { return false }
        if let activePlan {
            guard selectedPlan.sortPriority > activePlan.sortPriority else { return false }
#if DEBUG
            if canUseDebugSubscriptionFallback || isDebugSubscriptionTrialAvailable {
                return true
            }
#endif
            return hasProduct(for: selectedPlan)
        }
#if DEBUG
        if canUseDebugSubscriptionFallback || isDebugSubscriptionTrialAvailable {
            return true
        }
#endif
        guard hasProduct(for: selectedPlan) else { return false }
        return true
    }

    var hasLoadedAllProducts: Bool {
        if products.count == SubscriptionPlan.allCases.count {
            return true
        }
#if DEBUG
        if canUseDebugSubscriptionFallback || isDebugSubscriptionTrialAvailable {
            return true
        }
#else
#endif
        return false
    }

    #if DEBUG
    var debugFallbackExpirationText: String? {
        guard isUsingDebugFallback, let expirationDate = persistedDebugFallbackExpirationDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return L10n.f(
            "subscription.status.debug_fallback_expiration",
            formatter.string(from: expirationDate)
        )
    }
    #endif

    func bootstrap() async {
        let env = ProcessInfo.processInfo.environment
        let storeKitURL = storeKitConfigurationDescription
        let injectedStoreKitURL = env["STOREKIT_CONFIGURATION_URL"] ?? "<none>"
        let hasInjectedStoreKitURL = env["STOREKIT_CONFIGURATION_URL"] != nil
        let xpcService = env["XPC_SERVICE_NAME"] ?? "<none>"
        diagnosticsLog("bootstrap begin; bundle=\(Bundle.main.bundleURL.path); bundleID=\(Bundle.main.bundleIdentifier ?? "<missing>"); version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "<missing>"); build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "<missing>"); arguments=\(ProcessInfo.processInfo.arguments.joined(separator: " | "))")
        diagnosticsLog("env STOREKIT_CONFIGURATION_URL=\(injectedStoreKitURL); bundledStoreKit=\(storeKitURL); storeKitEnvironmentInjected=\(hasInjectedStoreKitURL); XPC_SERVICE_NAME=\(xpcService); localStoreKitRequested=\(isLocalStoreKitRequested)")
        diagnosticsLogBundledStoreKitResources()
        if !hasBootstrapped {
            hasBootstrapped = true
            startTransactionObserverIfNeeded()
            diagnosticsLog("transaction observer started")
        }
        await loadProductsIfNeeded()
        await refreshEntitlements()
#if DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
        // Do not delay product loading on the optional environment probe.
        await loadAppTransactionEnvironment()
#endif
        #if DEBUG
        let bootstrapRealCount = products.count
        let bootstrapSyntheticCount = syntheticProducts.count
        diagnosticsLog("bootstrap end; realProducts=\(bootstrapRealCount)/\(SubscriptionPlan.allCases.count); syntheticProducts=\(bootstrapSyntheticCount)/\(SubscriptionPlan.allCases.count); activePlan=\(activePlan?.rawValue ?? "free"); fallback=\(isUsingDebugFallback)")
        #else
        diagnosticsLog("bootstrap end; products=\(products.count)/\(SubscriptionPlan.allCases.count); activePlan=\(activePlan?.rawValue ?? "free"); fallback=\(isUsingDebugFallback)")
        #endif
    }

    func loadProductsIfNeeded(forceReload: Bool = false) async {
        guard !isLoadingProducts else { return }
        guard forceReload || products.isEmpty || !hasLoadedAllProducts else { return }
        isLoadingProducts = true
        statusMessage = L10n.tr("subscription.status.loading")
        defer { isLoadingProducts = false }
        let requestedProductIDs = SubscriptionPlan.allCases.map(\.productID)
        let totalProductCount = requestedProductIDs.count
        lastProductLoadAttemptCount = 0
        lastProductLoadDate = Date()
        lastProductLoadDiagnostics = "requested=[\(requestedProductIDs.joined(separator: ", "))] returned=<pending> missing=<pending> error=<none>"

#if DEBUG
        // The fallback-only scheme must remain usable when StoreKit is not
        // available. The regular Debug scheme still exercises real local
        // StoreKit because it passes -DemoFlowLocalStoreKit.
        if canUseDebugSubscriptionFallback && !isLocalStoreKitRequested {
            let parsedSynthetic = parseBundledStoreKitSyntheticProducts()
            syntheticProducts = parsedSynthetic
            isUsingDebugFallback = persistedDebugFallbackPlan != nil
            lastProductLoadAttemptCount = 1
            lastProductLoadDiagnostics = "requested=[\(requestedProductIDs.joined(separator: ", "))] returned=[] missing=[\(requestedProductIDs.joined(separator: ", "))] error=<none> mode=explicit-debug-fallback"
            diagnosticsLog("product load bypassed StoreKit; synthetic=\(parsedSynthetic.count)/\(totalProductCount); mode=explicit-debug-fallback")
            statusMessage = L10n.tr("subscription.status.debug_fallback_ready")
            return
        }
#endif

        // Preserve a previously loaded product if a later refresh is affected
        // by a temporary StoreKit outage. A cached Product remains valid for
        // the current app session and still drives the system purchase sheet.
        var nextProducts = products
        var lastError: Error?

        diagnosticsLog("product load begin; requested=[\(requestedProductIDs.joined(separator: ", "))]")

        for attempt in 0..<3 {
            lastProductLoadAttemptCount = attempt + 1
            lastProductLoadDate = Date()
            diagnosticsLog("product load attempt \(attempt + 1)/3 begin")
            do {
                let loaded = try await Product.products(for: requestedProductIDs)
                let debugURL = storeKitConfigurationDescription
                diagnosticsLog("Product.products(for:) returned count=\(loaded.count); IDs=[\(loaded.map(\.id).sorted().joined(separator: ", "))]; storeKitURL=\(debugURL)")
                lastError = nil
                for product in loaded {
                    guard let plan = SubscriptionPlan(productID: product.id) else { continue }
                    nextProducts[plan] = product
                }
                let returnedIDs = loaded.map(\.id).sorted().joined(separator: ", ")
                let missingIDs = requestedProductIDs.filter { id in !loaded.contains(where: { $0.id == id }) }
                    .sorted()
                    .joined(separator: ", ")
                lastProductLoadDiagnostics = "requested=[\(requestedProductIDs.joined(separator: ", "))] returned=[\(returnedIDs)] missing=[\(missingIDs)]"
                diagnosticsLog("product load attempt \(attempt + 1)/3 result; returned=[\(returnedIDs)]; missing=[\(missingIDs)]; count=\(loaded.count)")
#if DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
                if isSubscriptionDiagnosticsVisible {
                    NSLog("[Subscription] Product load attempt %d: %@", attempt + 1, lastProductLoadDiagnostics ?? "")
                }
#if DEBUG
                NSLog("[Subscription] %@", debugRunMarkerMessage)
#endif
#endif

                if nextProducts.count == totalProductCount || !nextProducts.isEmpty {
                    break
                }
            } catch {
                lastError = error
                debugLogProductLoadFailure(error)
                diagnosticsLog("product load attempt \(attempt + 1)/3 error; \(diagnosticErrorDescription(error))")
#if DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
                lastProductLoadDiagnostics = "requested=[\(requestedProductIDs.joined(separator: ", "))] returned=[] missing=[\(requestedProductIDs.joined(separator: ", "))] error=\(diagnosticErrorDescription(error))"
#else
                lastProductLoadDiagnostics = "requested=[\(requestedProductIDs.joined(separator: ", "))] error=\(error.localizedDescription)"
#endif
            }

            guard attempt < 2 else { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        products = nextProducts
        selectFirstAvailablePlanIfNeeded(from: nextProducts)
        #if DEBUG
        for plan in SubscriptionPlan.allCases where products[plan] != nil {
            syntheticProducts.removeValue(forKey: plan)
        }
        if products.count == totalProductCount {
            syntheticProducts.removeAll()
        } else if canUseDebugSubscriptionFallback {
            let parsedSynthetic = parseBundledStoreKitSyntheticProducts()
            var addedSyntheticCount = 0
            for plan in SubscriptionPlan.allCases where products[plan] == nil {
                guard syntheticProducts[plan] == nil, let synthetic = parsedSynthetic[plan] else { continue }
                syntheticProducts[plan] = synthetic
                addedSyntheticCount += 1
            }
            diagnosticsLog("synthetic product fill; parsed=\(parsedSynthetic.count); added=\(addedSyntheticCount); total=\(syntheticProducts.count)/\(totalProductCount); mode=explicit-debug-fallback")
        }
        let missingPlans = SubscriptionPlan.allCases
            .filter { products[$0] == nil && syntheticProducts[$0] == nil }
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        diagnosticsLog("product availability; real=\(products.count)/\(totalProductCount); synthetic=\(syntheticProducts.count)/\(totalProductCount); missingPlans=[\(missingPlans)]")
        #endif
        diagnosticsLog("product load end; products=\(nextProducts.count)/\(totalProductCount); lastError=\(lastError.map(diagnosticErrorDescription) ?? "none"); fallbackAllowed=\(diagnosticsFallbackAllowed); fallbackActive=\(isUsingDebugFallback)")
        if nextProducts.count == totalProductCount {
            isUsingDebugFallback = false
            cancelAutomaticProductRetry()
            statusMessage = L10n.tr("subscription.status.products_loaded")
        } else if nextProducts.isEmpty {
            #if DEBUG
            if canUseDebugSubscriptionFallback {
                isUsingDebugFallback = persistedDebugFallbackPlan != nil
                statusMessage = L10n.tr("subscription.status.debug_fallback_ready")
            } else {
                isUsingDebugFallback = false
                statusMessage = productsUnavailableMessage(error: lastError)
            }
            #else
            statusMessage = productsUnavailableStatusMessage(error: lastError)
            scheduleAutomaticProductRetryIfNeeded()
            #endif
        } else {
#if DEBUG
            if canUseDebugSubscriptionFallback && hasLoadedAllProducts {
                isUsingDebugFallback = persistedDebugFallbackPlan != nil
                statusMessage = L10n.tr("subscription.status.debug_fallback_ready")
            } else {
                isUsingDebugFallback = false
                statusMessage = L10n.tr("subscription.status.products_partial")
            }
#else
            isUsingDebugFallback = false
            statusMessage = productsPartialStatusMessage()
            scheduleAutomaticProductRetryIfNeeded()
#endif
        }
    }

    func reloadProducts() async {
        cancelAutomaticProductRetry(resetAttemptCount: true)
        await loadProductsIfNeeded(forceReload: true)
    }

    func displayPriceText(for plan: SubscriptionPlan) -> String {
        if let product = products[plan] {
            return product.displayPrice
        }
        #if DEBUG
        if canUseDebugSubscriptionFallback, let synthetic = syntheticProducts[plan] {
            return synthetic.displayPrice
        }
        #endif
        if isLoadingProducts || products.isEmpty {
            return L10n.tr("subscription.plan.price_loading")
        }
        return L10n.tr("subscription.plan.price_unavailable")
    }

    func selectPlan(_ plan: SubscriptionPlan) {
        guard canSelectPlan(plan) else { return }
        selectedPlan = plan
    }

    func canSelectPlan(_ plan: SubscriptionPlan) -> Bool {
        guard !isLoadingProducts, !isPurchasing else { return false }
        if let activePlan {
            guard plan.sortPriority > activePlan.sortPriority else { return false }
#if DEBUG
            if canUseDebugSubscriptionFallback || isDebugSubscriptionTrialAvailable {
                return true
            }
#endif
            return hasProduct(for: plan)
        }
#if DEBUG
        if canUseDebugSubscriptionFallback || isDebugSubscriptionTrialAvailable {
            return true
        }
#endif
        guard hasProduct(for: plan) else { return false }
        return true
    }

    func purchaseSelectedPlan() async -> SubscriptionPurchaseOutcome {
        guard canPurchaseSelectedPlan else {
            let message = currentPlanActionDisabledMessage
            statusMessage = message
            return .failed(message)
        }
        return await purchase(plan: selectedPlan)
    }

    func purchase(plan: SubscriptionPlan) async -> SubscriptionPurchaseOutcome {
        diagnosticsLog("purchase begin; plan=\(plan.rawValue); productID=\(plan.productID); cachedProduct=\(products[plan] != nil)")
        if products[plan] == nil {
            await loadProductsIfNeeded(forceReload: true)
        }

        #if DEBUG
        if products[plan] == nil, canUseDebugSubscriptionFallback || isDebugSubscriptionTrialAvailable {
            activateDebugSubscriptionTrial()
            diagnosticsLog("purchase debug fallback redirected to local trial; selectedPlan=\(plan.rawValue); expiration=\(persistedDebugFallbackExpirationDate.map(String.init(describing:)) ?? "none")")
            return .success
        }
        #endif

        guard let product = products[plan] else {
            let message = productsUnavailableMessage(error: nil)
            statusMessage = message
            diagnosticsLog("purchase unavailable; plan=\(plan.rawValue); products=\(products.keys.map(\.rawValue).sorted().joined(separator: ", "))")
            return .failed(message)
        }

        isPurchasing = true
        statusMessage = L10n.tr("subscription.status.purchase_waiting")
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verificationResult):
                switch verificationResult {
                case .verified(let transaction):
                    diagnosticsLog("purchase success verified; plan=\(plan.rawValue); transactionProductID=\(transaction.productID); transactionID=\(transaction.id)")
                    await transaction.finish()
                    await refreshEntitlements()
                    if isProUnlocked {
                        statusMessage = L10n.tr("subscription.status.purchase_success")
                        return .success
                    } else {
                        statusMessage = L10n.tr("subscription.status.purchase_verify_failed")
                        return .failed(L10n.tr("subscription.status.purchase_verify_failed"))
                    }
                case .unverified(_, _):
                    diagnosticsLog("purchase success but unverified; plan=\(plan.rawValue)")
                    statusMessage = L10n.tr("subscription.status.purchase_verify_failed")
                    return .failed(L10n.tr("subscription.status.purchase_verify_failed"))
                }
            case .pending:
                diagnosticsLog("purchase pending; plan=\(plan.rawValue)")
                statusMessage = L10n.tr("subscription.status.purchase_pending")
                return .pending
            case .userCancelled:
                diagnosticsLog("purchase cancelled by user; plan=\(plan.rawValue)")
                statusMessage = L10n.tr("subscription.status.purchase_cancelled")
                return .cancelled
            @unknown default:
                diagnosticsLog("purchase returned unknown result; plan=\(plan.rawValue)")
                statusMessage = L10n.tr("subscription.status.purchase_failed")
                return .failed(L10n.tr("subscription.status.purchase_failed"))
            }
        } catch {
            diagnosticsLog("purchase error; plan=\(plan.rawValue); \(diagnosticErrorDescription(error))")
            let message = L10n.tr("subscription.status.purchase_failed")
            statusMessage = message
            return .failed(message)
        }
    }

    func restorePurchases() async -> Bool {
        #if DEBUG
        let cachedTotal = products.count + syntheticProducts.count
        #else
        let cachedTotal = products.count
        #endif
        diagnosticsLog("restore begin; cachedProducts=\(cachedTotal)/\(SubscriptionPlan.allCases.count)")
#if DEBUG
        if products.isEmpty, canUseDebugSubscriptionFallback {
            await refreshEntitlements()
            if isProUnlocked {
                statusMessage = L10n.tr("subscription.status.debug_fallback_restore_success")
                diagnosticsLog("restore debug fallback success; activePlan=\(activePlan?.rawValue ?? "free")")
                return true
            } else {
                statusMessage = L10n.tr("subscription.status.restore_empty")
                diagnosticsLog("restore debug fallback empty")
                return false
            }
        }
        #endif

        statusMessage = L10n.tr("subscription.status.restore_waiting")
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if isProUnlocked {
                statusMessage = L10n.tr("subscription.status.restore_success")
                diagnosticsLog("restore success; activePlan=\(activePlan?.rawValue ?? "free")")
                return true
            } else {
                statusMessage = L10n.tr("subscription.status.restore_empty")
                diagnosticsLog("restore completed with no active entitlement")
                return false
            }
        } catch {
            diagnosticsLog("restore error; \(diagnosticErrorDescription(error))")
            statusMessage = L10n.tr("subscription.status.restore_failed")
            return false
        }
    }

    func refreshEntitlements() async {
        diagnosticsLog("entitlement refresh begin")
        var activePlan: SubscriptionPlan?
        var activeExpirationDate: Date?
        var entitlementProductIDs: [String] = []
        var entitlementResultCount = 0

        for await verificationResult in Transaction.currentEntitlements {
            entitlementResultCount += 1
            guard case .verified(let transaction) = verificationResult,
                  let plan = SubscriptionPlan(productID: transaction.productID) else {
                diagnosticsLog("entitlement ignored; result=unverified_or_unknown")
                continue
            }
            lastTransactionEnvironment = transaction.environment.rawValue
            entitlementProductIDs.append(transaction.productID)
            diagnosticsLog("entitlement verified; productID=\(transaction.productID); transactionID=\(transaction.id)")
            if let currentPlan = activePlan {
                if plan.sortPriority > currentPlan.sortPriority {
                    activePlan = plan
                    activeExpirationDate = transaction.expirationDate
                } else if plan == currentPlan,
                          let expirationDate = transaction.expirationDate,
                          expirationDate > (activeExpirationDate ?? .distantPast) {
                    activeExpirationDate = expirationDate
                }
            } else {
                activePlan = plan
                activeExpirationDate = transaction.expirationDate
            }
        }

        #if DEBUG
        if activePlan == nil {
            if let persistedPlan = persistedDebugFallbackPlan {
                activePlan = persistedPlan
                activeExpirationDate = persistedDebugFallbackExpirationDate
                isUsingDebugFallback = true
            } else {
                isUsingDebugFallback = false
            }
        } else {
            isUsingDebugFallback = false
        }
        #endif

        if activePlan == nil,
           let freeTrialExpirationDate = freeTrialStore.activeTrialExpirationDate() {
            activePlan = .monthly
            activeExpirationDate = freeTrialExpirationDate
            isUsingFreeTrial = true
        } else {
            isUsingFreeTrial = false
        }

        applyActivePlan(activePlan, expirationDate: activeExpirationDate)
        diagnosticsLog("entitlement refresh end; results=\(entitlementResultCount); productIDs=[\(entitlementProductIDs.sorted().joined(separator: ", "))]; activePlan=\(activePlan?.rawValue ?? "free"); membership=\(membershipLevel.rawValue); fallback=\(isUsingDebugFallback)")
    }

    deinit {
        transactionObserverTask?.cancel()
        automaticProductRetryTask?.cancel()
    }

    private func startTransactionObserverIfNeeded() {
        guard transactionObserverTask == nil else { return }

        transactionObserverTask = Task { [weak self] in
            guard let self else { return }

            for await verificationResult in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = verificationResult else {
                    self.diagnosticsLog("transaction update ignored; result=unverified")
                    continue
                }
                self.diagnosticsLog("transaction update verified; productID=\(transaction.productID); transactionID=\(transaction.id)")
                await transaction.finish()
                await self.refreshEntitlements()
            }
        }
    }

    private func applyActivePlan(_ plan: SubscriptionPlan?, expirationDate: Date? = nil) {
        activePlan = plan
        activeExpirationDate = expirationDate
        activeEntitlement = SubscriptionEntitlementStatus(plan: plan)
        membershipLevel = SubscriptionMembershipLevel(activePlan: plan)
        selectedPlan = plan ?? .yearly
    }

    private func selectFirstAvailablePlanIfNeeded(from availableProducts: [SubscriptionPlan: Product]) {
        guard activePlan == nil,
              availableProducts[selectedPlan] == nil else {
            return
        }

        let preferredOrder: [SubscriptionPlan] = [.yearly, .monthly, .lifetime]
        if let availablePlan = preferredOrder.first(where: { availableProducts[$0] != nil }) {
            selectedPlan = availablePlan
        }
    }

    private func scheduleAutomaticProductRetryIfNeeded() {
        guard automaticProductRetryTask == nil,
              automaticProductRetryIndex < automaticProductRetryDelays.count else {
            return
        }

        let delay = automaticProductRetryDelays[automaticProductRetryIndex]
        automaticProductRetryIndex += 1
        diagnosticsLog("product load retry scheduled; delayMs=\(delay / 1_000_000); retry=\(automaticProductRetryIndex)/\(automaticProductRetryDelays.count)")
        automaticProductRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            self.automaticProductRetryTask = nil
            await self.loadProductsIfNeeded(forceReload: true)
        }
    }

    private func cancelAutomaticProductRetry(resetAttemptCount: Bool = true) {
        automaticProductRetryTask?.cancel()
        automaticProductRetryTask = nil
        if resetAttemptCount {
            automaticProductRetryIndex = 0
        }
    }

    func planBadgeText(for plan: SubscriptionPlan) -> String? {
        if let activePlan {
            if plan == activePlan {
                return activePlan == .lifetime
                    ? L10n.tr("subscription.plan.badge.current_lifetime")
                    : L10n.tr("subscription.plan.badge.current")
            }

            if plan.sortPriority > activePlan.sortPriority {
                return L10n.tr("subscription.plan.badge.upgrade")
            }

            return L10n.tr("subscription.plan.badge.locked")
        }

        if plan.isRecommended {
            return L10n.tr("subscription.plan.recommended")
        }

        return nil
    }

    private var currentPlanActionDisabledMessage: String {
        if let activePlan {
            if activePlan == .lifetime {
                return L10n.tr("subscription.status.already_lifetime")
            }
            return L10n.tr("subscription.status.already_owned")
        }
        return L10n.tr("subscription.status.purchase_failed")
    }

    private func hasProduct(for plan: SubscriptionPlan) -> Bool {
        if products[plan] != nil {
            return true
        }
#if DEBUG
        return canUseDebugSubscriptionFallback && syntheticProducts[plan] != nil
#else
        return false
#endif
    }

    private func productsUnavailableMessage(error: Error?) -> String {
        #if DEBUG
        guard isSubscriptionDiagnosticsVisible else {
            return L10n.tr("subscription.status.products_failed")
        }
        if let error {
            return L10n.f(
                "subscription.status.products_failed_debug_reason",
                L10n.f("subscription.status.products_failed_debug_error", error.localizedDescription)
            )
        }

        let reason: String
        if let lastProductLoadDiagnostics, !lastProductLoadDiagnostics.isEmpty {
            reason = L10n.f(
                "subscription.status.products_failed_debug_diagnostics",
                lastProductLoadDiagnostics
            )
        } else {
            reason = L10n.tr("subscription.status.products_failed_debug_scheme")
        }
        return L10n.f("subscription.status.products_failed_debug_reason", reason)
        #elseif DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
        guard isSubscriptionDiagnosticsVisible else {
            return L10n.tr("subscription.status.products_failed_external")
        }
        if let error {
            return L10n.f(
                "subscription.status.products_failed_external_reason",
                L10n.f("subscription.status.products_failed_external_error", diagnosticErrorDescription(error))
            )
        }

        let diagnostics = lastProductLoadDiagnostics ?? L10n.tr("subscription.status.products_failed_external_no_diagnostics")
        return L10n.f(
            "subscription.status.products_failed_external_reason",
            L10n.f("subscription.status.products_failed_external_diagnostics", diagnostics)
        )
        #else
        return L10n.tr("subscription.status.products_failed")
        #endif
    }

    private func productsUnavailableStatusMessage(error: Error?) -> String {
        if automaticProductRetryIndex >= automaticProductRetryDelays.count {
            return productsUnavailableMessage(error: error)
        }
        return L10n.tr("subscription.status.products_connecting")
    }

    private func productsPartialStatusMessage() -> String {
#if DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
        if automaticProductRetryIndex >= automaticProductRetryDelays.count {
            return productsUnavailableMessage(error: nil)
        }
#endif
        return L10n.tr("subscription.status.products_partial")
    }

    private func debugLogProductLoadFailure(_ error: Error) {
#if DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
        guard isSubscriptionDiagnosticsVisible else { return }
        NSLog("[Subscription] Product load failed: %@", String(describing: error))
#endif
    }

    private func diagnosticsLog(_ message: String) {
        SubscriptionDiagnosticsStore.shared.append(message)
    }

    private var storeKitConfigurationDescription: String {
        if let injectedURL = ProcessInfo.processInfo.environment["STOREKIT_CONFIGURATION_URL"] {
            return injectedURL
        }
        if let bundledURL = Bundle.main.url(forResource: "DemoFlow", withExtension: "storekit") {
            return bundledURL.path
        }
        return "<not-injected>"
    }

#if DEMOFLOW_EXTERNAL_CHANNEL && !DEBUG
    private var storeKitEnvironmentDiagnostic: String {
        if let lastTransactionEnvironment {
            return lastTransactionEnvironment
        }

#if DEBUG
        if ProcessInfo.processInfo.environment["STOREKIT_CONFIGURATION_URL"] != nil || isLocalStoreKitRequested {
            return "xcode"
        }
#endif

        return "unknown-no-product-or-transaction"
    }

    private func loadAppTransactionEnvironment() async {
        if lastTransactionEnvironment != nil {
            return
        }

        do {
            switch try await AppTransaction.shared {
            case .verified(let transaction):
                lastTransactionEnvironment = transaction.environment.rawValue
                diagnosticsLog("AppTransaction.shared verified; environment=\(transaction.environment.rawValue); bundleID=\(transaction.bundleID); appVersion=\(transaction.appVersion)")
            case .unverified(_, let error):
                diagnosticsLog("AppTransaction.shared unverified; \(diagnosticErrorDescription(error))")
            }
        } catch {
            diagnosticsLog("AppTransaction.shared failed; \(diagnosticErrorDescription(error))")
        }
    }
#endif

    private func diagnosticErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain); code=\(nsError.code); description=\(nsError.localizedDescription); userInfo=\(nsError.userInfo)"
    }

    private var diagnosticsFallbackAllowed: Bool {
#if DEBUG
        return canUseDebugSubscriptionFallback
#else
        return false
#endif
    }

    private func diagnosticsLogBundledStoreKitResources() {
        let resources = Bundle.main.urls(forResourcesWithExtension: "storekit", subdirectory: nil) ?? []
        if resources.isEmpty {
            diagnosticsLog("StoreKit resource scan; resources=[]")
            return
        }

        for url in resources.sorted(by: { $0.path < $1.path }) {
            let data = try? Data(contentsOf: url)
            let parsed = parseStoreKitResource(data: data)
            diagnosticsLog("StoreKit resource; path=\(url.path); bytes=\(data?.count ?? 0); version=\(parsed.version); productIDs=[\(parsed.productIDs.joined(separator: ", "))]; count=\(parsed.productIDs.count)")
        }
    }

    private func parseStoreKitResource(data: Data?) -> (version: String, productIDs: [String]) {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (version: "unreadable", productIDs: [])
        }

        var productIDs: [String] = []
        let directProducts = object["products"] as? [[String: Any]] ?? []
        productIDs.append(contentsOf: directProducts.compactMap { $0["productID"] as? String })

        let groups = object["subscriptionGroups"] as? [[String: Any]] ?? []
        for group in groups {
            let subscriptions = group["subscriptions"] as? [[String: Any]] ?? []
            productIDs.append(contentsOf: subscriptions.compactMap { $0["productID"] as? String })
        }

        let versionObject = object["version"] as? [String: Any]
        let version: String
        if let major = versionObject?["major"], let minor = versionObject?["minor"] {
            version = "\(major).\(minor)"
        } else if let versionString = object["version"] as? String {
            version = versionString
        } else {
            version = "unknown"
        }

        return (version: version, productIDs: Array(Set(productIDs)).sorted())
    }

    #if DEBUG
    var isDebugSubscriptionTrialAvailable: Bool {
        canUseDebugSubscriptionFallback
    }

    func activateDebugSubscriptionTrial() {
        let expiration = Calendar.current.date(byAdding: .day, value: SubscriptionFreeTrialStore.trialDays, to: Date())
            ?? Date().addingTimeInterval(TimeInterval(SubscriptionFreeTrialStore.trialDays * 24 * 60 * 60))
        persistDebugFallbackPlan(.yearly, expiration: expiration)
        applyActivePlan(.yearly, expirationDate: expiration)
        isUsingDebugFallback = true
        statusMessage = L10n.tr("subscription.status.debug_bypass_activated")
        diagnosticsLog("debug subscription trial activated; days=\(SubscriptionFreeTrialStore.trialDays); expiration=\(expiration)")
    }

    func clearDebugFallback() {
        diagnosticsLog("debug fallback clear begin")
        UserDefaults.standard.removeObject(forKey: Self.debugFallbackPlanDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.debugFallbackExpirationDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyDebugBypassEnabledDefaultsKey)
        freeTrialStore.resetForDebugTesting()
        isUsingDebugFallback = false
        isUsingFreeTrial = false
        applyActivePlan(nil)
        statusMessage = L10n.tr("subscription.status.debug_fallback_cleared")
        debugClearMessage = L10n.tr("subscription.status.debug_fallback_cleared")
        diagnosticsLog("debug fallback cleared")
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEntitlements()
            SubscriptionDiagnosticsStore.shared.clear()
            if self.isProUnlocked {
                self.statusMessage = L10n.tr("subscription.status.debug_clear_storekit_active")
                self.debugClearMessage = L10n.tr("subscription.status.debug_clear_storekit_active")
            } else {
                self.statusMessage = L10n.tr("subscription.status.debug_fallback_cleared")
                self.debugClearMessage = L10n.tr("subscription.status.debug_fallback_cleared")
            }
        }
    }

    private var canUseDebugSubscriptionFallback: Bool {
        ProcessInfo.processInfo.arguments.contains("-DemoFlowEnableDebugSubscriptionFallback")
    }

    private var persistedDebugFallbackPlan: SubscriptionPlan? {
        // A persisted trial is inert unless this launch explicitly opts in.
        // This prevents switching schemes from silently granting membership.
        guard canUseDebugSubscriptionFallback else { return nil }
        guard let expirationDate = persistedDebugFallbackExpirationDate else { return nil }
        guard expirationDate > Date() else {
            UserDefaults.standard.removeObject(forKey: Self.debugFallbackPlanDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.debugFallbackExpirationDefaultsKey)
            return nil
        }

        guard let rawValue = UserDefaults.standard.string(forKey: Self.debugFallbackPlanDefaultsKey),
              let plan = SubscriptionPlan(rawValue: rawValue) else {
            return nil
        }
        // Migrate the legacy permanent debug bypass to the current bounded
        // Debug trial so it cannot continue to simulate a lifetime purchase.
        if UserDefaults.standard.bool(forKey: Self.legacyDebugBypassEnabledDefaultsKey) {
            let expiration = Calendar.current.date(
                byAdding: .day,
                value: SubscriptionFreeTrialStore.trialDays,
                to: Date()
            ) ?? Date().addingTimeInterval(
                TimeInterval(SubscriptionFreeTrialStore.trialDays * 24 * 60 * 60)
            )
            UserDefaults.standard.set(SubscriptionPlan.yearly.rawValue, forKey: Self.debugFallbackPlanDefaultsKey)
            UserDefaults.standard.set(expiration.timeIntervalSince1970, forKey: Self.debugFallbackExpirationDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyDebugBypassEnabledDefaultsKey)
            diagnosticsLog("migrated legacy debug bypass to bounded VIP trial; expiration=\(expiration)")
            return .yearly
        }
        return plan
    }

    private var persistedDebugFallbackExpirationDate: Date? {
        guard let timestamp = UserDefaults.standard.object(forKey: Self.debugFallbackExpirationDefaultsKey) as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func persistDebugFallbackPlan(_ plan: SubscriptionPlan, expiration: Date) {
        UserDefaults.standard.set(plan.rawValue, forKey: Self.debugFallbackPlanDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyDebugBypassEnabledDefaultsKey)
        UserDefaults.standard.set(expiration.timeIntervalSince1970, forKey: Self.debugFallbackExpirationDefaultsKey)
        isUsingDebugFallback = true
        NSLog("[Subscription] Persisted debug fallback plan: %@", plan.rawValue)
        diagnosticsLog("debug fallback activated; plan=\(plan.rawValue); expiration=\(expiration.description)")
    }

    var debugTrialDaysLabel: String {
        L10n.f("subscription.debug.trial_days", SubscriptionFreeTrialStore.trialDays)
    }
    #endif
}
