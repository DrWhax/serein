@_spi(Qt) import SwiftUI

extension View {
    func onSecondaryClick(isEnabled: Bool, perform: @escaping @MainActor (CGPoint) -> Void) -> some View {
        qtOnContextRequest(isEnabled: isEnabled, perform: perform)
    }
}
