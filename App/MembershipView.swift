import KeyboardCore
import StoreKit
import SwiftUI

struct MembershipView: View {
    @ObservedObject var store: MembershipStore
    let locale: OnboardingLocale
    let onboarding: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selected: MembershipPlan = .yearly
    private func t(_ s: String, _ h: String, _ e: String) -> String { locale.text(s, h, e) }
    private var checkingAccess: Bool { !store.hasAccess && (store.checkingEntitlements || store.loading) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "crown.fill").font(.system(size: 32)).foregroundStyle(Palette.accent)
                            .frame(width: 64, height: 64).background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityHidden(true)
                        Text(store.hasAccess ? t("学习已解锁", "學習已解鎖", "Learning is unlocked") : t("每次输入，都是一次记忆更新", "每次輸入，都是一次記憶更新", "Every word you type reinforces what you learn"))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        feature("character.bubble", t("19 种语言，实时显示译文", "19 種語言，即時顯示譯文", "Live translations in 19 languages"),
                                detail: t("支持中文和英文输入，在候选词上方边打边学。", "支援中文和英文輸入，在候選詞上方邊打邊學。", "Type in Chinese or English and learn from translations above your suggestions."))
                        feature("brain.head.profile", t("中文词库记忆，越用越顺手", "中文詞庫記憶，越用越順手", "A Chinese dictionary that learns with you"),
                                detail: t("记住常用词组，让中文候选更贴合你的输入习惯。", "記住常用詞組，讓中文候選更貼合你的輸入習慣。", "Remembers frequently used Chinese phrases for suggestions that fit your typing habits."))
                        feature("keyboard", t("熟悉的中文输入，自由选择", "熟悉的中文輸入，自由選擇", "Your preferred Chinese keyboard"),
                                detail: t("支持仓颉、九宫格和 26 键拼音，按习惯轻松输入。", "支援倉頡、九宮格和 26 鍵拼音，依習慣輕鬆輸入。", "Choose Cangjie, nine-key Pinyin or 26-key Pinyin and type your way."))
                    }
                    if store.hasAccess {
                        Label(t("会员权益已生效", "會員權益已生效", "Your membership is active"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Palette.accent)
                            .accessibilityIdentifier("membership.active")
                        Link(t("管理订阅", "管理訂閱", "Manage subscription"), destination: ProductLinks.manageSubscriptions)
                            .frame(minHeight: 44)
                    } else if checkingAccess {
                        ProgressView(t("正在核验会员权益", "正在核驗會員權益", "Checking membership"))
                            .accessibilityIdentifier("membership.checking")
                    } else {
                        VStack(spacing: 10) {
                            ForEach(MembershipPlan.allCases) { plan in planCard(plan) }
                        }.disabled(store.purchasing)

                    }
                    if let notice = store.notice {
                        Text(noticeText(notice)).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("membership.notice")
                    }
                    HStack {
                        Button(t("恢复购买", "恢復購買", "Restore Purchases")) { Task { await store.restore() } }
                            .accessibilityIdentifier("membership.restore")
                        Spacer()
                        if !store.hasAccess && !checkingAccess {
                            Button(t("重新加载", "重新載入", "Retry")) { Task { await store.loadProducts(); await store.refreshEntitlements() } }
                                .accessibilityIdentifier("membership.retry")
                        }
                    }.font(.subheadline).frame(minHeight: 44).disabled(store.purchasing || store.loading)
                    Text(t("基础打字始终可用。学习译文需要有效会员和已下载的语言包；可用语言以系统支持为准。", "基本打字始終可用。學習譯文需要有效會員和已下載的語言包；可用語言以系統支援為準。", "Basic typing remains available. Learning translations require active access and downloaded language packs. Available languages depend on system support."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .navigationTitle("TypeToLearn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel(t("关闭", "關閉", "Close"))
                        .accessibilityIdentifier("membership.close")
                }
            }
            .safeAreaInset(edge: .bottom) { purchaseFooter }
            .task { await store.loadProducts(); await store.refreshEntitlements() }
        }.tint(Palette.accent).environment(\.locale, Locale(identifier: locale.rawValue))
    }

    private func feature(_ symbol: String, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Palette.accent)
                .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
    private func title(_ plan: MembershipPlan) -> String {
        switch plan {
        case .monthly: t("月付", "月付", "Monthly")
        case .yearly: t("年付", "年付", "Yearly")
        case .lifetime: t("买断", "買斷", "Lifetime")
        }
    }
    private func planCard(_ plan: MembershipPlan) -> some View {
        Button { selected = plan } label: {
            HStack(spacing: 12) {
                Image(systemName: selected == plan ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text(title(plan)).font(.headline)
                            planBadge(plan)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title(plan)).font(.headline)
                            planBadge(plan)
                        }
                    }
                    Text(plan == .lifetime ? t("一次购买，持续解锁", "一次購買，持續解鎖", "One payment. Ongoing access.") :
                         (plan == .monthly && store.monthlyTrialEligible ? t("免费试用 3 天", "免費試用 3 天", "3-day free trial") : t("自动续订，可随时取消", "自動續訂，可隨時取消", "Auto-renews. Cancel anytime.")))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(store.product(plan)?.displayPrice ?? (store.loading ? t("加载中…", "載入中…", "Loading…") : t("暂不可用", "暫不可用", "Unavailable"))).font(.headline)
                    Text(plan == .lifetime ? t("一次性", "一次性", "one time") : (plan == .monthly ? t("每月", "每月", "per month") : t("每年", "每年", "per year")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16).frame(maxWidth: .infinity, minHeight: 76)
                .background(selected == plan ? Palette.accent.opacity(0.07) : Palette.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected == plan ? Palette.accent : Color.clear, lineWidth: 1.5))
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .accessibilityAddTraits(selected == plan ? .isSelected : [])
            .accessibilityIdentifier("membership.plan.\(plan.rawValue)")
    }
    @ViewBuilder private func planBadge(_ plan: MembershipPlan) -> some View {
        if plan == .lifetime {
            badge(t("最划算", "最划算", "Best value"), background: Palette.offerRed)
                .accessibilityIdentifier("membership.badge.lifetime")
        } else if plan == .yearly, let discount = store.annualDiscount {
            badge(t("约 \(discount.chineseRate) 折", "約 \(discount.chineseRate) 折", "Save \(discount.savingsPercent)%"), background: Palette.offerRed)
                .accessibilityLabel(t("相比按月付费一年，约 \(discount.chineseRate) 折", "相比按月付費一年，約 \(discount.chineseRate) 折", "Save \(discount.savingsPercent)% compared with 12 monthly payments"))
                .accessibilityIdentifier("membership.badge.yearly")
        }
    }
    private func badge(_ text: String, background: Color) -> some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(.white)
            .fixedSize().padding(.horizontal, 8).padding(.vertical, 4)
            .background(background, in: Capsule())
    }
    private var purchaseFooter: some View {
        VStack(spacing: 8) {
            if !checkingAccess {
                if !store.hasAccess { Text(billingText).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                Button {
                    if store.hasAccess { dismiss() }
                    else { Task { await store.purchase(selected) } }
                } label: {
                    HStack {
                        if store.purchasing { ProgressView().tint(.white) }
                        Text(store.hasAccess ? t("继续", "繼續", "Continue") :
                             (selected == .monthly && store.monthlyTrialEligible ? t("开始 3 天免费试用", "開始 3 天免費試用", "Start 3-day free trial") :
                                (selected == .lifetime ? t("一次购买，解锁学习", "一次購買，解鎖學習", "Unlock lifetime access") : t("订阅并解锁", "訂閱並解鎖", "Subscribe and unlock"))))
                    }.font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent)
                    .disabled(store.purchasing || (!store.hasAccess && store.product(selected) == nil))
                    .accessibilityIdentifier(store.hasAccess ? "membership.continue" : "membership.purchase")
            }
            HStack(spacing: 12) {
                Link(t("隐私政策", "隱私政策", "Privacy Policy"), destination: ProductLinks.privacy)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("membership.privacy")
                Link(t("技术支持", "技術支援", "Support"), destination: ProductLinks.support)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("membership.support")
                Link(t("用户协议", "使用者協議", "Terms of Use"), destination: ProductLinks.terms)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("membership.terms")
            }.font(.footnote).multilineTextAlignment(.center)
            if onboarding && !store.hasAccess {
                Button(t("先使用基础键盘", "先使用基本鍵盤", "Continue with basic typing")) { dismiss() }
                    .font(.footnote).frame(minHeight: 44).accessibilityIdentifier("membership.skip")
            }
        }.padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: 620).frame(maxWidth: .infinity)
            .background(Palette.surface)
    }
    private var billingText: String {
        guard let price = store.product(selected)?.displayPrice else {
            return t("价格由 App Store 提供，请等待套餐加载。", "價格由 App Store 提供，請等待方案載入。", "Prices are provided by the App Store. Please wait for plans to load.")
        }
        if selected == .lifetime { return t("一次性付款 \(price)，不会自动续费。", "一次性付款 \(price)，不會自動續費。", "One payment of \(price). No automatic renewal.") }
        let unit = selected == .monthly ? t("月", "月", "month") : t("年", "年", "year")
        if selected == .monthly && store.monthlyTrialEligible {
            return t("免费试用 3 天，之后 \(price)/月自动续订；请在试用结束前至少 24 小时取消以避免扣费。", "免費試用 3 天，之後 \(price)/月自動續訂；請在試用結束前至少 24 小時取消以避免扣費。", "3 days free, then \(price)/month, auto-renewing. Cancel at least 24 hours before the trial ends to avoid a charge.")
        }
        return t("\(price)/\(unit)，自动续订。可在 Apple 账户订阅设置中取消。", "\(price)/\(unit)，自動續訂。可在 Apple 帳戶訂閱設定中取消。", "\(price)/\(unit), auto-renewing. Cancel in your Apple Account subscription settings.")
    }
    private func noticeText(_ notice: MembershipStore.Notice) -> String {
        switch notice {
        case .unavailable: t("暂时无法加载 App Store 套餐，请稍后重试。", "暫時無法載入 App Store 方案，請稍後重試。", "App Store plans are unavailable right now. Please try again.")
        case .purchaseFailed: t("购买未完成，请重试。", "購買未完成，請重試。", "The purchase wasn't completed. Please try again.")
        case .pending: t("购买正在等待批准，批准后会自动解锁。", "購買正在等待批准，批准後會自動解鎖。", "Your purchase is awaiting approval. Access unlocks after approval.")
        case .restored: t("购买已恢复。", "購買已恢復。", "Purchases restored.")
        case .nothingToRestore: t("此 Apple 账户没有可恢复的有效会员。", "此 Apple 帳戶沒有可恢復的有效會員。", "No active membership was found for this Apple Account.")
        case .verificationFailed: t("无法验证这笔购买，请恢复购买或联系支持。", "無法驗證這筆購買，請恢復購買或聯絡支援。", "This purchase couldn't be verified. Restore purchases or contact support.")
        case .sharingFailed: t("会员状态未能同步到键盘，请重新打开 App。", "會員狀態未能同步到鍵盤，請重新開啟 App。", "Membership couldn't sync to the keyboard. Please reopen the app.")
        }
    }
}
