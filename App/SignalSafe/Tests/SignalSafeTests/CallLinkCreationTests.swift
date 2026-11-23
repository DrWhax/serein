import Foundation
import SignalCore
import Testing
@testable import SignalSafe

@MainActor @Suite struct CallLinkCreationTests {
    let link = CallLinkRecord(roomId: "room", rootKey: Data(repeating: 1, count: 16), adminKey: Data([2]))

    @Test func unavailableCallingShowsFailureOnTheCallsTab() async {
        let session = SignalSession()
        await session.createCallLink()
        #expect(session.callLinkModal == .creationFailed(code: nil))
        #expect(!session.isCreatingCallLink)
    }

    @Test func retryShowsProgressAndOpensTheCreatedLink() async {
        let session = SignalSession()
        await session.createCallLink { throw URLError(.notConnectedToInternet) }
        #expect(session.callLinkModal == .creationFailed(code: nil))

        await session.createCallLink {
            #expect(session.isCreatingCallLink)
            #expect(session.callLinkModal == nil)
            await session.createCallLink {
                Issue.record("A second click started another creation request")
                return nil
            }
            return link
        }
        #expect(!session.isCreatingCallLink)
        #expect(session.callLinkModal == .edit(roomId: link.roomId))
        #expect(session.callLink(link.roomId) == link)
    }

    @Test func databaseObservationArrivingFirstDoesNotDuplicateTheLink() async {
        let session = SignalSession()
        await session.createCallLink {
            session.callLinks = [link]
            return link
        }
        #expect(session.callLinks == [link])
        #expect(session.callLinkModal == .edit(roomId: link.roomId))
    }

    @Test func serverFailuresIdentifyTheRequestWithoutShowingItsContents() async {
        let session = SignalSession()
        await session.createCallLink { throw ChatRequestError.http(status: 400, message: "private", body: Data([1])) }
        #expect(session.callLinkModal == .creationFailed(code: "HTTP 400 (chat)"))
        await session.createCallLink { throw CallingError.callLinkRequestFailed(status: 403) }
        #expect(session.callLinkModal == .creationFailed(code: "HTTP 403 (SFU)"))
    }
}
