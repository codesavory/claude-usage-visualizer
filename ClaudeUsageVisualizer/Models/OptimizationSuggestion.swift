import Foundation

struct SettingsPatch: Sendable, Hashable {
    let title: String
    let description: String
    /// JSON path → new value. Value is encoded as a String for simplicity.
    let keyPath: String
    let newValueJSON: String
    let previousValueJSON: String?
}

struct OptimizationSuggestion: Sendable, Identifiable, Hashable {
    enum Severity: Sendable, Hashable { case info, warn, critical }
    enum Kind: Sendable, Hashable {
        case pasteCommand(String)
        case settingsPatch(SettingsPatch)
        case openFile(URL)
    }

    let id: UUID
    let kind: Kind
    let title: String
    let rationale: String
    let applyLabel: String
    let severity: Severity
    let icon: String

    init(id: UUID = UUID(),
         kind: Kind,
         title: String,
         rationale: String,
         applyLabel: String,
         severity: Severity,
         icon: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.rationale = rationale
        self.applyLabel = applyLabel
        self.severity = severity
        self.icon = icon
    }
}
