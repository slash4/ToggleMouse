import Foundation
import ServiceManagement
import ToggleMouseShared

/// Turns off AWDL (AirDrop and other Apple peer-to-peer Wi-Fi) while streaming, through
/// the privileged helper. AWDL hops the Wi-Fi radio between channels, which delivers
/// packets in bursts and makes the cursor stutter.
final class AWDLController: ObservableObject {
    enum Status: Equatable {
        case unavailable(String)
        case notInstalled
        case needsApproval
        case ready
    }

    /// Unchecking removes the helper, so no root component stays installed unused.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { install() } else { uninstall() }
        }
    }

    @Published private(set) var status: Status = .notInstalled
    @Published private(set) var lastError: String?

    private static let enabledKey = "suppressAWDL"

    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    private let teamID = CodeSigning.ownTeamID()
    private var connection: NSXPCConnection?
    private var isStreaming = false
    private var isSuppressing = false

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        refresh()
    }

    func refresh() {
        let newStatus: Status
        if teamID == nil {
            newStatus = .unavailable("Needs a build signed with an Apple Development or Developer ID certificate.")
        } else {
            switch service.status {
            case .enabled: newStatus = .ready
            case .requiresApproval: newStatus = .needsApproval
            default: newStatus = .notInstalled
            }
        }
        if newStatus != status { status = newStatus }
        apply()
    }

    func install() {
        lastError = nil
        do {
            try service.register()
        } catch {
            refresh()
            if status != .needsApproval { lastError = "Couldn't install the helper: \(error.localizedDescription)" }
        }
        refresh()
        if status == .needsApproval { openLoginItems() }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setStreaming(_ streaming: Bool) {
        isStreaming = streaming
        apply()
    }

    private func uninstall() {
        apply()
        connection?.invalidate()
        connection = nil
        do {
            try service.unregister()
        } catch {
            lastError = "Couldn't remove the helper: \(error.localizedDescription)"
        }
        refresh()
    }

    private func apply() {
        let wanted = isEnabled && isStreaming && status == .ready
        guard wanted != isSuppressing else { return }
        guard let helper = helper() else { return }
        isSuppressing = wanted
        helper.setAWDLSuppressed(wanted) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.lastError = error }
        }
    }

    private func helper() -> AWDLHelperProtocol? {
        guard let teamID else { return nil }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: AWDLHelperProtocol.self)
            // Only talk to the helper signed by our own team.
            connection.setCodeSigningRequirement(CodeSigning.requirement(identifier: HelperConstants.helperIdentifier, teamID: teamID))
            connection.invalidationHandler = { [weak self, weak connection] in
                DispatchQueue.main.async {
                    guard let self, self.connection === connection else { return }
                    self.connection = nil
                    self.helperLost()
                }
            }
            connection.interruptionHandler = { [weak self] in
                DispatchQueue.main.async { self?.helperLost() }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { self?.lastError = "Helper unavailable: \(error.localizedDescription)" }
        } as? AWDLHelperProtocol
    }

    /// The helper exited or restarted and forgot our request; ask again if still needed.
    private func helperLost() {
        guard isSuppressing else { return }
        isSuppressing = false
        apply()
    }
}
