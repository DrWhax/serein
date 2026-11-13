// Shared contacts in the app: the dialog's choice as sent (enqueueSharedContactForSend), and a
// received contact's fields in the detail panel.

import SignalCore
import SignalUI
import Testing
@testable import SignalSafe

@MainActor @Suite struct SharedContactSurfacesTests {
    @Test func theDialogsChoiceIsSentAsUpstreamDoes() {
        var d = ShareContactDraft(aci: "22222222-2222-4222-8222-222222222222", avatar: ShareContactAvatar(image: nil, isProfile: true),
                                  name: EmbeddedContactName(givenName: "Fran", middleName: "Q", familyName: "Friend"), e164: "+15555550102",
                                  nickname: ("F", nil), note: "from work")
        var info = SignalSession.sharedContactInfo(d)
        #expect(info.givenName == "Fran" && info.middleName == "Q" && info.familyName == "Friend")
        // The number as one CUSTOM entry; the ACI, nickname, note and avatar kind as chosen.
        #expect(info.numbers == [.init(value: "+15555550102", type: 4)])
        #expect(info.aci == d.aci && info.signalNicknameGiven == "F" && info.signalNicknameFamily == nil && info.note == "from work")
        #expect(info.avatarIsProfile && info.canBeShared)
        // Unticked number, no ACI: nothing SignalCore would send.
        d.e164 = nil
        d.aci = nil
        d.avatar = nil
        info = SignalSession.sharedContactInfo(d)
        #expect(info.numbers.isEmpty && !info.avatarIsProfile && !info.canBeShared)
    }

    @Test func detailFieldsMapTypesAndLabels() {
        var c = SharedContactInfo(givenName: "Bob")
        c.numbers = [.init(value: "+1", type: 2), .init(value: "+2", type: 4, label: "boat")]
        c.emails = [.init(value: "b@example.com", type: 3)]
        c.signalNicknameGiven = "Bobby"
        c.note = "n"
        let f = SignalSession.contactDetailFields(c)
        #expect(f.number == [.init(.mobile, "+1"), .init(.custom, "+2", label: "boat")])
        #expect(f.email == [.init(.work, "b@example.com")])
        #expect(f.nicknameGiven == "Bobby" && f.note == "n")
    }
}
