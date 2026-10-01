import SwiftUI

struct WiFiSettingsView: View {
    @ObservedObject var awdl: AWDLController

    var body: some View {
        GroupBox("Wi-Fi") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Turn off AirDrop while streaming", isOn: $awdl.isEnabled)
                Text("Makes the cursor smoother on Wi-Fi. AirDrop, Universal Control, Sidecar and AirPlay pause until streaming stops. Needs a helper on both Macs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if awdl.isEnabled {
                    switch awdl.status {
                    case .ready:
                        Text("Helper installed.").foregroundStyle(.secondary)
                    case .notInstalled:
                        HStack {
                            Text("The helper isn't installed.")
                            Spacer()
                            Button("Install Helper…") { awdl.install() }
                        }
                    case .needsApproval:
                        HStack {
                            Text("Allow ToggleMouse in System Settings › General › Login Items.")
                            Spacer()
                            Button("Open Settings") { awdl.openLoginItems() }
                        }
                    case .unavailable(let reason):
                        Text(reason).foregroundStyle(.orange)
                    }
                }
                if let error = awdl.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
