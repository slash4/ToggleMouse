import Foundation
import Network

enum NetworkConfig {
    static let serviceType = "_togglemouse._tcp"
    static let defaultPort: UInt16 = 52525

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .responsiveData
        return parameters
    }

    /// Pointer datagrams. Marked as interactive voice so Wi-Fi puts them in its fastest queue.
    static func datagramParameters() -> NWParameters {
        let parameters = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
        parameters.serviceClass = .interactiveVoice
        return parameters
    }

    /// Parses "host" or "host:port" typed by the user. IPv6 literals use the default port.
    static func endpoint(forAddress address: String) -> NWEndpoint? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var host = trimmed
        var port = defaultPort
        if trimmed.filter({ $0 == ":" }).count == 1, let colon = trimmed.firstIndex(of: ":") {
            guard let parsed = UInt16(trimmed[trimmed.index(after: colon)...]), parsed > 0 else { return nil }
            host = String(trimmed[..<colon])
            port = parsed
        }
        return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }

    /// IPv4 addresses of this Mac, shown on the receiver to help with manual entry.
    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}

/// Length-prefixed frames over a TCP connection. All callbacks run on the main queue,
/// and `onClose` fires exactly once.
final class FramedConnection {
    static let maxFrameSize = 64 * 1024

    var onReady: (() -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    private let connection: NWConnection
    private var isClosed = false

    /// The peer's resolved address once connected.
    var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    convenience init(endpoint: NWEndpoint) {
        self.init(NWConnection(to: endpoint, using: NetworkConfig.parameters()))
    }

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .waiting(let error), .failed(let error):
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
        receiveHeader()
    }

    func send(_ frame: Data) {
        guard !isClosed else { return }
        var packet = Data()
        withUnsafeBytes(of: UInt32(frame.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(frame)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error.localizedDescription) }
        })
    }

    func close() {
        finish(nil)
    }

    private func finish(_ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        let handler = onClose
        onReady = nil
        onFrame = nil
        onClose = nil
        handler?(reason)
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error { self.finish(error.localizedDescription); return }
            guard let data, data.count == 4 else { self.finish(isComplete ? nil : "Malformed frame"); return }
            let length = data.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= Self.maxFrameSize else { self.finish("Invalid frame length"); return }
            self.receiveBody(length: length)
        }
    }

    private func receiveBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error { self.finish(error.localizedDescription); return }
            guard let data, data.count == length else { self.finish(isComplete ? nil : "Malformed frame"); return }
            self.onFrame?(data)
            if !self.isClosed { self.receiveHeader() }
        }
    }
}
