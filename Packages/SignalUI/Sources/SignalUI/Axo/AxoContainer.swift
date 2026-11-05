// Port of ts/axo/AxoContainer.dom.tsx: centred content column,
// `mx-auto w-full min-w-[320px] max-w-[750px] px-4 pt-2 pb-4`.

import SwiftUI

public enum AxoContainer {
    /// `<AxoContainer.Root>`
    public struct Root<Content: View>: View {
        let content: Content

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            // One block: padding applied to a tuple of children would pad each of them.
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(minWidth: 320, maxWidth: 750, alignment: .topLeading)
                .frame(maxWidth: .infinity)
        }
    }
}
