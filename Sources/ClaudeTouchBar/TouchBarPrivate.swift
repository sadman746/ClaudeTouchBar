import AppKit

// Bridges to undocumented AppKit/DFRFoundation APIs that let a background
// app pin a Touch Bar item to the system Control Strip and present a modal
// Touch Bar that stays available even while another app is frontmost.
// Same technique used by Pock, BetterTouchTool, TouchSwitcher, etc.
enum TouchBarPrivate {

    private static let dfrFoundation: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

    private typealias SetControlStripPresenceFn = @convention(c) (NSString, Bool) -> Void
    private typealias ShowsCloseBoxFn = @convention(c) (Bool) -> Void

    private static let setControlStripPresenceFn: SetControlStripPresenceFn? = {
        guard let handle = dfrFoundation,
              let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") else { return nil }
        return unsafeBitCast(sym, to: SetControlStripPresenceFn.self)
    }()

    private static let showsCloseBoxFn: ShowsCloseBoxFn? = {
        guard let handle = dfrFoundation,
              let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return nil }
        return unsafeBitCast(sym, to: ShowsCloseBoxFn.self)
    }()

    static func setControlStripPresence(for identifier: NSTouchBarItem.Identifier, present: Bool) {
        setControlStripPresenceFn?(identifier.rawValue as NSString, present)
    }

    static func setShowsCloseBoxWhenNotFrontmost(_ shows: Bool) {
        showsCloseBoxFn?(shows)
    }

    /// Pins `item` into the system Control Strip so it is visible no matter which app is frontmost.
    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        _ = (NSTouchBarItem.self as AnyObject).perform(NSSelectorFromString("addSystemTrayItem:"), with: item)
    }

    /// Presents `touchBar` system-wide, replacing the Control Strip content, with a close (X)
    /// button shown automatically once we're no longer the frontmost app.
    static func presentModal(_ touchBar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) {
        let selector = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        _ = (NSTouchBar.self as AnyObject).perform(selector, with: touchBar, with: trayIdentifier.rawValue)
    }

    static func dismissModal(_ touchBar: NSTouchBar) {
        let selector = NSSelectorFromString("dismissSystemModalTouchBar:")
        _ = (NSTouchBar.self as AnyObject).perform(selector, with: touchBar)
    }
}
