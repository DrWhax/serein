// Generated from the AttachmentSection Documents / Audio / Links captures' DOM (same tuples as
// DocumentListItemFixtures and AudioListItemFixtures; links: (date, img src or "")).

enum AttachmentSectionListFixtures {
    static let documents: [(String, String, String, Int)] = [
        ("fooquux.docx", "167 kB", "Nov 5", 1),
        ("quxqux.pdf", "12.8 MB", "Nov 4", 2),
        ("bazquux.txt", "9 MB", "Nov 5", 1),
        ("foobaz.pdf", "49.5 MB", "Nov 5", 0),
        ("barbar.docx", "7.1 MB", "Nov 4", 1),
        ("quuxquux.docx", "21.5 MB", "Nov 4", 1),
        ("fooquux.docx", "23.3 MB", "Nov 5", 0),
        ("bazquux.docx", "48.6 MB", "Nov 4", 0),
    ]
    static let audio: [(String, String, String, Int, [Double], Bool)] = [
        ("fooquux.mp3", "167 kB · Audio · 0:00", "Nov 5", 1, [2, 2, 2, 2, 2, 2, 2], true),
        ("quxqux.mp3", "12.8 MB · Audio · 0:00", "Nov 4", 2, [2, 2, 2, 2, 2, 2, 2], true),
        ("bazquux.mp3", "9 MB · Audio · 0:00", "Nov 5", 1, [2, 2, 2, 2, 2, 2, 2], true),
        ("foobaz.mp3", "49.5 MB · Audio · 1:31", "Nov 5", 0, [15.59, 15.17, 15.31, 14.63, 15.8, 14.7, 8.47], true),
        ("barbar.mp3", "7.1 MB · Audio · 0:00", "Nov 4", 1, [2, 2, 2, 2, 2, 2, 2], true),
        ("quuxquux.mp3", "21.5 MB · Audio · 0:00", "Nov 4", 1, [2, 2, 2, 2, 2, 2, 2], true),
        ("fooquux.mp3", "23.3 MB · Audio · 1:31", "Nov 5", 0, [15.59, 15.17, 15.31, 14.63, 15.8, 14.7, 8.47], true),
        ("bazquux.mp3", "48.6 MB · Audio · 1:31", "Nov 4", 0, [15.59, 15.17, 15.31, 14.63, 15.8, 14.7, 8.47], true),
    ]
    static let links: [(String, String)] = [
        ("Nov 5", ""),
        ("Nov 5", ""),
        ("Nov 4", "/fixtures/cat-screenshot-3x4.png"),
        ("Nov 5", ""),
        ("Nov 4", ""),
        ("Nov 4", ""),
    ]
}
