import Foundation
import Security

/// XPC interface of the privileged helper, which can only switch the AWDL interface
/// (AirDrop and other Apple peer-to-peer Wi-Fi) off and back on.
@objc(TMAWDLHelperProtocol)
public protocol AWDLHelperProtocol {
    /// While suppressed, the helper keeps awdl0 down for as long as this connection lives.
    /// Replies with an error message, or nil on success.
    func setAWDLSuppressed(_ suppressed: Bool, reply: @escaping (String?) -> Void)
}

public enum HelperConstants {
    public static let machServiceName = "app.togglemouse.helper"
    public static let plistName = "app.togglemouse.helper.plist"
    public static let appIdentifier = "app.togglemouse.ToggleMouse"
    public static let helperIdentifier = "app.togglemouse.helper"
}

public enum CodeSigning {
    /// Team ID from this process's own signature; nil for ad-hoc or unsigned builds.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Matches code with the given identifier, signed through Apple's CA by the given team.
    public static func requirement(identifier: String, teamID: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
