//
//  SubscriptionViewModel.swift
//  DemoFlow
//
//  2026-07-11 新增：订阅商品加载、购买、恢复与权益判断。
//

import Combine
import Foundation
import StoreKit

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
    @Published private(set) var isUsingDebugFallback = false
    @Published var selectedPlan: SubscriptionPlan = .yearly

    private var hasBootstrapped = false
    private var transactionObserverTask: Task<Void, Never>?
#if DEBUG
    private var lastProductLoadDiagnostics: String?

    var productLoadDiagnosticsMessage: String? {
        guard isUsingDebugFallback,
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
        products.count == SubscriptionPlan.allCases.count
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
        if !hasBootstrapped {
            hasBootstrapped = true
            startTransactionObserverIfNeeded()
        }
        await loadProductsIfNeeded()
        await refreshEntitlements()
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

        for attempt in 0..<3 {
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
                NSLog("[Subscription] Product load attempt %d: %@", attempt + 1, lastProductLoadDiagnostics ?? "")
#endif

                if nextProducts.count == totalProductCount || !nextProducts.isEmpty {
                    break
                }
            } catch {
                lastError = error
                debugLogProductLoadFailure(error)
#if DEBUG
                lastProductLoadDiagnostics = "requested=[\(requestedProductIDs.joined(separator: ", "))] error=\(error.localizedDescription)"
#endif
            }

            guard attempt < 2 else { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        products = nextProducts
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
        products[plan]?.displayPrice ?? plan.priceText
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
            return .success
        }
        #endif

        guard let product = products[plan] else {
            let message = productsUnavailableMessage(error: nil)
            statusMessage = message
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
                    statusMessage = L10n.tr("subscription.status.purchase_verify_failed")
                    return .failed(L10n.tr("subscription.status.purchase_verify_failed"))
                }
            case .pending:
                statusMessage = L10n.tr("subscription.status.purchase_pending")
                return .pending
            case .userCancelled:
                statusMessage = L10n.tr("subscription.status.purchase_cancelled")
                return .cancelled
            @unknown default:
                statusMessage = L10n.tr("subscription.status.purchase_failed")
                return .failed(L10n.tr("subscription.status.purchase_failed"))
            }
        } catch {
            let message = L10n.tr("subscription.status.purchase_failed")
            statusMessage = message
            return .failed(message)
        }
    }

    func restorePurchases() async -> Bool {
        #if DEBUG
        if products.isEmpty, canUseDebugSubscriptionFallback {
            await refreshEntitlements()
            if isProUnlocked {
                statusMessage = L10n.tr("subscription.status.debug_fallback_restore_success")
                return true
            } else {
                statusMessage = L10n.tr("subscription.status.restore_empty")
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
                return true
            } else {
                statusMessage = L10n.tr("subscription.status.restore_empty")
                return false
            }
        } catch {
            statusMessage = L10n.tr("subscription.status.restore_failed")
            return false
        }
    }

    func refreshEntitlements() async {
        var activePlan: SubscriptionPlan?

        for await verificationResult in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verificationResult,
                  let plan = SubscriptionPlan(productID: transaction.productID) else {
                continue
            }
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
                    continue
                }
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

    #if DEBUG
    func clearDebugFallback() {
        UserDefaults.standard.removeObject(forKey: Self.debugFallbackPlanDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.debugFallbackExpirationDefaultsKey)
        isUsingDebugFallback = canUseDebugSubscriptionFallback
        statusMessage = L10n.tr("subscription.status.debug_fallback_cleared")
        Task { @MainActor in
            await refreshEntitlements()
        }
    }

    private var canUseDebugSubscriptionFallback: Bool {
        true
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
