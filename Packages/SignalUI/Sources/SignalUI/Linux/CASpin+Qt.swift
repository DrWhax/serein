@_spi(Qt) import SwiftUI

extension View {
    public func caSpin(period: Double) -> some View { qtContinuousRotation(period: period) }
}
