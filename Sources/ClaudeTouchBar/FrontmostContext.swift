import AppKit
import ApplicationServices

/// What the user was looking at when they opened the chat, so "riassumi
/// questo" or "salvalo in Lavoro" works without explaining it first.
/// Must be captured BEFORE this app activates its input window, or the
/// frontmost app is ClaudeTouchBar itself.
struct FrontmostContext {
    let appName: String
    let windowTitle: String?
    let selectedText: String?

    private static let maxTitle = 150
    private static let maxSelection = 2000

    static func capture() -> FrontmostContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let name = app.localizedName else { return nil }
        return FrontmostContext(
            appName: name,
            windowTitle: windowTitle(pid: app.processIdentifier),
            selectedText: selectedText(pid: app.processIdentifier)
        )
    }

    /// Window titles come with the Screen Recording permission this app
    /// already has for screenshots; without it the name is simply missing.
    private static func windowTitle(pid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let title = windows.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
                && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty
        }?[kCGWindowName as String] as? String
        return title.map { String($0.prefix(maxTitle)) }
    }

    /// Only if the user has granted Accessibility to the app — never prompts.
    private static func selectedText(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var selected: CFTypeRef?
        // CF type bridged from CFTypeRef: the cast can't fail at runtime.
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(text.prefix(maxSelection))
    }

    /// Short label for the input preview, e.g. "Safari · Titolo pagina".
    var hint: String {
        guard let windowTitle else { return appName }
        return "\(appName) · \(windowTitle.prefix(40))"
    }

    /// Prepended to the question; the model is told to ignore it when the
    /// question has nothing to do with what's on screen.
    func wrap(_ question: String) -> String {
        var context = "App in primo piano: \(appName)"
        if let windowTitle { context += ", finestra \"\(windowTitle)\"" }
        if let selectedText { context += ". Testo selezionato: \"\(selectedText)\"" }
        return """
        [Contesto, usalo solo se la domanda vi si riferisce: \(context)]
        \(question)
        """
    }
}
