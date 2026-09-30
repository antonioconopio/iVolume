import Combine
import ServiceManagement

/// Wraps `SMAppService.mainApp`, the modern (macOS 13+) API for registering this app as a login
/// item. The system is the source of truth for whether it's enabled; this just mirrors that
/// status for the UI and forwards toggles to it.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the system's current registration status, in case it changed outside the app
    /// (e.g. the user removed it in System Settings > General > Login Items).
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration can fail (e.g. sandboxing/approval issues); fall through to refresh()
            // so the toggle reflects whatever the system actually did rather than what we asked for.
        }
        refresh()
    }
}
