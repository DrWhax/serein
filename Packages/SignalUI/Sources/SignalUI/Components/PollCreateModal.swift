// Port of ts/components/PollCreateModal.dom.tsx (stylesheets/components/PollCreateModal.scss):
// the "New poll" dialog — a question, two to ten options (an empty one is always kept at the
// end, and emptied middle options are removed), "Allow multiple votes", and Send, which
// validates first and shows the first error under the switch.

import SignalI18n
import SwiftUI

/// `PollCreateType`
public struct PollCreateType: Sendable, Equatable {
    public var question: String
    public var options: [String]
    public var allowMultiple: Bool
}

/// ts/types/Polls.dom.ts, ts/util/longAttachment.std.ts
public enum PollLimits {
    public static let questionMaxLengthSend = 100
    public static let optionMaxLength = 100
    public static let optionsMinCount = 2
    public static let optionsMaxCount = 10
    public static let maxMessageBodyByteLength = 2 * 1024
}

public struct PollCreateModal: View {
    struct PollOption: Identifiable, Equatable {
        let id = UUID()
        var value = ""
    }

    let onClose: () -> Void
    let onSendPoll: (PollCreateType) -> Void
    @State private var question = ""
    @State private var options = [PollOption(), PollOption()]
    @State private var allowMultiple = true
    @State private var emojiPickerOpenForOption: UUID?
    @State private var validationErrorMessages: [String]?
    @Environment(\.i18n) var i18n

    public init(onClose: @escaping () -> Void = {}, onSendPoll: @escaping (PollCreateType) -> Void = { _ in }) {
        self.onClose = onClose
        self.onSendPoll = onSendPoll
    }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `computeOptionsAfterChange`
    static func optionsAfterChange(_ options: [PollOption], changed index: Int) -> [PollOption] {
        var result = options
        let isLast = index == result.count - 1
        let isSecondToLast = index == result.count - 2
        let hasText = !trimmed(result[index].value).isEmpty
        let canAddMore = result.count < PollLimits.optionsMaxCount
        let canRemove = result.count > PollLimits.optionsMinCount
        if isLast && hasText && canAddMore { result.append(PollOption()) }
        if isSecondToLast && !hasText && canRemove, let last = result.last, trimmed(last.value).isEmpty { result.removeLast() }
        if !isLast && !hasText && canRemove {
            result.remove(at: index)
            if let last = result.last, !trimmed(last.value).isEmpty, result.count < PollLimits.optionsMaxCount { result.append(PollOption()) }
        }
        return result
    }

    func setOption(_ id: UUID, _ value: String) {
        guard let i = options.firstIndex(where: { $0.id == id }) else { return }
        var updated = options
        updated[i].value = value
        options = Self.optionsAfterChange(updated, changed: i)
    }

    var allowSend: Bool { !Self.trimmed(question).isEmpty || options.contains { !Self.trimmed($0.value).isEmpty } }

    /// `validatePoll`
    func validate() -> [String] {
        var errors: [String] = []
        let q = Self.trimmed(question)
        if q.isEmpty { errors.append(i18n("icu:PollCreateModal__Error--RequiresQuestion")) }
        if q.utf8.count > PollLimits.maxMessageBodyByteLength { errors.append(i18n("icu:PollCreateModal__Error--QuestionTooLong")) }
        let values = options.map { Self.trimmed($0.value) }
        if values.filter({ !$0.isEmpty }).count < PollLimits.optionsMinCount { errors.append(i18n("icu:PollCreateModal__Error--RequiresTwoOptions")) }
        if values.contains(where: { $0.utf8.count > PollLimits.maxMessageBodyByteLength }) { errors.append(i18n("icu:PollCreateModal__Error--OptionTooLong")) }
        return errors
    }

    func send() {
        let errors = validate()
        if !errors.isEmpty {
            validationErrorMessages = errors
            return
        }
        onSendPoll(PollCreateType(question: Self.trimmed(question), options: options.map { Self.trimmed($0.value) }.filter { !$0.isEmpty },
                                  allowMultiple: allowMultiple))
    }

    /// `mb-2 block font-semibold text-primary`
    func label(_ key: String) -> some View {
        CSSText(i18n(key), type: AxoType.bodyMedium.weight(600), color: .labelPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }

    func emojiPicker(_ id: UUID) -> AnyView {
        AnyView(FunEmojiPicker(panel: FunPanelEmojis(recentEmojis: [], onSelectEmoji: { emoji in
            // closeOnSelect; not past the option's grapheme limit.
            if let i = options.firstIndex(where: { $0.id == id }), options[i].value.count + 1 <= PollLimits.optionMaxLength {
                setOption(id, options[i].value + emoji)
            }
            emojiPickerOpenForOption = nil
        })))
    }

    public var body: some View {
        AxoDialog.Content(size: .md) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:PollCreateModal__title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body {
                VStack(spacing: 0) {
                    label("icu:PollCreateModal__questionLabel")
                    // .PollCreateModalInput: the Input__container's margin-block is 0.
                    Input(value: Binding(get: { question }, set: { question = $0 }),
                          placeholder: i18n("icu:PollCreateModal__questionPlaceholder"), clearLabel: i18n("icu:cancel"), forceTextarea: true,
                          maxLengthCount: PollLimits.questionMaxLengthSend, whenToShowRemainingCount: PollLimits.questionMaxLengthSend - 30)
                        .padding(.bottom, 18)
                    label("icu:PollCreateModal__optionsLabel")
                    VStack(spacing: 10) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            Input(value: Binding(get: { option.value }, set: { setOption(option.id, $0) }),
                                  placeholder: i18n("icu:PollCreateModal__optionPlaceholder", ["number": .string(String(index + 1))]),
                                  clearLabel: i18n("icu:cancel"), forceTextarea: true,
                                  maxLengthCount: PollLimits.optionMaxLength, whenToShowRemainingCount: PollLimits.optionMaxLength - 30,
                                  children: AnyView(FunEmojiPickerButton(isOpen: Binding(get: { emojiPickerOpenForOption == option.id },
                                                                                         set: { emojiPickerOpenForOption = $0 ? option.id : nil }),
                                                                         picker: emojiPicker(option.id))))
                        }
                    }
                    .padding(.bottom, 10)
                    // <label class="mb-2.5 flex items-center gap-3">
                    HStack(spacing: 12) {
                        CSSText(i18n("icu:PollCreateModal__allowMultipleVotes"), type: .bodyMedium, color: .labelPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { allowMultiple.toggle() }
                        AxoSwitch.Root(checked: $allowMultiple, label: i18n("icu:PollCreateModal__allowMultipleVotes"))
                    }
                    .padding(.bottom, 10)
                    if let first = validationErrorMessages?.first {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            AxoSymbol.InlineGlyph("error-circle", size: 13, weight: 400).cssTextColor(.labelDestructive)
                            CSSText(" " + first, type: .bodyMedium, color: .labelPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onClose)
                    AxoDialog.Action(i18n("icu:PollCreateModal__sendButton"), variant: .strongPrimary, disabled: !allowSend, action: send)
                }
            }
        }
    }
}
