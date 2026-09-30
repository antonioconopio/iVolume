import SwiftUI

@main
struct iVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var processMonitor = AudioProcessMonitor.shared
    @StateObject private var engineManager = AudioEngineManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView()
                .environmentObject(processMonitor)
                .environmentObject(engineManager)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
