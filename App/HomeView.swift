import KeyboardCore
import SwiftUI
import Translation

struct HomeView: View {
    @ObservedObject var model: AppModel
    var showOnboarding: () -> Void
    var showMembership: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var testText = ""
    @State private var search = ""
    @State private var englishSearch = ""
    @State private var privacySettingsError = false

    private var isEnglishOnly: Bool { model.settings.audience.isEnglishOnly }
    private func text(_ value: String) -> String { model.text(value) }
    private var primaryLanguage: LearningLanguage? {
        isEnglishOnly ? model.selectedEnglishLanguage : model.selectedLanguage
    }
    private var primaryLanguageID: String {
        isEnglishOnly ? model.settings.englishTargetLanguageID : model.settings.targetLanguageID
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    KeyboardPreview(settings: model.settings, targetID: primaryLanguageID,
                                    locale: isEnglishOnly ? .english : (model.settings.script == .traditional ? .traditional : .simplified),
                                    identifier: "home.preview", allowsEnglishSwitch: true)
                        .listRowInsets(EdgeInsets())
                }.listRowBackground(Color.clear)


                learningLanguageSection
                inputSettingsSection
                keyFeedbackSection

                if !isEnglishOnly {
                    Section("个人词库") {
                        NavigationLink { learnedWordsView } label: {
                            Label("查看已记住的词组", systemImage: "text.book.closed")
                        }.accessibilityIdentifier("settings.learnedWords")
                        Text("分段选字完成词组后，下次输入相同编码会优先显示组合。只保存在本机，可随时删除。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(action: showOnboarding) { Label(text("新手引导"), systemImage: "sparkles") }
                        .accessibilityIdentifier("settings.onboarding")
                    NavigationLink { setupView } label: { Label(text("启用伴语输入法"), systemImage: "keyboard") }
                    NavigationLink { privacyView } label: { Label(text("隐私与剪贴板"), systemImage: "hand.raised") }
                        .accessibilityIdentifier("settings.privacy")
                    NavigationLink { noticesView } label: { Label(text("词库来源与许可"), systemImage: "doc.text") }
                }

                Section(text("试着输入")) {
                    TextEditor(text: $testText)
                        .frame(minHeight: 112)
                        .accessibilityLabel(text("键盘测试输入框"))
                        .accessibilityIdentifier("keyboard.test.editor")
                    Text(text("点击输入框，长按地球键切换到伴语输入法。试试 nihao、九宫格 64426，或仓颉「日」键。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Section {
                        Text("\(text("版本")) \(version)")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("home.version")
                    }.listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .navigationTitle(text("伴语输入法"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    BrandTitle(title: text("伴语输入法"))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: showMembership) {
                        Image(systemName: "crown.fill").frame(width: 44, height: 44)
                    }.accessibilityLabel(isEnglishOnly ? "Membership" : "会员订阅")
                        .accessibilityIdentifier("membership.open")
                }
            }
            .task(id: model.settings.script.rawValue + model.settings.audience.rawValue) { await model.loadLanguages() }
            .onChange(of: model.settings) { old, new in
                model.save()
                if old.audience != new.audience {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
                if old.targetLanguageID != new.targetLanguageID || old.script != new.script || old.audience != new.audience {
                    model.preparationStatus = nil
                }
                if old.englishTargetLanguageID != new.englishTargetLanguageID || old.audience != new.audience {
                    model.englishPreparationStatus = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.loadLearnedWords()
                    Task { await model.loadLanguages() }
                }
            }
            .translationTask(model.preparation, action: model.prepare)
        }
        .environment(\.locale, Locale(identifier: model.settings.audience.interfaceLocale))
    }

    private var learningLanguageSection: some View {
        Section {
            Toggle(text("显示候选译文"), isOn: $model.settings.translationEnabled)
            Toggle(text("候选译文过长时换行"), isOn: $model.settings.wrapCandidateTranslations)
            NavigationLink {
                if isEnglishOnly { englishLanguageList }
                else { languageList }
            } label: {
                LabeledContent(text("翻译成")) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(primaryLanguage?.name ?? languageName(primaryLanguageID))
                        Text(text(model.isLoading ? "正在检查" : (primaryLanguage?.installed == true ? "已下载" : "待下载")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.accessibilityIdentifier("settings.learningLanguage")
            Button {
                if isEnglishOnly { model.prepareEnglishLanguage() }
                else { model.prepareLanguage() }
            } label: {
                HStack {
                    Label(text(primaryLanguage?.installed == true ? "检查语言资源" : "下载离线语言"), systemImage: "arrow.down.circle")
                    Spacer()
                    if model.preparing { ProgressView() }
                }.frame(minHeight: 32)
            }
            .disabled(model.preparing || primaryLanguage == nil)
            .accessibilityIdentifier("language.prepare")
            if let message = isEnglishOnly ? model.englishPreparationStatus : model.preparationStatus {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("language.preparation.status")
            }
        } header: {
            Text(text("学习语言"))
        } footer: {
            Text(text("语言由当前设备的系统翻译提供。请先下载资源；键盘会先显示中文，再补上译文。"))
        }
        .disabled(model.preparing)
    }

    private var inputSettingsSection: some View {
        Section {
            Picker(text("默认键盘用户"), selection: $model.settings.audience) {
                ForEach(KeyboardAudience.allCases) { audience in
                    Text(text(audience.title)).tag(audience)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("audience.picker")
            Text(text("中文用户可切换中英文，并分别选择学习语言。"))
                .font(.footnote).foregroundStyle(.secondary)

            if !isEnglishOnly {
                Picker("键盘形式", selection: $model.settings.layout) {
                    ForEach(KeyboardLayout.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("settings.chineseLayout")
                Toggle(isOn: $model.settings.fuzzyPinyinEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("模糊音")
                        Text("拼音双向匹配平翘舌、前后鼻音、n/l 和 f/h。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings.fuzzyPinyin")
                Picker("候选字体", selection: $model.settings.script) {
                    ForEach(ChineseScript.allCases) { Text($0.title).tag($0) }
                }
                NavigationLink { englishLanguageList } label: {
                    LabeledContent("英文候选译成") {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(model.selectedEnglishLanguage?.name ?? languageName(model.settings.englishTargetLanguageID))
                            Text(model.isLoading ? self.text("正在检查") : (model.selectedEnglishLanguage?.installed == true ? self.text("已下载") : self.text("待下载")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityIdentifier("settings.englishLearningLanguage")
                Button { model.prepareEnglishLanguage() } label: {
                    HStack {
                        Label(model.selectedEnglishLanguage?.installed == true ? "检查英文译文资源" : "下载英文译文资源",
                              systemImage: "arrow.down.circle")
                        Spacer()
                        if model.preparing { ProgressView() }
                    }.frame(minHeight: 32)
                }
                .disabled(model.preparing || model.selectedEnglishLanguage == nil)
                .accessibilityIdentifier("english.language.prepare")
                if let message = model.englishPreparationStatus {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("english.language.preparation.status")
                }
            }
        } header: {
            Text(text("输入设置"))
        }
        .disabled(model.preparing)
    }

    private var keyFeedbackSection: some View {
        Section {
            Toggle(text("按键声"), isOn: $model.settings.keySoundEnabled)
                .accessibilityIdentifier("settings.keySound")
            if model.settings.keySoundEnabled {
                Picker(text("按键声音效"), selection: $model.settings.keySoundStyle) {
                    ForEach(KeyboardSoundStyle.allCases) { style in
                        Text(text(style.title)).tag(style)
                    }
                }
                .accessibilityIdentifier("settings.keySoundStyle")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(text("按键声音量"))
                        Spacer()
                        Text("\(Int((model.settings.keySoundVolume * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.settings.keySoundVolume, in: 0...1, step: 0.05)
                        .accessibilityIdentifier("settings.keySoundVolume")
                }
            }
            Toggle(text("按键震动"), isOn: $model.settings.keyHapticsEnabled)
                .accessibilityIdentifier("settings.keyHaptics")
            if model.settings.keyHapticsEnabled {
                Picker(text("震动强度"), selection: $model.settings.keyHapticStrength) {
                    ForEach(KeyboardHapticStrength.allCases) { strength in
                        Text(text(strength.title)).tag(strength)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.keyHapticStrength")
            }
        } header: {
            Text(text("按键反馈"))
        } footer: {
            if model.settings.keySoundEnabled {
                if model.settings.keySoundStyle == .system {
                    Text(text("仿系统音效由伴语生成，不依赖 iPhone 的键盘反馈开关。"))
                } else {
                    Text(text("自定义按键声在静音模式下也会播放；音量同时受媒体音量影响。"))
                }
            }
        }
    }

    private var languageList: some View {
        List {
            if model.isLoading { HStack { ProgressView(); Text(self.text("正在读取系统支持的语言…")) } }
            if let error = model.languageError {
                Text(error).foregroundStyle(.secondary)
                Button(self.text("重新读取")) { Task { await model.loadLanguages() } }
            }
            ForEach(model.languages.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.nativeName.localizedCaseInsensitiveContains(search) }) { language in
                Button {
                    model.settings.targetLanguageID = language.id
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(language.name).foregroundStyle(.primary)
                            Text(language.nativeName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(language.installed ? self.text("已下载") : self.text("待下载")).font(.caption).foregroundStyle(.secondary)
                        if language.id == model.settings.targetLanguageID {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                        }
                    }.frame(minHeight: 44)
                }
                .accessibilityAddTraits(language.id == model.settings.targetLanguageID ? .isSelected : [])
            }
        }
        .navigationTitle(self.text("选择学习语言"))
        .searchable(text: $search, prompt: self.text("搜索语言"))
        .disabled(model.preparing)
    }

    private var learnedWordsView: some View {
        List {
            if model.learnedWords.items.isEmpty {
                ContentUnavailableView("还没有记住的词组", systemImage: "text.book.closed",
                                       description: Text("例如输入 dise，依次选择「底」和「色」，下次就会优先出现「底色」。"))
            }
            ForEach(model.learnedWords.items) { word in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(word.text).font(.body)
                        Text("\(word.code) · \(word.layout.shortTitle) · \(word.script.title)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { model.deleteLearnedWord(word.id) } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("删除\(word.text)")
                }
            }
        }
        .navigationTitle("我的词组")
        .onAppear { model.loadLearnedWords() }
    }

    private var englishLanguageList: some View {
        List {
            if model.isLoading { HStack { ProgressView(); Text(self.text("正在读取系统支持的语言…")) } }
            if let error = model.languageError, model.englishLanguages.isEmpty {
                Text(error).foregroundStyle(.secondary)
                Button(text("重新读取")) { Task { await model.loadLanguages() } }
            }
            ForEach(model.englishLanguages.filter {
                englishSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(englishSearch) ||
                $0.nativeName.localizedCaseInsensitiveContains(englishSearch)
            }) { language in
                Button { model.settings.englishTargetLanguageID = language.id } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(language.name).foregroundStyle(.primary)
                            Text(language.nativeName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(language.installed ? self.text("已下载") : self.text("待下载")).font(.caption).foregroundStyle(.secondary)
                        if language.id == model.settings.englishTargetLanguageID {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                        }
                    }.frame(minHeight: 44)
                }
                .accessibilityIdentifier("english.language.\(language.id)")
                .accessibilityAddTraits(language.id == model.settings.englishTargetLanguageID ? .isSelected : [])
            }
        }
        .navigationTitle(self.text("英文候选译文"))
        .searchable(text: $englishSearch, prompt: self.text("搜索语言"))
        .disabled(model.preparing)
    }

    private var setupView: some View {
        List {
            Section(self.text("首次设置")) {
                Label(self.text("打开系统设置 → 通用 → 键盘 → 键盘"), systemImage: "1.circle")
                Label(self.text("添加新键盘 → 伴语输入法"), systemImage: "2.circle")
                FullAccessSetupStep(locale: isEnglishOnly ? .english : (model.settings.script == .traditional ? .traditional : .simplified))
                Label(self.text("返回输入框，长按地球键选择伴语输入法"), systemImage: "4.circle")
                Button(self.text("打开应用设置")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Section(self.text("使用方式")) {
                Text(self.text("点击候选词输入中文；长按候选词，选择输入外语。"))
                Text(self.text("键盘右上角点按键盘图标，可依次切换全拼、九宫格和仓颉五代。候选栏可左右连续滑动，查看更多候选。"))
                Text(self.text("拼音支持整句和简拼混输，例如 nihao、nhao、nh 都可以输入你好。九宫格按拼音对应数字输入，例如你好是 64426。长句可以整句选中，也可以分段选词，剩余编码会保留。"))
                Text(self.text("实时翻译和剪贴板功能需要开启「允许完全访问」。未开启时仍可进行基本输入。"))
            }
        }.navigationTitle(self.text("启用键盘"))
    }

    private var privacyView: some View {
        List {
            Section {
                Text(self.text("在应用设置中，将「从其他 App 粘贴」设为「允许」，减少重复询问。"))
                    .accessibilityIdentifier("privacy.pastePermission")
                Text(self.text("剪贴板还需在「键盘」中开启「允许完全访问」；基本输入无需开启。"))
                    .accessibilityIdentifier("privacy.fullAccess")
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else {
                        privacySettingsError = true
                        return
                    }
                    openURL(url) { privacySettingsError = !$0 }
                } label: {
                    Label(self.text("打开应用设置"), systemImage: "gearshape")
                        .frame(minHeight: 32)
                }
                .accessibilityIdentifier("privacy.openSettings")
                if privacySettingsError {
                    Text(self.text("请手动打开系统设置 → App → 伴语输入法。"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("privacy.settingsError")
                }
            } header: {
                Text(self.text("剪贴板权限"))
            } footer: {
                Text(self.text("若无粘贴选项，先复制其他 App 的文字，在键盘点剪贴板后再返回设置。"))
                    .accessibilityIdentifier("privacy.permissionHint")
            }
            Section(self.text("输入隐私")) {
                Text(self.text("不记录输入历史。中文候选在本机生成，译文由 Apple 系统翻译处理。"))
                    .accessibilityIdentifier("privacy.typing")
                Text(self.text("个人词库及其译文仅存本机，可随时删除。"))
            }
            Section(self.text("剪贴板与收藏")) {
                Text(self.text("点击才读取，不后台监控。关闭面板或键盘后清除未收藏的预览。"))
                Text(self.text("收藏仅存本机，可删除或清空；最多 30 条，每条 2,000 字。"))
                    .accessibilityIdentifier("privacy.clips")
            }
        }.navigationTitle(self.text("隐私与剪贴板"))
    }

    private var noticesView: some View {
        ScrollView {
            Text(notices)
                .font(.footnote).textSelection(.enabled).padding(20)
        }.navigationTitle(self.text("词库来源与许可"))
    }

    private var notices: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return self.text("许可文件未找到。") }
        guard let extensionResources = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("LearnKeyboardExtension.appex", isDirectory: true),
              let extra = try? String(contentsOf: extensionResources.appendingPathComponent("IOS-LEXICON-NOTICE.txt"),
                                      encoding: .utf8) else { return text }
        return text + "\n\n" + extra
    }

    private func languageName(_ id: String) -> String {
        Locale(identifier: model.settings.audience.interfaceLocale).localizedString(forIdentifier: id) ?? id
    }
}
