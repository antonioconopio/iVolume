import Foundation

/// Per-app volume/mute state persisted across relaunches, keyed by bundle ID.
struct StoredVolumeState: Codable, Equatable {
    var volume: Double
    var isMuted: Bool

    static let `default` = StoredVolumeState(volume: 1.0, isMuted: false)
}

final class VolumeStore {
    static let shared = VolumeStore()

    private let defaultsKey = "com.antonioconopio.iVolume.savedVolumes"
    private let queue = DispatchQueue(label: "com.antonioconopio.iVolume.VolumeStore")
    private var cache: [String: StoredVolumeState]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: StoredVolumeState].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func state(for bundleID: String) -> StoredVolumeState {
        queue.sync { cache[bundleID] ?? .default }
    }

    func setState(_ state: StoredVolumeState, for bundleID: String) {
        queue.sync {
            cache[bundleID] = state
            persistLocked()
        }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
