//
//  SubscriptionViewModel.swift
//  DemoFlow
//
//  StoreKit 2 商品、购买、恢复与权益判断。
//

import Combine
import Foundation
import StoreKit
#if DEBUG
import Security
#endif

@MainActor
final class SubscriptionViewModel: ObservableObject {
#if DEBUG
    private static let diagnosticsVisibilityDefaultsKey = "demoflow.subscription.diagnostics.visible"
#endif

    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false
#if DEBUG
    @Published private(set) var isSubscriptionDiagnosticsVisible = false
#endif
    @Published private(set) var statusMessage: String?
    @Published private(set) var activePlan: SubscriptionPlan?
    @Published private(set) var activeExpirationDate: Date?
    @Published private(set) var activeEntitlement: SubscriptionEntitlementStatus = .free
    @Published private(set) var membershipLevel: SubscriptionMembershipLevel = .free
    @Published private(set) var products: [SubscriptionPlan: Product] = [:]
    @Published var selectedPlan: SubscriptionPlan = .yearly

    private var hasBootstrapped = false
    private var transactionObserverTask: Task<Void, Never>?
    private var automaticProductRetryTask: Task<Void, Never>?
    private var automaticProductRetryIndex = 0
    private var lastProductLoadDiagnostics: String?
    private var lastProductLoadAttemptCount = 0
    private var lastProductLoadDate: Date?
#if DEBUG
    private var hasAppliedLocalSubscriptionTestReset = false
    private var forceFreeSubscriptionState = false
#endif

    init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        isSubscriptionDiagnosticsVisible = isLocalSubscriptionTestResetMode
            && (UserDefaults.standard.bool(forKey: Self.diagnosticsVisibilityDefaultsKey)
                || arguments.contains("-DemoFlowEnableSubscriptionDiagnostics"))
        forceFreeSubscriptionState = isLocalSubscriptionTestResetMode
            && arguments.contains(Self.forceFreeSubscriptionStateArgument)
#endif
    }

    private var automaticProductRetryDelays: [UInt64] {
        return [2_000_000_000, 6_000_000_000, 15_000_000_000]
    }

#if DEBUG
    private static let localSubscriptionResetArgument = "-DemoFlowEnableLocalSubscriptionReset"
    private static let localSubscriptionResetOnLaunchArgument = "-DemoFlowResetSubscriptionOnLaunch"
    private static let localSubscriptionTestResetArgument = "-DemoFlowLocalStoreKitTestReset"
    private static let forceFreeSubscriptionStateArgument = "-DemoFlowForceFreeSubscriptionState"
    private static let legacyTrialKeychainService = "pjln.top.demoflow.subscription"
    private static let legacyTrialKeychainAccounts = [
        "free-trial-device-id-v1",
        "free-trial-claim-v1"
    ]

    private var isLocalStoreKitRequested: Bool { ProcessInfo.processInfo.arguments.contains("-DemoFlowLocalStoreKit") }
    var isLocalSubscriptionTestResetMode: Bool {
        ProcessInfo.processInfo.arguments.contains(Self.localSubscriptionTestResetArgument)
    }
    /// A Debug-only local reset control. StoreKit transaction history is owned
    /// by Xcode's StoreKit Transaction Manager and cannot be cleared by the app.
    var isLocalSubscriptionResetAvailable: Bool {
        isLocalSubscriptionTestResetMode
            && ProcessInfo.processInfo.arguments.contains(Self.localSubscriptionResetArgument)
    }

    private var isLocalSubscriptionResetOnLaunch: Bool {
        isLocalSubscriptionResetAvailable
            && ProcessInfo.processInfo.arguments.contains(Self.localSubscriptionResetOnLaunchArgument)
    }

    /// Clears app-owned Debug subscription state and legacy trial remnants.
    /// StoreKit transaction history must be removed in Xcode's Transaction
    /// Manager. This never runs outside a Debug local StoreKit Scheme.
    func resetLocalSubscriptionTestData() {
        guard isLocalSubscriptionResetAvailable else { return }
        for account in Self.legacyTrialKeychainAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.legacyTrialKeychainService,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false
            ]
            SecItemDelete(query as CFDictionary)
        }
        [
            "demoflow.subscription.debug.plan",
            "demoflow.subscription.debug.expiration",
            "demoflow.subscription.debug.bypass.enabled"
        ].forEach(UserDefaults.standard.removeObject(forKey:))
        SubscriptionDiagnosticsStore.shared.clear()
        forceFreeSubscriptionState = true
        applyActivePlan(nil)
        statusMessage = L10n.tr("subscription.status.debug_reset_test_data")
        Task { [weak self] in
            guard let self else { return }
            await self.reloadProducts()
            await self.refreshEntitlements()
        }
    }

    private var localStoreKitSessionStatus: String {
        isLocalStoreKitRequested ? "scheme-configured" : "not-requested"
    }
    private var debugBuildMarker: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "version=\(version) build=\(build)"
    }
    var debugRunMarkerMessage: String {
        "\(debugBuildMarker) | bundledConfig=\(bundledStoreKitProductCount)/\(SubscriptionPlan.allCases.count) | products=\(products.count)/\(SubscriptionPlan.allCases.count)"
    }
    var storeKitDebugSummary: String {
        let bundled = Bundle.main.url(forResource: "DemoFlow", withExtension: "storekit")?.path ?? "<none>"
        return ["bundledConfig=\(bundledStoreKitProductCount)/\(SubscriptionPlan.allCases.count) products=\(products.count)/\(SubscriptionPlan.allCases.count)", "bundledURL=\(bundled)", "localRequested=\(isLocalStoreKitRequested) localSession=\(localStoreKitSessionStatus) runtime=\(debugBuildMarker)", lastProductLoadDiagnostics ?? "returned=<not-started> missing=<not-started> error=<none>"].joined(separator: "\n")
    }
    var productLoadDiagnosticsMessage: String? {
        guard !hasLoadedAllProducts, let diagnostics = lastProductLoadDiagnostics, !diagnostics.isEmpty else { return nil }
        return L10n.f("subscription.status.debug_product_diagnostics", diagnostics)
    }
#endif

#if DEBUG
    private var bundledStoreKitProductCount: Int {
        guard let url = Bundle.main.url(forResource: "DemoFlow", withExtension: "storekit"), let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        let direct = object["products"] as? [[String: Any]] ?? []
        let groups = object["subscriptionGroups"] as? [[String: Any]] ?? []
        return direct.count + groups.reduce(0) { $0 + (($1["subscriptions"] as? [[String: Any]])?.count ?? 0) }
    }
#endif

    var isProUnlocked: Bool { activeEntitlement.isPro }
    var membershipBadgeText: String? { membershipLevel.badgeTextKey.map { L10n.tr($0) } }
    var membershipValidityText: String? {
        if membershipLevel == .svip { return L10n.tr("subscription.membership.lifetime_svip") }
        guard let expiration = activeExpirationDate else { return nil }
        let days = max(0, Int(ceil(expiration.timeIntervalSinceNow / 86_400)))
        return days > 0 ? L10n.f("subscription.membership.days_remaining", days) : nil
    }
    var purchaseActionTitle: String {
        guard let activePlan else { return L10n.tr("subscription.paywall.purchase") }
        if activePlan == .lifetime { return L10n.tr("subscription.paywall.already_lifetime") }
        return selectedPlan.sortPriority > activePlan.sortPriority ? L10n.tr("subscription.paywall.upgrade") : L10n.tr("subscription.paywall.current_plan")
    }
    var canPurchaseSelectedPlan: Bool {
        guard !isPurchasing else { return false }
#if DEBUG
        // A displayed fallback price is diagnostic-only. A purchase must
        // always use a real StoreKit 2 Product returned by the active session.
#endif
        guard !isLoadingProducts, hasProduct(for: selectedPlan) else { return false }
        guard let activePlan else { return true }
        return selectedPlan.sortPriority > activePlan.sortPriority
    }
    var hasLoadedAllProducts: Bool { products.count == SubscriptionPlan.allCases.count }

    func toggleSubscriptionDiagnosticsVisibility() {
#if DEBUG
        guard isLocalSubscriptionTestResetMode else { return }
        isSubscriptionDiagnosticsVisible.toggle()
        UserDefaults.standard.set(isSubscriptionDiagnosticsVisible, forKey: Self.diagnosticsVisibilityDefaultsKey)
#endif
    }
    var shouldOfferProductReload: Bool { !isProUnlocked && !isLoadingProducts && !isPurchasing && products.count < SubscriptionPlan.allCases.count && automaticProductRetryTask == nil }

    func bootstrap() async {
        if !hasBootstrapped { hasBootstrapped = true; startTransactionObserverIfNeeded() }
#if DEBUG
        // The recording/free-state Scheme clears app-owned state at launch.
        // StoreKit transactions remain managed by Xcode's Transaction Manager.
        if isLocalSubscriptionResetOnLaunch, !hasAppliedLocalSubscriptionTestReset {
            hasAppliedLocalSubscriptionTestReset = true
            resetLocalSubscriptionTestData()
        }
#endif
        await loadProductsIfNeeded()
        await refreshEntitlements()
    }

    func loadProductsIfNeeded(forceReload: Bool = false) async {
        guard !isLoadingProducts, forceReload || products.isEmpty || !hasLoadedAllProducts else { return }
        isLoadingProducts = true
        statusMessage = L10n.tr("subscription.status.loading")
        defer { isLoadingProducts = false }
        let requestedIDs = SubscriptionPlan.allCases.map(\.productID)
        var nextProducts = products
        var lastError: Error?
        lastProductLoadAttemptCount = 0
        for attempt in 0..<3 {
            lastProductLoadAttemptCount = attempt + 1
            lastProductLoadDate = Date()
            do {
                let loaded = try await Product.products(for: requestedIDs)
                lastError = nil
                for product in loaded { if let plan = SubscriptionPlan(productID: product.id) { nextProducts[plan] = product } }
                let returned = loaded.map(\.id).sorted().joined(separator: ", ")
                let missing = requestedIDs.filter { id in !loaded.contains(where: { $0.id == id }) }.joined(separator: ", ")
                lastProductLoadDiagnostics = "requested=[\(requestedIDs.joined(separator: ", "))] returned=[\(returned)] missing=[\(missing)]"
                if !nextProducts.isEmpty { break }
            } catch {
                lastError = error
                lastProductLoadDiagnostics = "requested=[\(requestedIDs.joined(separator: ", "))] returned=[] error=\(error.localizedDescription)"
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 300_000_000) }
        }
        products = nextProducts
        selectFirstAvailablePlanIfNeeded()
        if products.count == requestedIDs.count {
            cancelAutomaticProductRetry()
            statusMessage = L10n.tr("subscription.status.products_loaded")
        } else if products.isEmpty {
            statusMessage = productsUnavailableStatusMessage(error: lastError)
            scheduleAutomaticProductRetryIfNeeded()
        } else {
            statusMessage = L10n.tr("subscription.status.products_partial")
            scheduleAutomaticProductRetryIfNeeded()
        }
    }

    func reloadProducts() async { cancelAutomaticProductRetry(); await loadProductsIfNeeded(forceReload: true) }
    func displayPriceText(for plan: SubscriptionPlan) -> String {
        if let product = products[plan] { return product.displayPrice }
        return isLoadingProducts ? L10n.tr("subscription.plan.price_loading") : L10n.tr("subscription.plan.price_unavailable")
    }
    func comparisonDisplayPriceText(for plan: SubscriptionPlan) -> String? {
        guard let reference = plan.comparisonReferencePlan else { return nil }
        if let product = products[reference] {
            let value = (product.price * Decimal(plan.comparisonMultiplier)).formatted(product.priceFormatStyle)
            return plan.comparisonPrefixKey.map { "\(L10n.tr($0)) \(value)" } ?? value
        }
        return nil
    }
    func comparisonDiscountPercent(for plan: SubscriptionPlan) -> Int? {
        guard let reference = plan.comparisonReferencePlan else { return nil }
        let current: Decimal
        let base: Decimal
        if let product = products[plan], let referenceProduct = products[reference] {
            current = product.price
            base = referenceProduct.price
        } else {
            return nil
        }
        let total = base * Decimal(plan.comparisonMultiplier)
        guard total > 0, current < total else { return nil }
        let savings = NSDecimalNumber(decimal: total - current).doubleValue
        return Int((savings / NSDecimalNumber(decimal: total).doubleValue * 100).rounded(.up))
    }
    func selectPlan(_ plan: SubscriptionPlan) { guard canSelectPlan(plan) else { return }; selectedPlan = plan }
    func canSelectPlan(_ plan: SubscriptionPlan) -> Bool {
        guard !isPurchasing, hasProduct(for: plan) else { return false }
        guard !isLoadingProducts else { return false }
        guard let activePlan else { return true }
        return plan.sortPriority > activePlan.sortPriority
    }
    func purchaseSelectedPlan() async -> SubscriptionPurchaseOutcome {
        guard canPurchaseSelectedPlan else { let message = currentPlanActionDisabledMessage; statusMessage = message; return .failed(message) }
        return await purchase(plan: selectedPlan)
    }
    func purchase(plan: SubscriptionPlan) async -> SubscriptionPurchaseOutcome {
        if products[plan] == nil { await loadProductsIfNeeded(forceReload: true) }
        guard let product = products[plan] else { let message = productsUnavailableMessage(error: nil); statusMessage = message; return .failed(message) }
        isPurchasing = true
        statusMessage = L10n.tr("subscription.status.purchase_waiting")
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
#if DEBUG
                forceFreeSubscriptionState = false
#endif
                await transaction.finish()
                await refreshEntitlements()
                guard isProUnlocked else { let message = L10n.tr("subscription.status.purchase_verify_failed"); statusMessage = message; return .failed(message) }
                statusMessage = L10n.tr("subscription.status.purchase_success"); return .success
            case .success(.unverified):
                let message = L10n.tr("subscription.status.purchase_verify_failed"); statusMessage = message; return .failed(message)
            case .pending: statusMessage = L10n.tr("subscription.status.purchase_pending"); return .pending
            case .userCancelled: statusMessage = L10n.tr("subscription.status.purchase_cancelled"); return .cancelled
            @unknown default: let message = L10n.tr("subscription.status.purchase_failed"); statusMessage = message; return .failed(message)
            }
        } catch { let message = L10n.tr("subscription.status.purchase_failed"); statusMessage = message; return .failed(message) }
    }
    func restorePurchases() async -> Bool {
        statusMessage = L10n.tr("subscription.status.restore_waiting")
        do {
            try await AppStore.sync()
#if DEBUG
            if isLocalSubscriptionTestResetMode { forceFreeSubscriptionState = false }
#endif
            await refreshEntitlements()
            statusMessage = isProUnlocked ? L10n.tr("subscription.status.restore_success") : L10n.tr("subscription.status.restore_empty")
            return isProUnlocked
        }
        catch { statusMessage = L10n.tr("subscription.status.restore_failed"); return false }
    }
    func refreshEntitlements() async {
        var bestPlan: SubscriptionPlan?
        var expiration: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, let plan = SubscriptionPlan(productID: transaction.productID) else { continue }
            if bestPlan == nil || plan.sortPriority > bestPlan!.sortPriority { bestPlan = plan; expiration = transaction.expirationDate }
            else if plan == bestPlan, let candidate = transaction.expirationDate, candidate > (expiration ?? .distantPast) { expiration = candidate }
        }
#if DEBUG
        if forceFreeSubscriptionState {
            applyActivePlan(nil)
            return
        }
#endif
        applyActivePlan(bestPlan, expirationDate: expiration)
    }

    deinit { transactionObserverTask?.cancel(); automaticProductRetryTask?.cancel() }
    private func startTransactionObserverIfNeeded() {
        guard transactionObserverTask == nil else { return }
        transactionObserverTask = Task { [weak self] in
            guard let self else { return }
            for await result in Transaction.updates {
                guard !Task.isCancelled, case .verified(let transaction) = result else { continue }
                await transaction.finish(); await self.refreshEntitlements()
            }
        }
    }
    private func applyActivePlan(_ plan: SubscriptionPlan?, expirationDate: Date? = nil) {
        activePlan = plan; activeExpirationDate = expirationDate; activeEntitlement = SubscriptionEntitlementStatus(plan: plan); membershipLevel = SubscriptionMembershipLevel(activePlan: plan); selectedPlan = plan ?? .yearly
    }
    private func selectFirstAvailablePlanIfNeeded() {
        guard activePlan == nil, !hasProduct(for: selectedPlan) else { return }
        if let plan = [SubscriptionPlan.yearly, .monthly, .lifetime].first(where: { hasProduct(for: $0) }) { selectedPlan = plan }
    }
    private func scheduleAutomaticProductRetryIfNeeded() {
        guard automaticProductRetryTask == nil, automaticProductRetryIndex < automaticProductRetryDelays.count else { return }
        let delay = automaticProductRetryDelays[automaticProductRetryIndex]; automaticProductRetryIndex += 1
        automaticProductRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.automaticProductRetryTask = nil; await self.loadProductsIfNeeded(forceReload: true)
        }
    }
    private func cancelAutomaticProductRetry() { automaticProductRetryTask?.cancel(); automaticProductRetryTask = nil; automaticProductRetryIndex = 0 }
    func planBadgeText(for plan: SubscriptionPlan) -> String? {
        if let activePlan { if plan == activePlan { return activePlan == .lifetime ? L10n.tr("subscription.plan.badge.current_lifetime") : L10n.tr("subscription.plan.badge.current") }; return plan.sortPriority > activePlan.sortPriority ? L10n.tr("subscription.plan.badge.upgrade") : L10n.tr("subscription.plan.badge.locked") }
        return plan.isRecommended ? L10n.tr("subscription.plan.recommended") : nil
    }
    private var currentPlanActionDisabledMessage: String { if activePlan == .lifetime { return L10n.tr("subscription.status.already_lifetime") }; if activePlan != nil { return L10n.tr("subscription.status.already_owned") }; return L10n.tr("subscription.status.purchase_failed") }
    private func hasProduct(for plan: SubscriptionPlan) -> Bool {
        products[plan] != nil
    }
    private func productsUnavailableMessage(error: Error?) -> String {
#if DEBUG
        guard isSubscriptionDiagnosticsVisible else { return L10n.tr("subscription.status.products_failed") }
        if let error { return L10n.f("subscription.status.products_failed_debug_reason", L10n.f("subscription.status.products_failed_debug_error", error.localizedDescription)) }
        return L10n.f("subscription.status.products_failed_debug_reason", lastProductLoadDiagnostics ?? L10n.tr("subscription.status.products_failed_debug_scheme"))
#else
        return L10n.tr("subscription.status.products_failed")
#endif
    }
    private func productsUnavailableStatusMessage(error: Error?) -> String { automaticProductRetryIndex >= automaticProductRetryDelays.count ? productsUnavailableMessage(error: error) : L10n.tr("subscription.status.products_connecting") }
}
