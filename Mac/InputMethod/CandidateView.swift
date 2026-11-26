import AppKit
import SwiftUI
import KeyboardCore
import DesktopCore

/// Native text measurement keeps translations within two lines without truncation.
@MainActor
enum CandidateMetrics {
    static let candidateFont = NSFont.systemFont(ofSize: 16, weight: .regular)
    static let translationSize: CGFloat = 12
    /// Reserve room for at least four real candidates before fitting translations.
    /// The final page can contain fewer when the lexicon has no more results.
    static func maximumCellWidth(availableWidth: CGFloat, candidateCount: Int) -> CGFloat {
        floor(availableWidth / CGFloat(max(1, min(4, candidateCount)))) - 2
    }
    static func expandedColumns(_ candidates: [Candidate], translations: [String: String], maximum: CGFloat) -> [CGFloat] {
        var columns = Array(repeating: CGFloat(58), count: 4)
        for (index, candidate) in candidates.enumerated() {
            columns[index % 4] = max(columns[index % 4], width(candidate, translation: translations[candidate.text], maximum: maximum))
        }
        return columns
    }
    static func isSingleWord(_ text: String) -> Bool {
        !text.isEmpty && text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
    static func height(_ text: String, width: CGFloat, size: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return ceil((text as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: style]).height)
    }
    static func twoLines(size: CGFloat) -> CGFloat {
        ceil(NSFont.systemFont(ofSize: size).ascender - NSFont.systemFont(ofSize: size).descender + NSFont.systemFont(ofSize: size).leading) * 2 + 1
    }
    static func width(_ candidate: Candidate, translation: String?, maximum: CGFloat) -> CGFloat {
        let original = (candidate.text as NSString).size(withAttributes: [.font: candidateFont]).width
        var width = min(maximum, max(58, ceil(original) + 34))
        if let translation, !translation.isEmpty {
            if isSingleWord(translation) {
                let natural = (translation as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: translationSize)]).width
                return min(maximum, max(width, ceil(natural) + 30))
            }
            // Grow within the four-candidate budget; never let one translation take the whole bar.
            while width < maximum, height(translation, width: width - 28, size: translationSize) > twoLines(size: translationSize) {
                width = min(maximum, width + 12)
            }
        }
        return width
    }
    static func fittedTranslationSize(_ text: String, width: CGFloat) -> CGFloat {
        var size = translationSize
        if isSingleWord(text) {
            while size > 1, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width > width { size -= 0.5 }
            return size
        }
        // Fit the complete text within the candidate's allotted two lines.
        while size > 1, height(text, width: width, size: size) > twoLines(size: size) { size -= 0.5 }
        return size
    }
}

struct CandidateView: View {
    var input: String
    let values: [Candidate]
    let translations: [String: String]
    let selected: Int
    let status: String
    let translationEnabled: Bool
    let style: DesktopCandidateStyle
    let maximumCellWidth: CGFloat
    let canPrevious: Bool
    let canNext: Bool
    let highlight: (Int) -> Void
    let choose: (Int) -> Void
    let page: (Int) -> Void
    var loading = false
    var translating = false
    var expanded = false
    var category: DesktopCandidateCategory = .frequency
    var categoriesVisible = false
    var categoryDetail = ""
    var emojiGroups: [DesktopEmojiCategory] = []
    var emojiGroupID = ""
    var setCategory: (DesktopCandidateCategory) -> Void = { _ in }
    var toggleCategories: () -> Void = {}
    var setEmojiGroup: (String) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var canRetryTranslation = false
    var retryTranslation: () -> Void = {}
    private var horizontal: Bool { style == .horizontal }
    private var rowHeight: CGFloat { translationEnabled ? 60 : 28 }
    private var expandedColumns: [CGFloat] {
        CandidateMetrics.expandedColumns(values, translations: translationEnabled ? translations : [:], maximum: maximumCellWidth)
    }
    private var expandedWidth: CGFloat { max(category == .emoji ? 310 : 250, expandedColumns.reduce(0, +) + 14) }
    private func width(_ candidate: Candidate) -> CGFloat {
        CandidateMetrics.width(candidate, translation: translationEnabled ? translations[candidate.text] : nil, maximum: maximumCellWidth)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          Group {
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(input.isEmpty ? "表情符号" : input).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        paging
                    }.padding(.horizontal, 5)
                    if values.isEmpty {
                        Text(category == .decomposition ? "没有匹配的拆字候选。试试 jiji（吉 + 吉）。" : "暂无候选")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                    } else {
                        LazyVGrid(columns: expandedColumns.map { GridItem(.fixed($0), spacing: 2, alignment: .leading) }, alignment: .leading, spacing: 1) {
                            ForEach(Array(values.enumerated()), id: \.offset) { offset, candidate in
                                cell(offset, candidate, width: expandedColumns[offset % 4])
                                    .frame(width: expandedColumns[offset % 4], height: rowHeight)
                            }
                        }
                    }
                }.padding(4).frame(width: expandedWidth, alignment: .leading)
            } else if horizontal {
                HStack(spacing: 2) {
                    if values.isEmpty {
                        HStack(spacing: 8) {
                            Text(input).font(Font(CandidateMetrics.candidateFont)).lineLimit(1)
                            CandidateTypingView(loading: loading, color: .secondaryLabelColor).frame(width: 20, height: 15)
                        }.frame(width: min(240, max(96, CGFloat(input.count) * 9 + 28)), alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                    ForEach(Array(values.enumerated()), id: \.offset) { offset, candidate in
                        cell(offset, candidate, width: width(candidate)).frame(width: width(candidate), height: rowHeight)
                    }
                    paging
                }.padding(4).frame(height: rowHeight + 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(input).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    ForEach(Array(values.enumerated()), id: \.offset) { offset, candidate in
                        cell(offset, candidate, width: maximumCellWidth).frame(height: rowHeight)
                    }
                    HStack { Spacer(); paging }
                }.padding(8).frame(width: maximumCellWidth + 16)
            }
          }
          if categoriesVisible {
              Divider()
              HStack(spacing: 3) {
                  ForEach(DesktopCandidateCategory.allCases) { item in
                      Button { setCategory(item) } label: {
                          Text(item.title).font(.system(size: 11)).lineLimit(1).fixedSize()
                              .padding(.horizontal, 5).padding(.vertical, 3)
                              .background(item == category ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.18) : .clear,
                                          in: RoundedRectangle(cornerRadius: 4))
                      }.buttonStyle(.plain).accessibilityLabel("候选分类：\(item.title)")
                          .accessibilityAddTraits(item == category ? .isSelected : [])
                  }
                  if category == .emoji, !emojiGroups.isEmpty {
                      Menu {
                          Button("全部表情") { setEmojiGroup("") }
                          ForEach(emojiGroups) { group in
                              Button(group.title) { setEmojiGroup(group.id) }
                          }
                      } label: {
                          Text(emojiGroups.first(where: { $0.id == emojiGroupID })?.title ?? "全部表情")
                              .font(.system(size: 11))
                      }.menuStyle(.borderlessButton).fixedSize()
                  } else if !categoryDetail.isEmpty {
                      Text(categoryDetail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                  }
                  Spacer(minLength: 0)
              }.padding(.horizontal, 5).padding(.vertical, 2)
                  .frame(maxWidth: expanded ? expandedWidth : nil, alignment: .leading)
          }
        }
        .background(CandidateMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .help("− / + 切换行，1–4 选择当前行；箭头按钮翻页；Tab 切换分类；空格选词，Shift + 数字输入译文")
    }
    private func cell(_ offset: Int, _ candidate: Candidate, width: CGFloat) -> some View {
        let translation = translations[candidate.text] ?? ""
        let fontSize = CandidateMetrics.fittedTranslationSize(translation, width: max(1, width - 28))
        return Button { choose(offset) } label: {
            HStack(alignment: .bottom, spacing: 5) {
                Text(expanded ? (offset / 4 == selected / 4 ? "\(offset % 4 + 1)" : "") : "\(offset + 1)").font(.system(size: 11, weight: .regular))
                    .foregroundStyle(offset == selected ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(width: expanded ? 8 : nil, height: 20).padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 2) {
                    if translationEnabled {
                        ZStack(alignment: .bottomLeading) {
                            Text(translation).font(.system(size: fontSize, weight: .regular))
                                .foregroundStyle(offset == selected ? Color.white.opacity(0.95) : Color.secondary)
                                .lineLimit(nil).fixedSize(horizontal: CandidateMetrics.isSingleWord(translation), vertical: true)
                                .opacity(loading && offset == 0 ? 0 : 1)
                            CandidateTypingView(loading: offset == 0 && (loading || (translating && translation.isEmpty)),
                                color: offset == selected ? .white : .secondaryLabelColor)
                                .frame(width: 20, height: 15).padding(.bottom, 3)
                        }.frame(height: 32, alignment: .bottomLeading)
                    }
                    Text(candidate.text).font(Font(CandidateMetrics.candidateFont))
                        .foregroundStyle(offset == selected ? Color.white : Color.primary)
                        .lineLimit(1).fixedSize(horizontal: candidate.text.count == 1, vertical: false).frame(height: 20)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(offset == selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).allowsHitTesting(!loading)
            .help("\(candidate.text)\n\(translation)")
            .accessibilityLabel("候选 \(offset + 1)，\(candidate.text)，\(translation)")
            .accessibilityAction(named: Text("输入候选")) { choose(offset) }
    }
    private var paging: some View {
        HStack(spacing: 0) {
            // Reserve the error action's width so asynchronous translation
            // status never adds a footer or resizes this toolbar.
            Button(action: retryTranslation) {
                Image(systemName: "arrow.clockwise").frame(width: 20, height: 24)
            }.disabled(!canRetryTranslation).opacity(canRetryTranslation ? 1 : 0)
                .accessibilityHidden(!canRetryTranslation)
                .help(status).accessibilityLabel("翻译失败，重试候选翻译")
            Button { page(-1) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 24) }
                .disabled(!canPrevious).help("上一页（−）").accessibilityLabel("上一页")
            Button { page(1) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 24) }
                .disabled(!canNext).help("下一页（+ 或 =）").accessibilityLabel("下一页")
            Button(action: toggleCategories) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down").frame(width: 20, height: 24)
            }.help("展开或收起候选；Tab 切换分类").accessibilityLabel("展开或收起候选")
        }.font(.system(size: 10, weight: .regular)).buttonStyle(.plain)
    }
}

private struct CandidateMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
