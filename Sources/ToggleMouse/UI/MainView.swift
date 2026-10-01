import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppModel.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Text("This Mac: \(model.identity.name)")
                    .foregroundStyle(.secondary)

                if !model.isTrusted {
                    GroupBox {
                        HStack {
                            Text("ToggleMouse needs Accessibility permission to \(model.mode == .emitter ? "capture" : "control") the mouse and keyboard.")
                            Spacer()
                            Button("Grant…") { model.requestAccessibility() }
                        }
                    }
                }

                if let emitter = model.emitter {
                    EmitterView(controller: emitter, store: model.store)
                } else if let receiver = model.receiver {
                    ReceiverView(controller: receiver, store: model.store)
                }

                WiFiSettingsView(awdl: model.awdl)
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 480)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

struct PairingSheet: View {
    @ObservedObject var session: PairingSession
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair with \(session.peerName)").font(.headline)
            switch session.phase {
            case .connecting:
                ProgressView("Connecting…")
                Button("Cancel", action: onDismiss)
            case .comparing(let code):
                Text(code.prefix(3) + " " + code.suffix(3))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                Text("Confirm only if the other Mac shows the same code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", action: onDismiss)
                    Button("Codes Match") { session.confirm() }
                        .keyboardShortcut(.defaultAction)
                }
            case .waitingForPeer:
                ProgressView("Waiting for the other Mac to confirm…")
                Button("Cancel", action: onDismiss)
            case .succeeded:
                Text("Paired.")
                Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
            case .failed(let reason):
                Text(reason).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Close", action: onDismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
