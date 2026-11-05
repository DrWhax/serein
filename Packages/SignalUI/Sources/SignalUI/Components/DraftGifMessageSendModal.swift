// Port of ts/components/DraftGifMessageSendModal.dom.tsx: "Add a message" before sending a GIF
// picked in the Fun picker. The GIF preview (at most 256px tall, px-2) above a
// CompositionTextArea; Send waits until the GIF has downloaded.

import SignalI18n
import SwiftUI

public struct DraftGifMessageSendModal: View {
    @Binding var draftText: String
    let gifFrame: RGBAImage?
    let gifWidth: CGFloat
    let gifHeight: CGFloat
    let loadingState: FunLoadingState
    let emojiPicker: AnyView?
    let onSubmit: () -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(draftText: Binding<String>, gifFrame: RGBAImage?, gifWidth: CGFloat, gifHeight: CGFloat, loadingState: FunLoadingState,
                emojiPicker: AnyView? = nil, onSubmit: @escaping () -> Void, onClose: @escaping () -> Void) {
        _draftText = draftText
        self.gifFrame = gifFrame
        self.gifWidth = gifWidth
        self.gifHeight = gifHeight
        self.loadingState = loadingState
        self.emojiPicker = emojiPicker
        self.onSubmit = onSubmit
        self.onClose = onClose
    }

    public var body: some View {
        AxoDialog.Content(size: .sm) {
            // The text area takes the initial focus.
            AxoDialog.Header(focusesClose: false) {
                AxoDialog.Title(i18n("icu:DraftGifMessageSendModal__Title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body(padding: .sm) {
                FunGifPreview(frame: gifFrame, state: loadingState, width: gifWidth, height: gifHeight, maxHeight: 256)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                CompositionTextArea(text: $draftText, isActive: true, emojiPicker: emojiPicker, onSubmit: onSubmit)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onClose)
                    AxoDialog.Action(i18n("icu:DraftGifMessageSendModal__SendButtonLabel"), variant: .strongPrimary,
                                     disabled: loadingState != .loaded, action: onSubmit)
                }
            }
        }
    }
}
