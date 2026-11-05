// Generated from the ConversationDetails captures' DOM: per story, the header (title, kitten
// fixture or 0) and the visible member rows (title, kitten, isAdmin, label or "", emoji or "").

enum ConversationDetailsFixtures {
    static let stories: [String: (header: (String, Int), members: [(String, Int, Bool, String, String)])] = [
        "11": (("Some Conversation", 2), [
        ]),
        "as-admin": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "as-last-admin": (("Some Conversation", 2), [
            ("You", 3, true, "", ""),
            ("Abe Crooks", 2, false, "", ""),
            ("Adella Bahringer", 3, false, "", ""),
            ("Amaya Lang", 1, false, "", ""),
            ("Arnold Maggio", 3, false, "", ""),
        ]),
        "as-only-admin": (("Some Conversation", 2), [
            ("You", 2, true, "", ""),
        ]),
        "basic": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "group-editable": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "group-editable-edit-label-disabled": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "group-editable-with-custom-disappearing-timeout": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "group-links-on": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "in-another-call-group": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "in-another-call-individual": (("Some Conversation", 2), [
        ]),
        "member-labels-cannot-be-added": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "member-labels-edit-disabled": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "member-labels-not-a-member": (("Some Conversation", 2), [
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
            ("Arielle Kozey", 1, false, "", ""),
        ]),
        "signal-conversation": (("Some Conversation", 2), [
        ]),
        "system-contact": (("Christelle Stanton", 2), [
        ]),
        "terminated-group": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
        "terminated-group-as-admin": (("Some Conversation", 2), [
            ("You", 2, true, "", ""),
        ]),
        "with-call-history-group": (("Some Conversation", 2), [
            ("You", 2, false, "", ""),
            ("Casandra Renner", 3, true, "", ""),
            ("Adelia Christiansen", 3, false, "", ""),
            ("Alize Walter", 1, false, "", ""),
            ("Ardella Thompson", 1, false, "", ""),
        ]),
    ]
}
