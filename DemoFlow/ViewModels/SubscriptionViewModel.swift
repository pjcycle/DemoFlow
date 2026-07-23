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
    #endif

    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var activePlan: SubscriptionPlan?
    @Published private(set) var activeEntitlement: SubscriptionEntitlementStatus = .free
    @Published private(set) var membershipLevel: SubscriptionMembershipLevel = .free
    @Published private(set) var products: [SubscriptionPlan: Product] = [:]
    #if DEBUG
    @Published private(set) var syntheticProducts: [SubscriptionPlan: SyntheticStoreKitProduct] = [:]
    #endif
    @Published private(set) var isUsingDebugFallback = false
    @Published var selectedPlan: SubscriptionPlan = .yearly

    private var hasBootstrapped = false
    private var transactionObserverTask: Task<Void, Never>?
#if DEBUG
    private var lastProductLoadDiagnostics: String?
    private let debugBuildMarker = "SUBSCRIPTION-DIAG-2026-07-17-CANONICAL-STOREKIT"

    var debugRunMarkerMessage: String {
        let bundlePath = Bundle.main.bundleURL.path
        let realCount = products.count
        #if DEBUG
        let syntheticCount = syntheticProducts.count
        #else
        let syntheticCount = 0
        #endif
        let bundledCount = bundledStoreKitProductCount
        return "\(debugBuildMarker) | app=\(bundlePath) | bundledConfig=\(bundledCount)/\(SubscriptionPlan.allCases.count) | realProducts=\(realCount)/\(SubscriptionPlan.allCases.count) | syntheticProducts=\(syntheticCount)/\(SubscriptionPlan.allCases.count) | scheme=DemoFlow.storekit"
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
        // Prefer zh-Hans (matches project convention), then en_US, then first available.
        let preferredLocales = ["zh-Hans", "en_US"]
        for locale in preferredLocales {
            if let entry = localizations.first(where: { ($0["locale"] as? String) == locale }),
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

    var isProUnlocked: Bool {
        activeEntitlement.isPro
    }

    var membershipBadgeText: String? {
        membershipLevel.badgeTextKey.map { L10n.tr($0) }
    }

    var purchaseActionTitle: String {
        if let activePlan {
            if activePlan == .lifetime {
                return L10n.tr("subscription.paywall.already_lifetime")
            }

            guard selectedPlan.sortPriority > activePlan.sortPriority else {
                return L10n.tr("subscription.paywall.current_plan")
            }
            return L10n.f("subscription.paywall.upgrade_to", L10n.tr(selectedPlan.titleKey))
        }

        return L10n.tr("subscription.paywall.purchase")
    }

    var canPurchaseSelectedPlan: Bool {
        guard !isLoadingProducts, !isPurchasing else { return false }
        guard let activePlan else { return true }
        return selectedPlan.sortPriority > activePlan.sortPriority
    }

    var hasLoadedAllProducts: Bool {
        var loaded = products.count
        #if DEBUG
        loaded += syntheticProducts.count
        #endif
        return loaded == SubscriptionPlan.allCases.count
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
        diagnosticsLog("bootstrap begin; bundle=\(Bundle.main.bundleURL.path); bundleID=\(Bundle.main.bundleIdentifier ?? "<missing>"); version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "<missing>"); build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "<missing>"); arguments=\(ProcessInfo.processInfo.arguments.joined(separator: " | "))")
        diagnosticsLogBundledStoreKitResources()
        if !hasBootstrapped {
            hasBootstrapped = true
            startTransactionObserverIfNeeded()
            diagnosticsLog("transaction observer started")
        }
        await loadProductsIfNeeded()
        await refreshEntitlements()
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
        var nextProducts: [SubscriptionPlan: Product] = [:]
        var lastError: Error?

        diagnosticsLog("product load begin; requested=[\(requestedProductIDs.joined(separator: ", "))]")

        for attempt in 0..<3 {
            diagnosticsLog("product load attempt \(attempt + 1)/3 begin")
            do {
                let loaded = try await Product.products(for: requestedProductIDs)
                lastError = nil
                nextProducts.removeAll(keepingCapacity: true)
                for product in loaded {
                    guard let plan = SubscriptionPlan(productID: product.id) else { continue }
                    nextProducts[plan] = product
                }
#if DEBUG
                let returnedIDs = loaded.map(\.id).sorted().joined(separator: ", ")
                let missingIDs = requestedProductIDs.filter { id in !loaded.contains(where: { $0.id == id }) }
                    .sorted()
                    .joined(separator: ", ")
                lastProductLoadDiagnostics = "requested=[\(requestedProductIDs.joined(separator: ", "))] returned=[\(returnedIDs)] missing=[\(missingIDs)]"
                diagnosticsLog("product load attempt \(attempt + 1)/3 result; returned=[\(returnedIDs)]; missing=[\(missingIDs)]; count=\(loaded.count)")
                NSLog("[Subscription] Product load attempt %d: %@", attempt + 1, lastProductLoadDiagnostics ?? "")
                NSLog("[Subscription] %@", debugRunMarkerMessage)
#endif

#if !DEBUG
                let returnedIDs = loaded.map(\.id).sorted().joined(separator: ", ")
                let missingIDs = requestedProductIDs.filter { id in !loaded.contains(where: { $0.id == id }) }
                    .sorted()
                    .joined(separator: ", ")
                diagnosticsLog("product load attempt \(attempt + 1)/3 result; returned=[\(returnedIDs)]; missing=[\(missingIDs)]; count=\(loaded.count)")
#endif

                if nextProducts.count == totalProductCount || !nextProducts.isEmpty {
                    break
                }
            } catch {
                lastError = error
                debugLogProductLoadFailure(error)
                diagnosticsLog("product load attempt \(attempt + 1)/3 error; \(diagnosticErrorDescription(error))")
#if DEBUG
                lastProductLoadDiagnostics = "requested=[\(requestedProductIDs.joined(separator: ", "))] error=\(error.localizedDescription)"
#endif
            }

            guard attempt < 2 else { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        products = nextProducts
        #if DEBUG
        // Fill synthetic products (parsed directly from bundled .storekit JSON)
        // for any plans where the real StoreKit product is missing. This lets the
        // app surface prices and trigger the existing debug fallback purchase
        // path even when launched outside Xcode's StoreKit Test daemon.
        let parsedSynthetic = parseBundledStoreKitSyntheticProducts()
        var addedSyntheticCount = 0
        for plan in SubscriptionPlan.allCases where products[plan] == nil {
            guard syntheticProducts[plan] == nil, let synthetic = parsedSynthetic[plan] else { continue }
            syntheticProducts[plan] = synthetic
            addedSyntheticCount += 1
        }
        let syntheticCount = syntheticProducts.count
        let missingPlans = SubscriptionPlan.allCases
            .filter { products[$0] == nil && syntheticProducts[$0] == nil }
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        diagnosticsLog("synthetic product fill; parsed=\(parsedSynthetic.count); added=\(addedSyntheticCount); total=\(syntheticCount)/\(totalProductCount); missingPlans=[\(missingPlans)]")
        #endif
        diagnosticsLog("product load end; products=\(nextProducts.count)/\(totalProductCount); lastError=\(lastError.map(diagnosticErrorDescription) ?? "none"); fallbackAllowed=\(diagnosticsFallbackAllowed); fallbackActive=\(isUsingDebugFallback)")
        if nextProducts.count == totalProductCount {
            isUsingDebugFallback = false
            statusMessage = L10n.tr("subscription.status.products_loaded")
        } else if nextProducts.isEmpty {
            #if DEBUG
            if canUseDebugSubscriptionFallback {
                isUsingDebugFallback = true
                statusMessage = L10n.tr("subscription.status.debug_fallback_ready")
            } else {
                isUsingDebugFallback = false
                statusMessage = productsUnavailableMessage(error: lastError)
            }
            #else
            statusMessage = productsUnavailableMessage(error: lastError)
            #endif
        } else {
            isUsingDebugFallback = false
            statusMessage = L10n.tr("subscription.status.products_partial")
        }
    }

    func displayPriceText(for plan: SubscriptionPlan) -> String {
        if let product = products[plan] {
            return product.displayPrice
        }
        #if DEBUG
        if let synthetic = syntheticProducts[plan] {
            return synthetic.displayPrice
        }
        #endif
        return plan.priceText
    }

    func selectPlan(_ plan: SubscriptionPlan) {
        guard canSelectPlan(plan) else { return }
        selectedPlan = plan
    }

    func canSelectPlan(_ plan: SubscriptionPlan) -> Bool {
        guard !isLoadingProducts, !isPurchasing else { return false }
        guard let activePlan else { return true }
        return plan.sortPriority > activePlan.sortPriority
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
        if products[plan] == nil, canUseDebugSubscriptionFallback {
            persistDebugFallbackPlan(plan)
            await refreshEntitlements()
            statusMessage = L10n.f(
                "subscription.status.debug_fallback_purchase",
                L10n.tr(plan.titleKey)
            )
            diagnosticsLog("purchase debug fallback success; plan=\(plan.rawValue); expiration=\(persistedDebugFallbackExpirationDate.map(String.init(describing:)) ?? "none")")
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
        var entitlementProductIDs: [String] = []
        var entitlementResultCount = 0

        for await verificationResult in Transaction.currentEntitlements {
            entitlementResultCount += 1
            guard case .verified(let transaction) = verificationResult,
                  let plan = SubscriptionPlan(productID: transaction.productID) else {
                diagnosticsLog("entitlement ignored; result=unverified_or_unknown")
                continue
            }
            entitlementProductIDs.append(transaction.productID)
            diagnosticsLog("entitlement verified; productID=\(transaction.productID); transactionID=\(transaction.id)")
            if let currentPlan = activePlan {
                if plan.sortPriority > currentPlan.sortPriority {
                    activePlan = plan
                }
            } else {
                activePlan = plan
            }
        }

        #if DEBUG
        if activePlan == nil, canUseDebugSubscriptionFallback {
            activePlan = persistedDebugFallbackPlan
        }
        #endif

        applyActivePlan(activePlan)
        diagnosticsLog("entitlement refresh end; results=\(entitlementResultCount); productIDs=[\(entitlementProductIDs.sorted().joined(separator: ", "))]; activePlan=\(activePlan?.rawValue ?? "free"); membership=\(membershipLevel.rawValue); fallback=\(isUsingDebugFallback)")
    }

    deinit {
        transactionObserverTask?.cancel()
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

    private func applyActivePlan(_ plan: SubscriptionPlan?) {
        activePlan = plan
        activeEntitlement = SubscriptionEntitlementStatus(plan: plan)
        membershipLevel = SubscriptionMembershipLevel(activePlan: plan)
        selectedPlan = plan ?? .yearly
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

    private func productsUnavailableMessage(error: Error?) -> String {
        #if DEBUG
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
        #else
        return L10n.tr("subscription.status.products_failed")
        #endif
    }

    private func debugLogProductLoadFailure(_ error: Error) {
#if DEBUG
        NSLog("[Subscription] Product load failed: %@", String(describing: error))
#endif
    }

    private func diagnosticsLog(_ message: String) {
        SubscriptionDiagnosticsStore.shared.append(message)
    }

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
    func clearDebugFallback() {
        diagnosticsLog("debug fallback clear begin")
        UserDefaults.standard.removeObject(forKey: Self.debugFallbackPlanDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.debugFallbackExpirationDefaultsKey)
        isUsingDebugFallback = canUseDebugSubscriptionFallback
        statusMessage = L10n.tr("subscription.status.debug_fallback_cleared")
        diagnosticsLog("debug fallback cleared")
        Task { @MainActor in
            await refreshEntitlements()
        }
    }

    private var canUseDebugSubscriptionFallback: Bool {
        ProcessInfo.processInfo.arguments.contains("-DemoFlowEnableDebugSubscriptionFallback")
    }

    private var persistedDebugFallbackPlan: SubscriptionPlan? {
        guard let expirationDate = persistedDebugFallbackExpirationDate else { return nil }
        guard expirationDate > Date() else {
            UserDefaults.standard.removeObject(forKey: Self.debugFallbackPlanDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.debugFallbackExpirationDefaultsKey)
            return nil
        }

        guard let rawValue = UserDefaults.standard.string(forKey: Self.debugFallbackPlanDefaultsKey) else {
            return nil
        }
        return SubscriptionPlan(rawValue: rawValue)
    }

    private var persistedDebugFallbackExpirationDate: Date? {
        guard let timestamp = UserDefaults.standard.object(forKey: Self.debugFallbackExpirationDefaultsKey) as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func persistDebugFallbackPlan(_ plan: SubscriptionPlan) {
        UserDefaults.standard.set(plan.rawValue, forKey: Self.debugFallbackPlanDefaultsKey)
        UserDefaults.standard.set(debugFallbackExpirationDate(for: plan).timeIntervalSince1970, forKey: Self.debugFallbackExpirationDefaultsKey)
        isUsingDebugFallback = true
        NSLog("[Subscription] Persisted debug fallback plan: %@", plan.rawValue)
        diagnosticsLog("debug fallback activated; plan=\(plan.rawValue); expiration=\(debugFallbackExpirationDate(for: plan).description)")
    }

    private func debugFallbackExpirationDate(for plan: SubscriptionPlan) -> Date {
        let duration: TimeInterval
        switch plan {
        case .monthly:
            duration = 60
        case .yearly:
            duration = 5 * 60
        case .lifetime:
            duration = 10 * 60
        }
        return Date().addingTimeInterval(duration)
    }
    #endif
}
