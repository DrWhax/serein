// Port of ts/components/EditNicknameAndNoteModal.dom.tsx: a contact's nickname (given and
// family name) and note, in an AxoFieldList; Save is enabled once something changed.

import SwiftUI

/// `NicknameAndNote`
public struct NicknameAndNote: Sendable, Hashable {
    public var givenName: String?
    public var familyName: String?
    public var note: String?
    public init(givenName: String? = nil, familyName: String? = nil, note: String? = nil) {
        self.givenName = givenName
        self.familyName = familyName
        self.note = note
    }
}

public struct EditNicknameAndNoteModal: View {
    let avatar: ConversationAvatarData
    let initial: NicknameAndNote
    let onSave: (NicknameAndNote) -> Void
    let onClose: () -> Void
    @State private var givenName: String
    @State private var familyName: String
    @State private var note: String
    @Environment(\.i18n) var i18n

    public init(avatar: ConversationAvatarData, nicknameAndNote: NicknameAndNote, onSave: @escaping (NicknameAndNote) -> Void = { _ in },
                onClose: @escaping () -> Void = {}) {
        self.avatar = avatar
        self.initial = nicknameAndNote
        self.onSave = onSave
        self.onClose = onClose
        _givenName = State(initialValue: nicknameAndNote.givenName ?? "")
        _familyName = State(initialValue: nicknameAndNote.familyName ?? "")
        _note = State(initialValue: nicknameAndNote.note ?? "")
    }

    /// `toOptionalStringValue`
    static func optional(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var result: NicknameAndNote {
        NicknameAndNote(givenName: Self.optional(givenName), familyName: Self.optional(familyName), note: Self.optional(note))
    }

    var submitDisabled: Bool {
        let r = result
        return (r.givenName ?? "") == (initial.givenName ?? "") && (r.familyName ?? "") == (initial.familyName ?? "") && (r.note ?? "") == (initial.note ?? "")
    }

    func save() {
        guard !submitDisabled else { return }
        onSave(result)
        onClose()
    }

    public var body: some View {
        AxoDialog.Content(size: .sm) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:EditNicknameAndNoteModal__Title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body(padding: .sm) {
                VStack(spacing: 0) {
                    // mb-3 text-center text-balance
                    CSSText(i18n("icu:EditNicknameAndNoteModal__Description"), type: .bodyMedium, wrap: .balance, alignment: .center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
                    ListAvatar(data: avatar, size: 80).padding(.bottom, 12)
                    AxoFieldList.Root {
                        AxoFieldList.Item {
                            AxoTextField.Root(value: $givenName, maxGraphemes: 26, maxBytes: 128) {
                                AxoTextField.Input(placeholder: i18n("icu:EditNicknameAndNoteModal__FirstName__Placeholder"))
                                AxoTextField.Count()
                            }
                            .accessibilityLabel(i18n("icu:EditNicknameAndNoteModal__FirstName__Label"))
                        }
                        AxoFieldList.Item {
                            AxoTextField.Root(value: $familyName, maxGraphemes: 26, maxBytes: 128) {
                                AxoTextField.Input(placeholder: i18n("icu:EditNicknameAndNoteModal__LastName__Placeholder"))
                                AxoTextField.Count()
                            }
                            .accessibilityLabel(i18n("icu:EditNicknameAndNoteModal__LastName__Label"))
                        }
                        AxoFieldList.Item {
                            AxoTextField.Root(value: $note, maxGraphemes: 240, maxBytes: 240) {
                                AxoTextField.TextArea(placeholder: i18n("icu:EditNicknameAndNoteModal__Note__Placeholder"), minLines: 2, maxLines: 5)
                                AxoTextField.Count()
                            }
                            .accessibilityLabel(i18n("icu:EditNicknameAndNoteModal__Note__Label"))
                        }
                    }
                }
                .onSubmit(save)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onClose)
                    AxoDialog.Action(i18n("icu:save"), variant: .strongPrimary, disabled: submitDisabled, action: save)
                }
            }
        }
    }
}
