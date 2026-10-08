import Foundation

/// Stable language codes shared by saved searches, CLI plans and controls.
public enum WordLanguage: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case en, fr, de, es, pt, it, nl, sv, da, no, fi, ru, ro, hu, tr, ar, el, ta
    public var id: Self { self }
    public var title: String {
        switch self {
        case .en: "English"
        case .fr: "French"
        case .de: "German"
        case .es: "Spanish"
        case .pt: "Portuguese"
        case .it: "Italian"
        case .nl: "Dutch"
        case .sv: "Swedish"
        case .da: "Danish"
        case .no: "Norwegian"
        case .fi: "Finnish"
        case .ru: "Russian"
        case .ro: "Romanian"
        case .hu: "Hungarian"
        case .tr: "Turkish"
        case .ar: "Arabic"
        case .el: "Greek"
        case .ta: "Tamil"
        }
    }
}
