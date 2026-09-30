import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioProcessMonitor.shared.start()
        AudioEngineManager.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioEngineManager.shared.invalidateAll()
    }
}
