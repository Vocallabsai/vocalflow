import Foundation

extension URL {
    /// Build a URL from a hard-coded literal. Traps via `precondition` so a
    /// typo surfaces the first time the call site runs, rather than crashing
    /// silently from a stray `!` somewhere down the line. Use only with
    /// literals — never with user input.
    init(staticString string: StaticString) {
        guard let url = URL(string: "\(string)") else {
            preconditionFailure("Invalid URL literal: \(string)")
        }
        self = url
    }
}

/// `x-apple.systempreferences:` deep links. Built once, reused everywhere.
enum SystemPrefsURL {
    static let microphone    = URL(staticString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    static let accessibility = URL(staticString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}
