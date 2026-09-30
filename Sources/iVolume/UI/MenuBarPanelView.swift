import SwiftUI

struct MenuBarPanelView: View {
    @EnvironmentObject private var processMonitor: AudioProcessMonitor
    @EnvironmentObject private var engineManager: AudioEngineManager
    @StateObject private var launchAtLogin = LaunchAtLoginManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = engineManager.permissionErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                Divider()
            }

            if processMonitor.items.isEmpty {
                Text("No apps are currently playing audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(processMonitor.items) { item in
                        AppRowView(item: item)
                        if item.id != processMonitor.items.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            )) {
                Text("Launch at Login")
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onAppear { launchAtLogin.refresh() }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .frame(width: 300)
    }
}
