import Combine
import CoreGraphics
import Foundation
import Network

struct DiscoveredReceiver: Identifiable, Equatable {
    /// Device ID from the Bonjour TXT record.
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// Emitter mode: captures local input and, while a receiver's shortcut is toggled on,
/// streams it there instead of delivering it locally.
final class EmitterController: ObservableObject {
    @Published private(set) var discovered: [DiscoveredReceiver] = []
    @Published private(set) var linkStates: [String: ReceiverLink.State] = [:]
    @Published private(set) var roundTrips: [String: TimeInterval] = [:]
    @Published private(set) var activeReceiverID: String?
    @Published private(set) var pairing: PairingSession?
    @Published private(set) var isCapturing = false
    @Published var lastError: String?

    /// Set while the UI records a shortcut so existing shortcuts don't fire.
    var isRecordingHotkey = false

    private let identity: Identity
    private let store: PeerStore
    private let capture = EventCapture()
    private var browser: NWBrowser?
    private var links: [String: ReceiverLink] = [:]
    private var timer: Timer?
    private var storeObserver: AnyCancellable?
    /// Where the local cursor is held while streaming.
    private var frozenLocation: CGPoint?
    private var edgePush = EdgePush()
    private var cachedLayout = ScreenLayout(displays: [])
    private var layoutRefreshed = Date.distantPast
    /// Key-ups to swallow because their key-down triggered a shortcut.
    private var swallowedKeyUps: Set<UInt16> = []

    init(identity: Identity, store: PeerStore) {
        self.identity = identity
        self.store = store
    }

    func start() {
        capture.handler = { [weak self] type, event in self?.handle(type, event) ?? false }
        isCapturing = capture.start()
        startBrowser()
        syncLinks()
        // $receivers fires before the new value is stored, so read it on the next turn.
        storeObserver = store.$receivers.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncLinks() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() {
        stopStreaming()
        capture.stop()
        browser?.cancel()
        timer?.invalidate()
        storeObserver = nil
        links.values.forEach { $0.close() }
        links = [:]
        pairing?.cancel()
    }

    // MARK: Streaming

    /// `entry` is where along the receiver's edge the cursor crossed over, when switching by edge.
    func toggle(_ receiverID: String, entry: Double? = nil) {
        if activeReceiverID == receiverID {
            stopStreaming()
            return
        }
        guard let link = links[receiverID] else { return }
        guard link.state == .connected else {
            lastError = "\(link.peer.name) is not connected"
            link.retrySoon()
            return
        }
        stopStreaming()
        lastError = nil
        activeReceiverID = receiverID
        link.send(.begin)
        link.send(.placement(side: link.peer.edge, entry: entry))
        // Freeze the local cursor; moves still arrive with their deltas.
        frozenLocation = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    func stopStreaming() {
        guard let id = activeReceiverID else { return }
        links[id]?.syncPointer()
        links[id]?.send(.end)
        activeReceiverID = nil
        frozenLocation = nil
        edgePush.reset()
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The receiver's cursor left through its return edge: take control back and bring the
    /// cursor in on this Mac's matching edge.
    private func returnFromEdge(_ receiverID: String, position: Double) {
        guard activeReceiverID == receiverID else { return }
        let side = links[receiverID]?.peer.edge
        stopStreaming()
        if let side, let point = layout.entryPoint(on: side, fraction: position) {
            CGWarpMouseCursorPosition(point)
        }
    }

    /// Display arrangement, refreshed every 2 s rather than on every move.
    private var layout: ScreenLayout {
        if Date().timeIntervalSince(layoutRefreshed) > 2 {
            cachedLayout = ScreenLayout.current()
            layoutRefreshed = Date()
        }
        return cachedLayout
    }

    /// Switches to the receiver placed on the edge the cursor is pushed through.
    private func checkEdge(_ event: CGEvent) {
        let location = event.location
        let layout = layout
        let target = store.receivers.first { peer in
            guard let edge = peer.edge, linkStates[peer.id] == .connected else { return false }
            return layout.isAtOuterEdge(location, edge)
        }
        let pushed = edgePush.push(
            against: target?.edge,
            dx: event.getDoubleValueField(.mouseEventDeltaX),
            dy: event.getDoubleValueField(.mouseEventDeltaY),
            now: ProcessInfo.processInfo.systemUptime
        )
        guard pushed, let target, let edge = target.edge else { return }
        toggle(target.id, entry: layout.fraction(of: location, along: edge))
    }

    /// macOS can quietly undo the cursor freeze, for example when focus moves to another app.
    /// If the cursor has left its spot, put it back and freeze it again.
    private func holdCursor(at location: CGPoint) {
        guard let frozenLocation,
              abs(location.x - frozenLocation.x) > 0.5 || abs(location.y - frozenLocation.y) > 0.5 else { return }
        CGWarpMouseCursorPosition(frozenLocation)
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .keyDown || type == .keyUp {
            let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyUp, swallowedKeyUps.remove(keyCode) != nil {
                return true
            }
            if type == .keyDown, !isRecordingHotkey,
               let peer = store.receivers.first(where: { $0.hotkey?.matches(keyCode: keyCode, flags: event.flags) == true }) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    toggle(peer.id)
                }
                swallowedKeyUps.insert(keyCode)
                return true
            }
        }
        guard let id = activeReceiverID, let link = links[id] else {
            if type == .mouseMoved, !isRecordingHotkey { checkEdge(event) }
            return false
        }
        switch StreamMessage(event: event, type: type) {
        case let .mouseMove(dx, dy):
            link.movePointer(dx: Double(dx), dy: Double(dy), time: EventClock.uptimeNanoseconds(of: event))
            holdCursor(at: event.location)
        case let message? where message.dependsOnPointer:
            link.syncPointer()
            link.send(message)
        case let message?:
            link.send(message)
        case nil:
            // System-defined events that aren't streamed media keys, such as Power, stay local.
            return false
        }
        return true
    }

    // MARK: Links

    private func syncLinks() {
        let peers = Dictionary(uniqueKeysWithValues: store.receivers.map { ($0.id, $0) })
        for (id, link) in links where peers[id] == nil {
            if activeReceiverID == id { stopStreaming() }
            link.close()
            links[id] = nil
            linkStates[id] = nil
            roundTrips[id] = nil
        }
        for peer in peers.values {
            if let link = links[peer.id] {
                let addressChanged = link.peer.manualHost != peer.manualHost || link.peer.publicKey != peer.publicKey
                link.peer = peer
                if addressChanged {
                    link.close()
                    link.retrySoon()
                }
                continue
            }
            let link = ReceiverLink(peer: peer, identity: identity)
            link.onStateChange = { [weak self] state in
                guard let self else { return }
                self.linkStates[peer.id] = state
                if state != .connected { self.roundTrips[peer.id] = nil }
                if state != .connected, self.activeReceiverID == peer.id {
                    // Connection lost mid-stream: hand control back to this Mac.
                    self.stopStreaming()
                }
            }
            link.onError = { [weak self] message in self?.lastError = message }
            link.onRoundTrip = { [weak self] rtt in self?.roundTrips[peer.id] = rtt }
            link.onEdgeExit = { [weak self] position in self?.returnFromEdge(peer.id, position: position) }
            links[peer.id] = link
            linkStates[peer.id] = .disconnected
        }
    }

    private func tick() {
        if !isCapturing {
            isCapturing = capture.start()
        }
        for link in links.values {
            link.tick(endpoint: endpoint(for: link.peer))
        }
    }

    private func endpoint(for peer: PairedPeer) -> NWEndpoint? {
        if let host = peer.manualHost, let endpoint = NetworkConfig.endpoint(forAddress: host) {
            return endpoint
        }
        return discovered.first { $0.id == peer.id }?.endpoint
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: NetworkConfig.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var seen = Set<String>()
            self.discovered = results.compactMap { result -> DiscoveredReceiver? in
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(txt) = result.metadata,
                      let id = txt["id"], id != self.identity.deviceID,
                      seen.insert(id).inserted else { return nil }
                return DiscoveredReceiver(id: id, name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: Pairing

    func startPairing(with receiver: DiscoveredReceiver) {
        beginPairing(endpoint: receiver.endpoint, name: receiver.name, manualHost: nil)
    }

    func startPairing(address: String) {
        guard let endpoint = NetworkConfig.endpoint(forAddress: address) else {
            lastError = "Invalid address: \(address)"
            return
        }
        let host = address.trimmingCharacters(in: .whitespaces)
        beginPairing(endpoint: endpoint, name: host, manualHost: host)
    }

    func dismissPairing() {
        pairing?.cancel()
        pairing = nil
    }

    private func beginPairing(endpoint: NWEndpoint, name: String, manualHost: String?) {
        pairing?.cancel()
        let session = PairingSession(connectingTo: endpoint, peerName: name, identity: identity)
        session.onComplete = { [weak self] peer in
            self?.store.addReceiver(peer, manualHost: manualHost)
        }
        pairing = session
    }
}
