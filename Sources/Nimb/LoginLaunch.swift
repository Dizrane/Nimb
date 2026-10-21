import AppKit

/// Whether macOS started Nimb at login (the login item of «Запускать при входе в систему») and not the person. The launch event of the
/// process says so; it is read while the program starts, later it is gone.
enum LoginLaunch {
    static func wasLaunchedAtLogin(_ event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent) -> Bool {
        guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
