import Foundation
import ToggleMouseShared

// Privileged launchd daemon, registered by the app through SMAppService. It does one
// thing: keep the awdl0 interface down while the app is streaming, because AWDL's channel
// hopping makes Wi-Fi deliver packets in bursts. All state lives on the main queue.

enum AWDL {
    private static let name = "awdl0"

    /// nil when this Mac has no awdl0 interface.
    static func isUp() -> Bool? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            if String(cString: entry.pointee.ifa_name) == name {
                return Int32(entry.pointee.ifa_flags) & IFF_UP != 0
            }
            cursor = entry.pointee.ifa_next
        }
        return nil
    }

    static func set(up: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [name, up ? "up" : "down"]
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Keeps awdl0 down while any client holds it, and restores it when the last one lets go,
/// but only if it was up to begin with.
final class Suppressor {
    static let shared = Suppressor()
    /// macOS brings AWDL back up on its own, e.g. when something browses for AirDrop.
    private static let checkInterval: DispatchTimeInterval = .milliseconds(500)

    private var holders: Set<ObjectIdentifier> = []
    private var restoreOnRelease = false
    private var timer: DispatchSourceTimer?

    var isIdle: Bool { holders.isEmpty }

    func hold(_ holder: ObjectIdentifier) -> String? {
        guard let isUp = AWDL.isUp() else { return "This Mac has no awdl0 interface" }
        if holders.isEmpty { restoreOnRelease = isUp }
        holders.insert(holder)
        if isUp, !AWDL.set(up: false) {
            release(holder)
            return "Couldn't turn off awdl0"
        }
        startTimer()
        return nil
    }

    func release(_ holder: ObjectIdentifier) {
        guard holders.remove(holder) != nil, holders.isEmpty else { return }
        timer?.cancel()
        timer = nil
        if restoreOnRelease { _ = AWDL.set(up: true) }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
        timer.setEventHandler {
            if AWDL.isUp() == true { _ = AWDL.set(up: false) }
        }
        timer.resume()
        self.timer = timer
    }
}

final class HelperService: NSObject, AWDLHelperProtocol {
    func setAWDLSuppressed(_ suppressed: Bool, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            let holder = ObjectIdentifier(self)
            if suppressed {
                reply(Suppressor.shared.hold(holder))
            } else {
                Suppressor.shared.release(holder)
                reply(nil)
            }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    /// Exit once idle, so launchd starts the current binary on next use after an app update.
    private static let idleExitDelay: TimeInterval = 30

    private var connections = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = HelperService()
        let holder = ObjectIdentifier(service)
        connection.exportedInterface = NSXPCInterface(with: AWDLHelperProtocol.self)
        connection.exportedObject = service
        // The app quitting or crashing ends the connection, which restores AWDL.
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                Suppressor.shared.release(holder)
                self?.connections -= 1
                self?.exitWhenIdle()
            }
        }
        DispatchQueue.main.async { self.connections += 1 }
        connection.resume()
        return true
    }

    func exitWhenIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleExitDelay) {
            if self.connections == 0, Suppressor.shared.isIdle { exit(0) }
        }
    }
}

guard let teamID = CodeSigning.ownTeamID() else {
    NSLog("ToggleMouseHelper: not signed with a team identity, refusing to run")
    exit(1)
}
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
// Only the ToggleMouse app signed by the same team may connect.
listener.setConnectionCodeSigningRequirement(CodeSigning.requirement(identifier: HelperConstants.appIdentifier, teamID: teamID))
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
delegate.exitWhenIdle()
dispatchMain()
