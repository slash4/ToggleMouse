import SwiftUI

struct ReceiverView: View {
    @ObservedObject var controller: ReceiverController
    @ObservedObject var store: PeerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.listenerStatus)
                    let addresses = NetworkConfig.localIPv4Addresses()
                    if !addresses.isEmpty {
                        Text("IP: \(addresses.joined(separator: ", "))").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let id = controller.streamingEmitterID {
                        HStack {
                            StatusDot(color: .green)
                            Text("Controlled by \(store.emitters.first { $0.id == id }?.name ?? "emitter")")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Pairing") {
                VStack(alignment: .leading, spacing: 8) {
                    if let until = controller.pairingOpenUntil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Pairing open, \(max(0, Int(until.timeIntervalSince(context.date))))s left. On the emitter, pick this Mac under “Add a receiver”.")
                        }
                        Button("Stop Pairing") { controller.closePairing() }
                    } else {
                        Text("Emitters can only pair while pairing is open.").foregroundStyle(.secondary)
                        Button("Allow Pairing for 2 Minutes") { controller.openPairing() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Paired emitters") {
                VStack(alignment: .leading, spacing: 8) {
                    if store.emitters.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    }
                    ForEach(store.emitters) { peer in
                        HStack {
                            StatusDot(color: controller.connectedEmitterIDs.contains(peer.id) ? .green : .gray)
                            Text(peer.name)
                            Spacer()
                            Button("Unpair", role: .destructive) { controller.unpair(peer.id) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
        .sheet(item: Binding(get: { controller.pairing }, set: { if $0 == nil { controller.dismissPairing() } })) { session in
            PairingSheet(session: session, onDismiss: controller.dismissPairing)
        }
    }
}
