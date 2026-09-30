import Combine
import CoreAudio
import Foundation

/// Owns every active per-app `ProcessTap`, applies volume/mute changes to them, and rebuilds
/// them when the system's default output device changes (e.g. switching to AirPods).
final class AudioEngineManager: ObservableObject {
    static let shared = AudioEngineManager()

    @Published private(set) var permissionErrorMessage: String?

    private var taps: [AudioObjectID: ProcessTap] = [:]
    private let queue = DispatchQueue(label: "com.antonioconopio.iVolume.AudioEngineManager")
    private var defaultOutputDeviceAddress = CAProperty.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    private var listenerInstalled = false
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    private var currentOutputDeviceID: AudioObjectID? {
        CAProperty.deviceID(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    func start() {
        guard !listenerInstalled else { return }
        listenerInstalled = true
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputDeviceAddress, queue
        ) { [weak self] _, _ in
            self?.rebuildAllActiveTapsOnCurrentOutputDevice()
        }

        // Tears down taps for processes that are no longer running or no longer producing
        // audio output, since AudioProcessMonitor's list drops them as soon as either happens.
        AudioProcessMonitor.shared.$items
            .receive(on: queue)
            .sink { [weak self] items in
                self?.pruneTaps(keeping: Set(items.map(\.processObjectID)))
            }
            .store(in: &cancellables)
    }

    private func pruneTaps(keeping activeProcessObjectIDs: Set<AudioObjectID>) {
        for (processObjectID, tap) in taps where !activeProcessObjectIDs.contains(processObjectID) {
            tap.invalidate()
            taps[processObjectID] = nil
        }
    }

    /// Applies `volume`/`isMuted` for the given app. A tap is only created for apps that aren't
    /// at full, unmuted volume; at 100% unmuted, any existing tap is torn down so that app's
    /// audio passes straight through the system mixer with zero added overhead.
    func setVolume(_ volume: Double, isMuted: Bool, for item: AudioAppItem) {
        queue.async { [weak self] in
            self?.applyVolume(volume, isMuted: isMuted, for: item)
        }
    }

    func invalidateAll() {
        queue.sync {
            for (_, tap) in taps {
                tap.invalidate()
            }
            taps.removeAll()
        }
    }

    private func applyVolume(_ volume: Double, isMuted: Bool, for item: AudioAppItem) {
        let needsTap = isMuted || volume < 0.999

        guard needsTap else {
            taps[item.processObjectID]?.invalidate()
            taps[item.processObjectID] = nil
            return
        }

        guard let outputDeviceID = currentOutputDeviceID else { return }

        let tap = taps[item.processObjectID]
            ?? ProcessTap(processObjectID: item.processObjectID, pid: item.pid, bundleID: item.bundleID)
        taps[item.processObjectID] = tap

        do {
            try tap.activate(outputDeviceID: outputDeviceID)
            tap.gain = isMuted ? 0 : Float(volume)
            clearPermissionError()
        } catch {
            taps[item.processObjectID] = nil
            reportPermissionErrorIfNeeded(error)
        }
    }

    private func rebuildAllActiveTapsOnCurrentOutputDevice() {
        guard let outputDeviceID = currentOutputDeviceID else { return }
        for (processObjectID, tap) in taps {
            let gain = tap.gain
            do {
                try tap.activate(outputDeviceID: outputDeviceID)
                tap.gain = gain
            } catch {
                taps[processObjectID] = nil
                reportPermissionErrorIfNeeded(error)
            }
        }
    }

    private func reportPermissionErrorIfNeeded(_ error: Error) {
        guard let caError = error as? CoreAudioError, caError.status == kAudioDevicePermissionsError else {
            return
        }
        let message = "iVolume needs Audio Recording permission. Enable it in " +
            "System Settings > Privacy & Security > Audio Recording, then reopen iVolume."
        DispatchQueue.main.async { [weak self] in
            self?.permissionErrorMessage = message
        }
    }

    private func clearPermissionError() {
        guard permissionErrorMessage != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.permissionErrorMessage = nil
        }
    }
}
