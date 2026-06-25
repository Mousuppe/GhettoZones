import Foundation
import Security

enum CodeSigningHelper {
    /// True when the app is ad-hoc signed (no Apple Development / Developer ID team).
    /// macOS ties Accessibility permission to the code signature; ad-hoc builds break after each reinstall.
    static var isAdHocSigned: Bool {
        guard let url = Bundle.main.bundleURL as CFURL? else { return true }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return true }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &signingInfo) == errSecSuccess,
              let info = signingInfo as? [String: Any] else { return true }

        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return false
        }
        return true
    }
}
