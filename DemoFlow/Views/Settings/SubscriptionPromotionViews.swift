//
//  SubscriptionPromotionViews.swift
//  DemoFlow
//
//  2026-07-11 调整：订阅入口收敛为单窗口，三张方案卡横向排布。
//  2026-07-11 进一步调整：改为系统窗口承载，卡片收敛为更紧凑的竖卡。
//

import AppKit
import SwiftUI

enum SubscriptionWindowLayout {
    static let windowSize = CGSize(width: 710, height: 470)
    static let contentPadding: CGFloat = 16
    static let topInset: CGFloat = 30
    static let sectionSpacing: CGFloat = 12
    static let chipSpacing: CGFloat = 8
    static let headerIconSize: CGFloat = 50
    static let planCardWidth: CGFloat = 196
    static let planCardSpacing: CGFloat = 10
    static let planCardMinHeight: CGFloat = 176
    static let planCardPadding: CGFloat = 12
    static let footerButtonHeight: CGFloat = 44
}

private enum SubscriptionPalette {
    static let backgroundTop = Color(red: 1.00, green: 0.97, blue: 0.94)
    static let backgroundBottom = Color(red: 1.00, green: 0.92, blue: 0.86)
    static let headerStart = Color(red: 1.00, green: 0.44, blue: 0.40)
    static let headerEnd = Color(red: 0.97, green: 0.63, blue: 0.20)
    static let cardSelectedStart = Color(red: 1.00, green: 0.39, blue: 0.42)
    static let cardSelectedEnd = Color(red: 1.00, green: 0.34, blue: 0.37)
    static let cardDefaultStart = Color(red: 1.00, green: 0.93, blue: 0.89)
    static let cardDefaultEnd = Color(red: 1.00, green: 0.88, blue: 0.82)
    static let cardDefaultStroke = Color(red: 0.94, green: 0.71, blue: 0.64)
    static let ribbonStart = Color(red: 1.00, green: 0.75, blue: 0.16)
    static let ribbonEnd = Color(red: 0.98, green: 0.58, blue: 0.10)
    static let ctaStart = Color(red: 1.00, green: 0.41, blue: 0.36)
    static let ctaEnd = Color(red: 0.96, green: 0.56, blue: 0.19)
    static let inkPrimary = Color(red: 0.24, green: 0.14, blue: 0.13)
    static let inkSecondary = Color(red: 0.47, green: 0.31, blue: 0.29)
    static let secondaryButtonFill = Color.white.opacity(0.88)
    static let mutedText = Color.white.opacity(0.92)
}

struct SubscriptionWindowView: View {
    @ObservedObject var subscriptionViewModel: SubscriptionViewModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [SubscriptionPalette.backgroundTop, SubscriptionPalette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(SubscriptionPalette.ribbonStart.opacity(0.22))
                .frame(width: 240, height: 240)
                .blur(radius: 30)
                .offset(x: 240, y: -120)

            VStack(alignment: .leading, spacing: SubscriptionWindowLayout.sectionSpacing) {
                header
                featureStrip
                planRow
                Spacer(minLength: 0)
                footer
            }
            .padding(.top, SubscriptionWindowLayout.topInset)
            .padding(.horizontal, SubscriptionWindowLayout.contentPadding)
            .padding(.bottom, SubscriptionWindowLayout.contentPadding)
        }
        .task {
            await subscriptionViewModel.bootstrap()
        }
        .frame(
            width: SubscriptionWindowLayout.windowSize.width,
            height: SubscriptionWindowLayout.windowSize.height,
            alignment: .topLeading
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                SubscriptionPalette.headerStart,
                                SubscriptionPalette.headerEnd
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: SubscriptionWindowLayout.headerIconSize, height: SubscriptionWindowLayout.headerIconSize)

                Image(systemName: "crown.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(L10n.tr("subscription.teaser.title"))
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(SubscriptionPalette.inkPrimary)

                    membershipStatusChip
                }

                Text(L10n.tr("subscription.teaser.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(SubscriptionPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.tr("subscription.teaser.no_account"))
                    .font(.footnote)
                    .foregroundStyle(SubscriptionPalette.inkSecondary.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)

                if subscriptionViewModel.isProUnlocked {
                    Label(L10n.tr("subscription.teaser.already_pro"), systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.green)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var featureStrip: some View {
        HStack(spacing: SubscriptionWindowLayout.chipSpacing) {
            featureChip(systemImage: "sparkles", textKey: "subscription.pitch.quality")
            featureChip(systemImage: "rectangle.stack.badge.person.crop", textKey: "subscription.pitch.batch")
            featureChip(systemImage: "person.badge.key", textKey: "subscription.pitch.no_account")
        }
    }

    private var planRow: some View {
        HStack(alignment: .top, spacing: SubscriptionWindowLayout.planCardSpacing) {
            ForEach(SubscriptionPlan.allCases) { plan in
                SubscriptionPlanCardView(
                    plan: plan,
                    priceText: subscriptionViewModel.displayPriceText(for: plan),
                    isSelected: subscriptionViewModel.selectedPlan == plan,
                    isDisabled: subscriptionViewModel.isPurchasing || subscriptionViewModel.isLoadingProducts || !subscriptionViewModel.canSelectPlan(plan),
                    badgeText: subscriptionViewModel.planBadgeText(for: plan),
                    onTap: {
                        subscriptionViewModel.selectPlan(plan)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                statusPill(subscriptionViewModel.statusMessage ?? L10n.tr("subscription.status.loading"))

                #if DEBUG
                if subscriptionViewModel.isUsingDebugFallback {
                    Button(L10n.tr("subscription.debug.clear")) {
                        subscriptionViewModel.clearDebugFallback()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SubscriptionPalette.inkPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SubscriptionPalette.secondaryButtonFill)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SubscriptionPalette.cardDefaultStroke.opacity(0.75), lineWidth: 1)
                    )
                }
                #endif
            }

            #if DEBUG
            Text(subscriptionViewModel.debugRunMarkerMessage)
                .font(.caption2.monospaced())
                .foregroundStyle(SubscriptionPalette.inkSecondary.opacity(0.9))
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button {
                    SubscriptionDiagnosticsStore.shared.openLogFile()
                } label: {
                    Label(L10n.tr("subscription.debug.open_log"), systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(L10n.f("subscription.debug.log_path", SubscriptionDiagnosticsStore.shared.logFileURL.path))
                    .font(.caption2.monospaced())
                    .foregroundStyle(SubscriptionPalette.inkSecondary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let debugFallbackExpirationText = subscriptionViewModel.debugFallbackExpirationText {
                Text(debugFallbackExpirationText)
                    .font(.caption)
                    .foregroundStyle(SubscriptionPalette.inkSecondary)
            }

            if let productLoadDiagnosticsMessage = subscriptionViewModel.productLoadDiagnosticsMessage {
                Text(productLoadDiagnosticsMessage)
                    .font(.caption2.monospaced())
                    .foregroundStyle(SubscriptionPalette.inkSecondary.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            #endif

            Button {
                Task { @MainActor in
                    let outcome = await subscriptionViewModel.purchaseSelectedPlan()
                    if case .success = outcome, subscriptionViewModel.isProUnlocked {
                        onClose()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if subscriptionViewModel.isPurchasing || subscriptionViewModel.isLoadingProducts {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }

                    Text(subscriptionViewModel.purchaseActionTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: SubscriptionWindowLayout.footerButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SubscriptionPalette.ctaStart, SubscriptionPalette.ctaEnd],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!subscriptionViewModel.canPurchaseSelectedPlan)
            .opacity(subscriptionViewModel.canPurchaseSelectedPlan ? 1 : 0.72)

            HStack(spacing: 10) {
                Button(L10n.tr("subscription.paywall.restore")) {
                    Task { @MainActor in
                        _ = await subscriptionViewModel.restorePurchases()
                        if subscriptionViewModel.isProUnlocked {
                            onClose()
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SubscriptionPalette.inkPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(SubscriptionPalette.secondaryButtonFill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(SubscriptionPalette.cardDefaultStroke.opacity(0.75), lineWidth: 1)
                )
                .disabled(subscriptionViewModel.isPurchasing)
                .opacity(subscriptionViewModel.isPurchasing ? 0.6 : 1)

                Button(L10n.tr("subscription.paywall.later")) {
                    onClose()
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SubscriptionPalette.inkPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(SubscriptionPalette.secondaryButtonFill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(SubscriptionPalette.cardDefaultStroke.opacity(0.75), lineWidth: 1)
                )
                .disabled(subscriptionViewModel.isPurchasing)
                .opacity(subscriptionViewModel.isPurchasing ? 0.6 : 1)

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var membershipStatusChip: some View {
        if let badgeText = subscriptionViewModel.membershipBadgeText {
            Text(badgeText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SubscriptionPalette.headerStart, SubscriptionPalette.headerEnd],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        } else {
            Text(L10n.tr("subscription.paywall.version_label"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(SubscriptionPalette.headerEnd)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(SubscriptionPalette.headerEnd.opacity(0.14))
                )
        }
    }

    @ViewBuilder
    private func statusPill(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(subscriptionViewModel.isPurchasing ? Color.orange : SubscriptionPalette.headerEnd)
                .frame(width: 7, height: 7)

            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(SubscriptionPalette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.78))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(SubscriptionPalette.cardDefaultStroke.opacity(0.6), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func featureChip(systemImage: String, textKey: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(SubscriptionPalette.inkSecondary)

            Text(L10n.tr(textKey))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(SubscriptionPalette.inkSecondary)
        }
        .padding(.trailing, 18)
        .allowsHitTesting(false)
    }
}

private struct SubscriptionPlanCardView: View {
    let plan: SubscriptionPlan
    let priceText: String
    let isSelected: Bool
    let isDisabled: Bool
    let badgeText: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .center, spacing: 8) {
                Spacer(minLength: 6)
                Text(L10n.tr(plan.titleKey))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(cardPrimaryTextColor)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)

                Text(planSummaryText)
                    .font(.caption)
                    .foregroundStyle(cardSecondaryTextColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)

                VStack(alignment: .center, spacing: 2) {
                    Text(priceText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(cardPrimaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(plan.compareAtPriceText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(cardSecondaryTextColor)
                        .strikethrough()
                }
                .frame(maxWidth: .infinity)
            }
            .padding(SubscriptionWindowLayout.planCardPadding)
            .frame(maxWidth: .infinity, minHeight: SubscriptionWindowLayout.planCardMinHeight, alignment: .center)
            .opacity(isDisabled && !isSelected ? 0.78 : 1)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isSelected
                                ? [SubscriptionPalette.cardSelectedStart, SubscriptionPalette.cardSelectedEnd]
                                : [SubscriptionPalette.cardDefaultStart, SubscriptionPalette.cardDefaultEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.9) : SubscriptionPalette.cardDefaultStroke.opacity(0.8), lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .topLeading) {
                if let badgeText {
                    PlanBadgeView(text: badgeText)
                }
            }
            .overlay(alignment: .topTrailing) {
                DiscountRibbon(text: ribbonText)
            }
            .shadow(color: isSelected ? SubscriptionPalette.cardSelectedStart.opacity(0.22) : Color.black.opacity(0.07), radius: isSelected ? 12 : 7, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .frame(width: SubscriptionWindowLayout.planCardWidth)
    }

    private var cardPrimaryTextColor: Color {
        isSelected ? .white : SubscriptionPalette.inkPrimary
    }

    private var cardSecondaryTextColor: Color {
        isSelected ? SubscriptionPalette.mutedText : SubscriptionPalette.inkSecondary
    }

    private var planSummaryText: String {
        L10n.tr(plan.subtitleKey)
    }

    private var ribbonText: String {
        guard let badgeTextKey = plan.badgeTextKey else { return "-50%" }
        return compactDiscountText(from: L10n.tr(badgeTextKey))
    }

    private func compactDiscountText(from source: String) -> String {
        let digits = source.filter(\.isNumber)
        guard !digits.isEmpty else { return source }
        return "-\(digits)%"
    }
}

private struct PlanBadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.62))
            )
            .padding(.top, 10)
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
    }
}

private struct DiscountRibbon: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SubscriptionPalette.ribbonStart, SubscriptionPalette.ribbonEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: SubscriptionPalette.ribbonEnd.opacity(0.18), radius: 4, y: 2)
        .padding(.top, 10)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .accessibilityHidden(true)
    }
}
