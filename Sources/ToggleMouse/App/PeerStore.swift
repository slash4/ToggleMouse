import Foundation

struct PairedPeer: Codable, Identifiable, Equatable {
    /// The peer's device ID.
    var id: String
    var name: String
    var publicKey: Data
    /// Receivers only: "host" or "host:port" to use instead of Bonjour discovery.
    var manualHost: String?
    /// Receivers only: shortcut that toggles streaming to this receiver.
    var hotkey: Hotkey?
    /// Receivers only: pushing the cursor through this edge of the emitter's screens
    /// switches to this receiver. nil turns edge switching off.
    var edge: ScreenEdge?
}

/// Paired peers, saved as JSON in Application Support. Public keys aren't secret;
/// this Mac's private key lives in the Keychain (see `Identity`).
final class PeerStore: ObservableObject {
    @Published var receivers: [PairedPeer] { didSet { save() } }
    @Published var emitters: [PairedPeer] { didSet { save() } }

    private struct Contents: Codable {
        var receivers: [PairedPeer] = []
        var emitters: [PairedPeer] = []
    }

    private let fileURL: URL

    init(directory: URL = PeerStore.defaultDirectory) {
        fileURL = directory.appendingPathComponent("peers.json")
        let contents = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) } ?? Contents()
        receivers = contents.receivers
        emitters = contents.emitters
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToggleMouse", isDirectory: true)
    }

    /// Adds or re-pairs a receiver, keeping its existing shortcut and address.
    func addReceiver(_ peer: PairedPeer, manualHost: String?) {
        if let index = receivers.firstIndex(where: { $0.id == peer.id }) {
            receivers[index].name = peer.name
            receivers[index].publicKey = peer.publicKey
            if let manualHost { receivers[index].manualHost = manualHost }
        } else {
            var peer = peer
            peer.manualHost = manualHost
            peer.hotkey = Hotkey.defaultHotkey(excluding: receivers.compactMap(\.hotkey))
            receivers.append(peer)
        }
    }

    func addEmitter(_ peer: PairedPeer) {
        if let index = emitters.firstIndex(where: { $0.id == peer.id }) {
            emitters[index] = peer
        } else {
            emitters.append(peer)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Contents(receivers: receivers, emitters: emitters)).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ToggleMouse: failed to save peers: \(error)")
        }
    }
}
