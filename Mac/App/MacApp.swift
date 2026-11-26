import SwiftUI
import DesktopCore
import KeyboardCore

@main
struct MacApp: App {
    @StateObject private var model = MacAppModel()
    var body: some Scene {
        WindowGroup("伴语输入法 · Mac") {
            MacSettingsView(model: model).tint(MacPalette.accent)
                .frame(minWidth: 640, minHeight: 700)
        }.defaultSize(width: 720, height: 800)
    }
}

struct MacSettingsView: View {
    @ObservedObject var model: MacAppModel
    var body: some View {
        Form {
            Section {
                Text("伴语输入法").font(.largeTitle.bold())
                Text("打字，也在学习另一种语言。").foregroundStyle(.secondary)
                HStack {
                    Button(model.installed ? "更新输入法组件" : "安装输入法") { model.installInputMethod() }
                    Button("打开键盘设置") { model.openKeyboardSettings() }
                }
                Text("安装后，在系统设置 → 键盘 → 文本输入 → 编辑中添加「伴语」。首次安装可能需要注销并重新登录。").font(.callout)
            }
            Section("输入") {
                Picker("候选窗口", selection: setting(\.candidateLayout)) {
                    ForEach(DesktopCandidateStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("英文输入", isOn: setting(\.english))
                Picker("中文输入方式", selection: setting(\.layout)) {
                    Text("全拼").tag(KeyboardLayout.pinyin)
                    Text("仓颉五代").tag(KeyboardLayout.cangjie)
                }.disabled(model.settings.english)
                Picker("中文字体", selection: setting(\.script)) {
                    ForEach(ChineseScript.allCases) { Text($0.title).tag($0) }
                }
                Text("单击或空格选词 · 数字键选当前页候选 · Shift + 数字输入对应译文 · + / − 展开后翻页 · Tab 切换分类 · 左右键修改拼写 · Shift + 空格拆字 · Esc 先收起，再取消").font(.callout).foregroundStyle(.secondary)
            }
            fuzzyPinyinSection
            Section("候选翻译") {
                Toggle("显示候选译文", isOn: setting(\.translationEnabled))
                Picker("翻译来源", selection: setting(\.provider)) {
                    ForEach(DesktopTranslationProvider.allCases) { Text($0.title).tag($0) }
                }
                Picker("目标语言", selection: Binding(get: { model.selectedLanguage }, set: { model.selectedLanguage = $0; model.save() })) {
                    if !model.languages.contains(where: { $0.id == model.selectedLanguage }) {
                        Text(model.selectedLanguage).tag(model.selectedLanguage)
                    }
                    ForEach(model.languages) { language in
                        Text(language.name + (language.installed ? " · 已下载" : "")).tag(language.id)
                    }
                }
                if model.settings.provider == .apple {
                    Text("使用本机语言资源，翻译文字在这台 Mac 上处理。首次使用需下载源语言和目标语言。").font(.callout)
                    Text(model.localLanguageStatus).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("下载并验证语言") { model.prepareLanguages() }.disabled(model.busy)
                        Button("系统语言设置") { model.openLanguageSettings() }
                    }
                } else {
                    Picker("模型", selection: setting(\.cloudModel)) {
                        ForEach(SiliconFlowModel.allCases) { Text($0.title).tag($0) }
                    }
                    Text("启用后，当前可见候选文字会发送至硅基流动进行翻译，费用由你的硅基流动账户承担。不会发送输入框全文。").font(.callout)
                    Toggle("允许将候选文字发送至硅基流动", isOn: setting(\.cloudConsent))
                    SecureField(model.hasKey ? "已保存 Key；填写可替换" : "输入你的 API Key", text: $model.apiKey)
                    HStack {
                        Button("保存到钥匙串") { model.saveKey() }.disabled(model.apiKey.isEmpty)
                        Button("删除 Key", role: .destructive) { model.removeKey() }.disabled(!model.hasKey)
                        Text(model.hasKey ? "已保存" : "尚未保存").foregroundStyle(.secondary)
                    }
                }
            }
            Section("检查翻译") {
                TextField("测试文字", text: $model.sample)
                HStack {
                    Button(model.settings.provider == .apple ? "测试本机翻译" : "测试 API 连接与翻译") { model.testTranslation() }.disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small); Button("取消") { model.save() } }
                }
                if !model.translation.isEmpty { Text(model.translation).font(.title3).textSelection(.enabled) }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            Section("试打区") {
                Text("切换到「伴语」输入法后在这里打字。").foregroundStyle(.secondary)
                TextEditor(text: $model.testText).frame(height: 100).font(.title3)
            }
            Section("词库与许可") {
                Text("Mac 版使用雾凇拼音数据，已转换为伴语的简繁体拼音词库，同时保留基础词汇、英文补全和仓颉码表。")
                    .font(.callout)
                Link("雾凇拼音 · iDvel 与贡献者", destination: URL(string: "https://github.com/iDvel/rime-ice")!)
                Link("雾凇词库许可（GPL-3.0-only）", destination: URL(string: "https://github.com/iDvel/rime-ice/blob/927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6/LICENSE")!)
                if let notice = Bundle.main.resourceURL?.appendingPathComponent(
                    "InputMethods/TypeToLearnInputMethod.app/Contents/Resources/DictionaryResources/TATOEBA-NOTICE.txt"
                ), FileManager.default.fileExists(atPath: notice.path) {
                    Text("Tatoeba 普通话语料用于调整已有词条的词频。")
                        .font(.callout)
                    Link("Tatoeba · 语料与贡献者", destination: URL(string: "https://tatoeba.org/en/downloads")!)
                    Link("Tatoeba 语料许可（CC BY 2.0 FR）", destination: URL(string: "https://creativecommons.org/licenses/by/2.0/fr/")!)
                }
            }
        }.formStyle(.grouped)
            .task { model.refreshKeyStatus(); await model.loadLanguages() }
            .task(id: "\(model.settings.provider)-\(model.settings.sourceLanguage)-\(model.settings.destinationLanguage)") { await model.loadLanguages() }
            .translationTask(model.configuration, action: model.prepare)
    }
    private func setting<T>(_ path: WritableKeyPath<DesktopSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { model.settings[keyPath: path] = $0; model.save() })
    }
    private var fuzzyPinyinSection: some View {
        Section("模糊音") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                Toggle("z / zh", isOn: fuzzyPinyin(.zZh))
                Toggle("c / ch", isOn: fuzzyPinyin(.cCh))
                Toggle("s / sh", isOn: fuzzyPinyin(.sSh))
                Toggle("n / l", isOn: fuzzyPinyin(.nL))
                Toggle("f / h", isOn: fuzzyPinyin(.fH))
                Toggle("an / ang", isOn: fuzzyPinyin(.anAng))
                Toggle("en / eng", isOn: fuzzyPinyin(.enEng))
                Toggle("in / ing", isOn: fuzzyPinyin(.inIng))
            }.toggleStyle(.checkbox)
            Button("全部关闭") {
                model.settings.fuzzyPinyinOptions = []
                model.save()
            }.disabled(model.settings.fuzzyPinyinOptions.isEmpty)
            Text("仅用于中文拼音，所选音组双向匹配。an / ang 也包含 ian / iang、uan / uang。设置于下一次开始输入时生效。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func fuzzyPinyin(_ option: PinyinFuzzyOptions) -> Binding<Bool> {
        Binding(get: { model.settings.fuzzyPinyinOptions.contains(option) }, set: { enabled in
            var options = model.settings.fuzzyPinyinOptions
            if enabled { options.insert(option) } else { options.remove(option) }
            model.settings.fuzzyPinyinOptions = options
            model.save()
        })
    }
}
