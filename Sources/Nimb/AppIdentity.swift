import Foundation

/// Installation-specific names. Both applications use the same implementation.
enum AppIdentity {
    static let isTest = Bundle.main.bundleIdentifier == "com.nimb.test"
    static let name = isTest ? "NimbTest" : "Nimb"
    static let identifier = isTest ? "com.nimb.test" : "com.nimb.app"
    static let systemName = isTest ? "nimbtest" : "nimb"
    static let bundleName = "\(name).app"

    static let logs: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return library.appendingPathComponent("Logs/\(name)", isDirectory: true)
    }()
}
