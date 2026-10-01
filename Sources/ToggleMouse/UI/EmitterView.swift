import AppKit
import SwiftUI

struct EmitterView: View {
    @ObservedObject var controller: EmitterController
    @ObservedObject var store: PeerStore
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !controller.isCapturing {
                Text("Input capture is off until Accessibility permission is granted.")
                    .foregroundStyle(.orange)
            }

            GroupBox("Paired receivers") {
                VStack(alignment: .leading, spacing: 12) {
                    if store.receivers.isEmpty {
                        Text("None yet. Pair a receiver below.").foregroundStyle(.secondary)
                    }
                    ForEach($store.receivers) { $peer in
                        ReceiverRow(
                            peer: $peer,
                            state: controller.linkStates[peer.id] ?? .disconnected,
                            roundTrip: controller.roundTrips[peer.id],
                            isStreaming: controller.activeReceiverID == peer.id,
                            onRecordingChange: { controller.isRecordingHotkey = $0 },
                            onUnpair: { store.receivers.removeAll { $0.id == peer.id } }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Add a receiver") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("On the receiver Mac, switch to Receiver mode and click “Allow pairing”.")
                        .foregroundStyle(.secondary)
                    let unpaired = controller.discovered.filter { found in !store.receivers.contains { $0.id == found.id } }
                    if unpaired.isEmpty {
                        Text("No unpaired receivers found on this network.").foregroundStyle(.secondary)
                    }
                    ForEach(unpaired) { receiver in
                        HStack {
                            Text(receiver.name)
                            Spacer()
                            Button("Pair…") { controller.startPairing(with: receiver) }
                        }
                    }
                    HStack {
                        TextField("IP address or host[:port]", text: $address)
                            .onSubmit(pairByAddress)
                        Button("Pair…", action: pairByAddress)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            if let error = controller.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .sheet(item: Binding(get: { controller.pairing }, set: { if $0 == nil { controller.dismissPairing() } })) { session in
            PairingSheet(session: session, onDismiss: controller.dismissPairing)
        }
    }

    private func pairByAddress() {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        controller.startPairing(address: address)
    }
}

private struct ReceiverRow: View {
    @Binding var peer: PairedPeer
    let state: ReceiverLink.State
    let roundTrip: TimeInterval?
    let isStreaming: Bool
    let onRecordingChange: (Bool) -> Void
    let onUnpair: () -> Void
    @State private var host = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusDot(color: isStreaming ? .red : state == .connected ? .green : state == .connecting ? .yellow : .gray)
                Text(peer.name).bold()
                Text(isStreaming ? "Streaming" : state == .connected ? "Connected" : state == .connecting ? "Connecting…" : "Offline")
                    .foregroundStyle(.secondary)
                if let roundTrip, state == .connected {
                    Text("\(Int((roundTrip * 1000).rounded())) ms")
                        .monospacedDigit()
                        .foregroundStyle(roundTrip > 0.03 ? .orange : .secondary)
                        .help("Network round trip, measured every 2 seconds")
                }
                Spacer()
                HotkeyField(hotkey: $peer.hotkey, onRecordingChange: onRecordingChange)
                Button("Unpair", role: .destructive, action: onUnpair)
            }
            HStack {
                Text("Address").foregroundStyle(.secondary)
                TextField("Automatic (Bonjour)", text: $host)
                    .onSubmit { peer.manualHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? nil : host }
            }
            .font(.callout)
        }
        .onAppear { host = peer.manualHost ?? "" }
    }
}

/// Click, then press a key combination with at least one modifier. Escape cancels.
struct HotkeyField: View {
    @Binding var hotkey: Hotkey?
    let onRecordingChange: (Bool) -> Void
    @State private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? (hotkey?.displayString ?? "Set shortcut") : "Press shortcut…") {
            monitor == nil ? startRecording() : stopRecording()
        }
        .frame(minWidth: 110)
    }

    private func startRecording() {
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let modifiers = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(Hotkey.modifierMask)
            guard !modifiers.isEmpty else { return nil }
            hotkey = Hotkey(keyCode: event.keyCode, modifiers: modifiers.rawValue)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecordingChange(false)
    }
}
