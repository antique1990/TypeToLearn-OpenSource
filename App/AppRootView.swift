import KeyboardCore
import SwiftUI
import Translation

struct AppRootView: View {
    @StateObject private var app = AppModel()
    @StateObject private var membership = MembershipStore()
    @State private var showingMembership = false
    @State private var membershipFromOnboarding = false
    @StateObject private var onboarding = OnboardingModel()
    @Environment(\.scenePhase) private var scenePhase

    private var pendingCurrentLanguage: Bool {
        let target = app.settings.audience == .english ? app.settings.englishTargetLanguageID : app.settings.targetLanguageID
        return onboarding.hasPendingDownload && onboarding.state.audience == app.settings.audience &&
            onboarding.state.targetLanguageID.map { Locale.Language(identifier: $0).minimalIdentifier == Locale.Language(identifier: target).minimalIdentifier } == true
    }

    var body: some View {
        Group {
            if onboarding.isPresented {
                OnboardingView(model: onboarding, app: app, showMembership: { membershipFromOnboarding = true; showingMembership = true })
            } else {
                HomeView(model: app, showOnboarding: { onboarding.restart(settings: app.settings) },
                         showMembership: { membershipFromOnboarding = false; showingMembership = true })
                    .safeAreaInset(edge: .bottom) {
                        if pendingCurrentLanguage {
                            Button {
                                onboarding.state.step = .language
                                onboarding.isPresented = true
                            } label: {
                                Label(app.text("语言包尚未就绪，下载完成后才会显示译文。点击查看。"), systemImage: "arrow.down.circle")
                                    .font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
                                    .padding(.horizontal, 16)
                            }.background(Palette.surface)
                                .accessibilityIdentifier("onboarding.pendingDownload")
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showingMembership, onDismiss: {
            if membershipFromOnboarding && onboarding.isPresented && onboarding.state.step == .language {
                onboarding.state.step = .enable
            }
        }) {
            MembershipView(store: membership, locale: membershipFromOnboarding ? onboarding.locale :
                           (app.settings.audience.isEnglishOnly ? .english : (app.settings.script == .traditional ? .traditional : .simplified)),
                           onboarding: membershipFromOnboarding)
        }
        .onOpenURL { url in
            if url.scheme == "typetolearn", url.host == "subscribe" { membershipFromOnboarding = false; showingMembership = true }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await membership.refreshEntitlements()
        }
        // Keep the translation session's anchor alive across every onboarding page.
        .translationTask(onboarding.configuration, action: onboarding.prepare)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await onboarding.refreshSelectedStatus()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if onboarding.hasPendingDownload || onboarding.downloadStatus == .checking {
                    await onboarding.refreshSelectedStatus()
                }
            }
        }
    }
}
