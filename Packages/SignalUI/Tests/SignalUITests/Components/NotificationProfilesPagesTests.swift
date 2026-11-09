// The profile pages' logic: the schedule summary (weekdays / weekends / daily / Sunday-first
// short names) and new profiles' colours (an opaque avatar background).

import SignalI18n
import Testing
@testable import SignalUI

@MainActor @Suite struct NotificationProfilesPagesTests {
    let i18n = Localizer(locale: "en")

    @Test func scheduleSummary() {
        #expect(NotificationProfilesEditPage.scheduleSummary(NotificationProfileDefaults.weekdays, i18n) == i18n("icu:NotificationProfiles--schedule-weekdays"))
        #expect(NotificationProfilesEditPage.scheduleSummary(NotificationProfileDefaults.weekends, i18n) == i18n("icu:NotificationProfiles--schedule-weekends"))
        #expect(NotificationProfilesEditPage.scheduleSummary(NotificationProfileDefaults.daily, i18n) == i18n("icu:NotificationProfiles--schedule-daily"))
        // Monday and Sunday only: Sunday first, joined by the separator.
        let custom = NotificationProfilesEditPage.scheduleSummary([1: true, 7: true], i18n)
        #expect(custom == i18n("icu:NotificationProfiles--schedule-sunday-short") + i18n("icu:NotificationProfiles--schedule-separator")
                + i18n("icu:NotificationProfiles--schedule-monday-short"))
    }

    @Test func randomColorIsAnOpaqueAvatarBackground() {
        let backgrounds = Set(AxoTokens.Avatar.allColorNames.map { name -> UInt32 in
            let bg = AxoTokens.Avatar.colorValues(name).bg
            func c(_ v: Double) -> UInt32 { UInt32((v * 255).rounded()) }
            return 0xFF00_0000 | c(bg.r) << 16 | c(bg.g) << 8 | c(bg.b)
        })
        for _ in 0..<20 { #expect(backgrounds.contains(NotificationProfileDefaults.randomColor())) }
        #expect(backgrounds.contains(0xFFE3_E3FE))     // A100, upstream's fallback
    }
}
