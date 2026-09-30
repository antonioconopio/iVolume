import AppKit
import Combine
import CoreAudio
import Darwin

/// Publishes the list of running apps that are currently producing audio output, reacting to
/// Core Audio's process-list and per-process running-output property notifications instead of
/// polling.
final class AudioProcessMonitor: ObservableObject {
    static let shared = AudioProcessMonitor()

    @Published private(set) var items: [AudioAppItem] = []

    private let queue = DispatchQueue(label: "com.antonioconopio.iVolume.AudioProcessMonitor")
    private var processListAddress = CAProperty.propertyAddress(kAudioHardwarePropertyProcessObjectList)
    private var observedProcessIDs: Set<AudioObjectID> = []
    private static let ownPID = ProcessInfo.processInfo.processIdentifier
    private var pollTimer: DispatchSourceTimer?

    private init() {}

    func start() {
        queue.async { [weak self] in
            self?.refresh()
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &processListAddress, queue
        ) { [weak self] _, _ in
            self?.refresh()
        }

        // Belt-and-suspenders: kAudioProcessPropertyIsRunningOutput's change notifications
        // aren't reliably delivered for every process on every macOS version, so a start/stop
        // transition on an already-known process (e.g. a new browser tab playing audio) can go
        // unnoticed by listeners alone. A short poll guarantees the ~2s detection latency the
        // app is meant to have regardless of whether the push notifications fire.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        timer.resume()
        pollTimer = timer
    }

    /// Re-reads the full process object list, figures out which processes are currently
    /// producing audio output, and (re)installs a per-process listener on
    /// `kAudioProcessPropertyIsRunningOutput` so future start/stop transitions are caught too.
    private func refresh() {
        let allProcessIDs = CAProperty.objectIDArray(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList
        )

        for processObjectID in allProcessIDs where !observedProcessIDs.contains(processObjectID) {
            observedProcessIDs.insert(processObjectID)
            var address = CAProperty.propertyAddress(kAudioProcessPropertyIsRunningOutput)
            AudioObjectAddPropertyListenerBlock(processObjectID, &address, queue) { [weak self] _, _ in
                self?.refresh()
            }
        }
        observedProcessIDs = observedProcessIDs.intersection(allProcessIDs)

        var newItems: [AudioAppItem] = []
        for processObjectID in allProcessIDs {
            guard CAProperty.uint32(processObjectID, kAudioProcessPropertyIsRunningOutput) == 1,
                  let pid = CAProperty.pid(processObjectID), pid > 0,
                  pid != Self.ownPID // skip iVolume itself: it becomes an "output" process once a tap is active
            else { continue }

            let identity = Self.identity(forProcessObjectID: processObjectID, pid: pid)
            let saved = VolumeStore.shared.state(for: identity.persistenceKey)
            newItems.append(
                AudioAppItem(
                    processObjectID: processObjectID,
                    pid: pid,
                    bundleID: identity.persistenceKey,
                    name: identity.name,
                    icon: identity.icon,
                    volume: saved.volume,
                    isMuted: saved.isMuted
                )
            )
        }
        newItems.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        DispatchQueue.main.async { [weak self] in
            self?.items = newItems
        }
    }

    private struct Identity {
        let name: String
        let icon: NSImage?
        let persistenceKey: String
    }

    /// Resolves a friendly name/icon/persistence-key for a tapped process, preferring, in order:
    /// a known-daemon override (e.g. avconferenced -> FaceTime) keyed by bundle ID; a direct
    /// `NSRunningApplication` match; the outermost `.app` bundle containing the executable, for
    /// apps (Chrome, Safari, most Electron apps) whose audio comes from a helper subprocess
    /// nested inside the main app's bundle rather than the main process itself; and finally the
    /// raw executable name, for bare command-line tools with no bundle at all.
    private static func identity(forProcessObjectID processObjectID: AudioObjectID, pid: pid_t) -> Identity {
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let rawCoreAudioBundleID = CAProperty.string(processObjectID, kAudioProcessPropertyBundleID)
        let resolvedBundleID = runningApp?.bundleIdentifier
            ?? (rawCoreAudioBundleID?.isEmpty == false ? rawCoreAudioBundleID : nil)

        // A few Apple system daemons that produce audio (avconferenced backs FaceTime, SharePlay,
        // and Messages screen sharing) resolve fine via NSRunningApplication/bundle ID above, but
        // under an unfriendly raw name and no `.app` bundle of their own to pull an icon from.
        // Check these first, keyed by the stable bundle ID rather than the executable name.
        if let resolvedBundleID, let overridden = friendlyIdentity(forBundleID: resolvedBundleID) {
            return overridden
        }

        if let runningApp, let bundleID = resolvedBundleID {
            return Identity(
                name: runningApp.localizedName ?? bundleID,
                icon: runningApp.icon,
                persistenceKey: bundleID
            )
        }

        let executablePath = executablePath(for: pid)
        if let appBundlePath = executablePath.flatMap(topLevelAppBundlePath(forExecutablePath:)),
           let bundle = Bundle(path: appBundlePath) {
            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? FileManager.default.displayName(atPath: appBundlePath)
            let icon = NSWorkspace.shared.icon(forFile: appBundlePath)
            let persistenceKey = bundle.bundleIdentifier ?? "app:\(appBundlePath)"
            return Identity(name: name, icon: icon, persistenceKey: persistenceKey)
        }

        let name = executablePath.map { ($0 as NSString).lastPathComponent }
            ?? resolvedBundleID
            ?? "pid \(pid)"
        let icon = executablePath.map { NSWorkspace.shared.icon(forFile: $0) }
        let persistenceKey = resolvedBundleID ?? executablePath.map { "cli:\($0)" } ?? "pid:\(pid)"
        return Identity(name: name, icon: icon, persistenceKey: persistenceKey)
    }

    /// Friendlier identity for known system daemons that have no `.app` bundle of their own.
    /// FaceTime is by far the most common source of `avconferenced` audio, so it's used as the
    /// display identity and, when installed, its icon.
    private static func friendlyIdentity(forBundleID bundleID: String) -> Identity? {
        switch bundleID {
        case "com.apple.avconferenced":
            let faceTimePath = "/System/Applications/FaceTime.app"
            let icon = FileManager.default.fileExists(atPath: faceTimePath)
                ? NSWorkspace.shared.icon(forFile: faceTimePath)
                : NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
            return Identity(name: "FaceTime", icon: icon, persistenceKey: "system:avconferenced")
        default:
            return nil
        }
    }

    /// Returns the path of the outermost `.app` bundle containing `executablePath`, e.g. maps
    /// `/Applications/Google Chrome.app/Contents/Frameworks/.../Helpers/Google Chrome Helper
    /// (Renderer).app/Contents/MacOS/...` to `/Applications/Google Chrome.app`.
    private static func topLevelAppBundlePath(forExecutablePath executablePath: String) -> String? {
        var accumulated = ""
        for component in executablePath.split(separator: "/") {
            accumulated += "/\(component)"
            if component.hasSuffix(".app") {
                return accumulated
            }
        }
        return nil
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [Int8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
