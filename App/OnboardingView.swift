import KeyboardCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var app: AppModel
    var showMembership: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var search = ""
    @State private var settingsError = false

    private func t(_ s: String, _ h: String, _ e: String) -> String { model.t(s, h, e) }
    private var isLanguage: Bool { model.state.step == .language }
    private var stepTitle: String {
        switch model.state.step {
        case .audience: t("选择输入方式", "選擇輸入方式", "Your keyboard")
        case .language: t("选择学习语言", "選擇學習語言", "Your learning language")
        case .enable: t("启用键盘", "啟用鍵盤", "Enable your keyboard")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if model.state.step != .audience {
                    Button { model.state.step = isLanguage ? .audience : .language } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel(t("上一步", "上一步", "Back"))
                        .accessibilityIdentifier("onboarding.back")
                        .disabled(model.isRequesting)
                } else { Image(systemName: "character.bubble").frame(width: 44, height: 44).foregroundStyle(Palette.accent) }
                Text("TypeToLearn").font(.headline)
                Spacer()
                Text("\(model.state.step.rawValue + 1) / 3")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel(stepTitle)
                    .accessibilityIdentifier("onboarding.step")
            }.padding(.horizontal, 16)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heading.id("heading")
                        switch model.state.step {
                        case .audience: audienceChoices
                        case .language: languageChoices(reader: reader)
                        case .enable: enableInstructions
                        }
                        if model.state.step != .language, let message = model.message {
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("onboarding.message")
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.state.step) { _, _ in reader.scrollTo("heading", anchor: .top) }
            }
            footer
        }
        .background(Palette.background)
        .environment(\.locale, Locale(identifier: model.locale.rawValue))
        .task(id: "\(model.state.audience?.rawValue ?? "unselected")|\(model.state.sourceID)") { await model.loadLanguages() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(stepTitle.uppercased()).font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Palette.accent)
            Text(headline).font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        switch model.state.step {
        case .audience: t("从你习惯的\n输入开始。", "從你習慣的\n輸入開始。", "Start with the way\nyou type.")
        case .language: t("照常打字，\n多懂一种语言。", "照常打字，\n多懂一種語言。", "Type naturally.\nLearn another language.")
        case .enable: t("最后一步，\n让键盘陪你表达。", "最後一步，\n讓鍵盤陪你表達。", "One last step.\nMake it your keyboard.")
        }
    }

    private var subtitle: String {
        switch model.state.step {
        case .audience: t("选择你的日常输入方式，以后也能在设置中调整。", "選擇你的日常輸入方式，以後也能在設定中調整。", "Choose your everyday keyboard. You can change this later in Settings.")
        case .language: t("点击语言即可预览，下载语言包后，会员可在键盘查看真实译文。", "點擊語言即可預覽，下載語言包後，會員可在鍵盤查看真實譯文。", "Tap a language to preview it. Learning translations require membership and a downloaded language pack.")
        case .enable: t("前往系统设置添加伴语输入法，再回到任意输入框试试。", "前往系統設定加入伴語輸入法，再回到任意輸入框試試。", "Add TypeToLearn in Settings, then try it in any text field.")
        }
    }

    private var audienceChoices: some View {
        VStack(spacing: 16) {
            audienceCard(.chinese, symbol: "character.zh", title: t("中文键盘用户", "中文鍵盤使用者", "Chinese keyboard user"),
                         detail: t("拼音、九宫格或仓颉，可随时切换英文。", "拼音、九宮格或倉頡，可隨時切換英文。", "Pinyin, nine-key or Cangjie, with English switching."))
            audienceCard(.english, symbol: "keyboard", title: t("英文键盘用户", "英文鍵盤使用者", "English keyboard user"),
                         detail: t("英文输入与联想，搭配你选择的学习语言。", "英文輸入與聯想，搭配你選擇的學習語言。", "English typing and suggestions, paired with your learning language."))
        }
    }

    private func audienceCard(_ audience: KeyboardAudience, symbol: String, title: String, detail: String) -> some View {
        let selected = model.state.audience == audience
        return Button { model.chooseAudience(audience) } label: {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: symbol).font(.title2).frame(width: 36, height: 36).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Palette.accent : Palette.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(selected ? Palette.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("onboarding.audience.\(audience.rawValue)")
    }

    private func languageChoices(reader: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyboardPreview(settings: previewSettings, targetID: model.state.targetLanguageID,
                            locale: model.locale, revision: model.previewRevision,
                            showcaseLanguageIDs: model.languages.map(\.id).filter { KeyboardDemo.translation(0, language: $0) != nil })
                .id("preview")
            if model.state.targetLanguageID != nil { downloadNotice }
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.message")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(t("搜索语言", "搜尋語言", "Search languages"), text: $search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("onboarding.language.search")
            }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            if model.loading {
                ProgressView(t("正在读取系统支持的语言…", "正在讀取系統支援的語言…", "Checking available languages…")).frame(minHeight: 44)
            } else if model.languageLoadFailed {
                Text(t("暂时无法读取语言，请重试。", "暫時無法讀取語言，請重試。", "Could not load languages. Please try again."))
                Button(t("重新读取", "重新讀取", "Try again")) { Task { await model.loadLanguages() } }.frame(minHeight: 44)
            }
            LazyVStack(spacing: 6) {
                ForEach(model.languages.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.nativeName.localizedCaseInsensitiveContains(search) }) { language in
                    languageRow(language, reader: reader)
                }
            }
        }
    }

    private var previewSettings: KeyboardSettings {
        var settings = app.settings
        settings.audience = model.state.audience ?? .chinese
        settings.script = model.state.script
        settings.translationEnabled = true
        return settings
    }

    private func languageRow(_ language: LearningLanguage, reader: ScrollViewProxy) -> some View {
        let selected = model.state.targetLanguageID == language.id
        let pending = model.state.requestedPairs.contains("\(model.state.sourceID)>\(language.id)") && !language.installed
        return HStack(spacing: 4) {
            Button {
                model.selectLanguage(language)
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                reader.scrollTo("preview", anchor: .top)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        HStack(spacing: 4) {
                            Text(language.nativeName).lineLimit(1)
                            if language.installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                            else if pending { Image(systemName: "arrow.down.circle") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("onboarding.language.\(language.id)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button {
                model.requestDownload(language)
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            } label: {
                Image(systemName: language.installed ? "checkmark" : (pending ? "arrow.clockwise" : "arrow.down"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Palette.accent, in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(language.installed ? t("使用", "使用", "Use") : (pending ? t("检查下载", "檢查下載", "Check download") : t("下载", "下載", "Download")))
            .accessibilityIdentifier("onboarding.download.\(language.id)")
        }
        .buttonStyle(.plain).disabled(model.isRequesting)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Palette.accent : .clear, lineWidth: 1.5))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var downloadNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.downloadStatus == .checking || model.isRequesting || model.downloadStatus == .downloading { ProgressView() }
                else { Image(systemName: model.downloadStatus == .ready ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(Palette.accent) }
                Text(downloadTitle).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("onboarding.download.status")
            }
            Text(model.downloadStatus == .ready
                 ? t("语言包已就绪，开通会员后即可显示学习译文。", "語言包已就緒，開通會員後即可顯示學習譯文。", "The language pack is ready. Active membership unlocks learning translations.")
                 : t("下载完成后才能显示这个学习语言的译文，基础打字不受影响。确认下载后，系统会在后台继续下载，你可以先去设置键盘。", "下載完成後才能顯示這個學習語言的譯文，基本打字不受影響。確認下載後，系統會在背景繼續下載，你可以先去設定鍵盤。", "Translations need the completed language pack. Basic typing still works. After you approve the download, the system can continue in the background while you set up the keyboard."))
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var downloadTitle: String {
        let name = model.state.targetLanguageID.map(model.languageName) ?? ""
        switch model.downloadStatus {
        case .ready: return "\(name) · " + t("已就绪", "已就緒", "Ready")
        case .checking: return t("正在检查语言包…", "正在檢查語言包…", "Checking language pack…")
        case .requesting: return t("请在系统提示中确认下载", "請在系統提示中確認下載", "Approve the download in the system prompt")
        case .downloading: return "\(name) · " + t("下载中", "下載中", "Downloading")
        case .failed: return t("下载需要重试", "下載需要重試", "Download needs attention")
        case .idle: return "\(name) · " + t("等待下载", "等待下載", "Download needed")
        }
    }

    private var enableInstructions: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                instruction(1, t("打开系统「设置」", "開啟系統「設定」", "Open Settings"),
                            t("通用 → 键盘 → 键盘 → 添加新键盘", "一般 → 鍵盤 → 鍵盤 → 新增鍵盤", "General → Keyboard → Keyboards → Add New Keyboard"))
                instruction(2, t("添加「伴语输入法」", "加入「伴语输入法」", "Add “伴语输入法” (TypeToLearn)"),
                            t("如果打开的是 App 设置，点击其中的「键盘」并开启。", "如果開啟的是 App 設定，點擊其中的「鍵盤」並啟用。", "If the app's Settings page opens, tap Keyboards and enable it there."))
                FullAccessSetupStep(locale: model.locale)
                instruction(4, t("长按地球键切换", "長按地球鍵切換", "Hold the globe key to switch"),
                            t("回到任意输入框，选择伴语输入法。", "回到任意輸入框，選擇伴語輸入法。", "Return to a text field and choose TypeToLearn."))
            }.padding(20).background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url) { settingsError = !$0 }
            } label: {
                Label(t("前往系统设置", "前往系統設定", "Open Settings"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding.openSettings")
            if settingsError {
                Text(t("请手动打开系统设置，并按照上面的步骤添加键盘。", "請手動開啟系統設定，並依照上方步驟加入鍵盤。", "Open Settings manually and follow the steps above."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func instruction(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                .frame(width: 28, height: 28).background(Palette.accent.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                switch model.state.step {
                case .audience: model.state.step = .language
                case .language:
                    guard model.saveSelection(to: app) else { return }
                    showMembership()
                case .enable: model.finish(app: app)
                }
            } label: {
                Text(model.state.step == .enable ? t("我已设置，开始使用", "我已設定，開始使用", "I've set it up — start typing") : (isLanguage ? t("下一步：解锁学习", "下一步：解鎖學習", "Next: unlock learning") : t("继续", "繼續", "Continue")))
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.state.step == .audience ? model.state.audience == nil : (isLanguage && (!model.canContinue || model.isRequesting)))
            .accessibilityIdentifier("onboarding.next")
            HStack(spacing: 6) {
                ForEach(OnboardingState.Step.allCases, id: \.rawValue) { step in
                    Capsule().fill(step == model.state.step ? Palette.accent : Palette.secondary.opacity(0.25)).frame(width: step == model.state.step ? 24 : 8, height: 5)
                }
            }.accessibilityHidden(true)
        }
        .frame(maxWidth: 620).padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity).background(Palette.background)
    }
}

/// Shared by onboarding and the home screen's keyboard setup instructions.
struct FullAccessSetupStep: View {
    let locale: OnboardingLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demoEnabled = false

    private func t(_ s: String, _ h: String, _ e: String) -> String { locale.text(s, h, e) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Text("3").font(.subheadline.weight(.bold)).foregroundStyle(Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(Palette.accent.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("允许完全访问", "允許完整取用", "Allow Full Access"))
                        .font(.headline).foregroundStyle(Palette.accent)
                        .accessibilityIdentifier("setup.fullAccess.title")
                    Text(t("必须开启，否则实时翻译无法生效。", "必須開啟，否則即時翻譯無法生效。", "Required for real-time translation. It won't work while this is off."))
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("setup.fullAccess.requirement")
                }
            }
            Text(t("在系统「键盘」列表中点进「伴语输入法」，开启「允许完全访问」，并在弹窗中点「允许」。", "在系統「鍵盤」列表中點進「伴語輸入法」，開啟「允許完整取用」，並在彈出視窗中點「允許」。", "In the system Keyboards list, tap TypeToLearn, turn on Allow Full Access, then tap Allow in the alert."))
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text(t("允许完全访问", "允許完整取用", "Allow Full Access"))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                Capsule()
                    .fill(demoEnabled ? Palette.accent : Palette.secondary.opacity(0.35))
                    .frame(width: 51, height: 31)
                    .overlay(alignment: demoEnabled ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 27, height: 27).padding(2)
                    }
            }
            .padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(t("开关示意：请在系统设置中开启允许完全访问", "開關示意：請在系統設定中開啟允許完整取用", "Switch illustration: enable Allow Full Access in system Settings"))
            .accessibilityIdentifier("setup.fullAccess.demo")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.accent.opacity(0.4), lineWidth: 1) }
        .task(id: reduceMotion) {
            demoEnabled = reduceMotion
            guard !reduceMotion else { return }
            // A single off-to-on demonstration, with no repeating motion.
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { demoEnabled = true }
        }
    }
}
