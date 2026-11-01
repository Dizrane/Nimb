import Foundation
import Security

/// Whether this is a build of ours. What a changed build does says nothing about Nimb (a helper of the tunnel from another build left on the
/// Mac, files of the app edited, a build from the sources), so such a build sends no reports at all, by itself or by hand; the report in the
/// window still shows what it found. The relay turns away what has no signature of a release (see `ReportSigner`), this is the first line.
enum BuildCheck {
    /// The installed helper is not the one inside this app: a number the app does not have, or its own number with other content. A smaller
    /// number is ours from before an update, and the next start of the tunnel replaces it.
    static func helperIsForeign(installed: Int?, bundled: Int?, sameContent: Bool) -> Bool {
        guard let installed, let bundled else { return false }
        return installed > bundled || (installed == bundled && !sameContent)
    }

    /// A build that is not signed at all is not judged (a run from the sources); a signature that does not hold is a changed app.
    static func signatureHolds(_ status: OSStatus) -> Bool { status == errSecSuccess || status == errSecCSUnsigned }

    /// Looked at once: it reads the whole app.
    private static let signatureStatus: OSStatus = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return errSecSuccess }
        return SecStaticCodeCheckValidity(code, [], nil)
    }()

    /// Why this build is not ours, in words for the report; nil when it is.
    static var problem: String? {
        if ReportKey.data == nil { return "собрано не из официального выпуска" }
        let versions = WarpTunnelModel.helperVersions()
        let bundled = Bundle.main.url(forResource: "nimb-tunnel", withExtension: "sh").flatMap { try? Data(contentsOf: $0) }
        let installed = FileManager.default.contents(atPath: WarpPaths.helper)
        if helperIsForeign(installed: versions.installed, bundled: versions.bundled, sameContent: installed == bundled) {
            return versions.installed == versions.bundled
                ? "помощник туннеля той же версии, но другой"
                : "помощник туннеля не наш: версия \(versions.installed.map(String.init) ?? "?"), в приложении \(versions.bundled.map(String.init) ?? "?")"
        }
        if !signatureHolds(signatureStatus) { return "подпись приложения нарушена" }
        return nil
    }

    static var isOurs: Bool { problem == nil }
}
