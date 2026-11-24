// UsernameEditor's messages for a failed reservation (ts/state/ducks/username.preload.ts's
// mapping from ReserveUsernameError).

import Foundation
import SignalCore
import Testing
@testable import SignalSafe
@testable import SignalUI

@MainActor
@Suite struct UsernameEditingTests {
    @Test func reservationErrorsBecomeEditorMessages() {
        let cases: [(ReserveUsernameError, UsernameReservationError)] = [
            (.unprocessable, .checkCharacters), (.conflict, .usernameNotAvailable), (.notEnoughCharacters, .notEnoughCharacters),
            (.tooManyCharacters, .tooManyCharacters), (.checkStartingCharacter, .checkStartingCharacter), (.checkCharacters, .checkCharacters),
            (.notEnoughDiscriminator, .notEnoughDiscriminator), (.allZeroDiscriminator, .allZeroDiscriminator),
            (.leadingZeroDiscriminator, .leadingZeroDiscriminator), (.tooManyAttempts, .tooManyAttempts),
        ]
        for (reason, expected) in cases {
            #expect(SignalSession.reservationError(UsernameError.reserve(reason)) == expected, "\(reason)")
        }
        #expect(SignalSession.reservationError(UsernameError.invalid("x")) == .checkCharacters)
        #expect(SignalSession.reservationError(URLError(.timedOut)) == .general)
    }
}
