import AppKit
import CoreAudio

/// A running process that is currently producing audio output, as shown in the panel.
struct AudioAppItem: Identifiable, Equatable {
    let processObjectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    var volume: Double
    var isMuted: Bool

    var id: AudioObjectID { processObjectID }

    static func == (lhs: AudioAppItem, rhs: AudioAppItem) -> Bool {
        lhs.processObjectID == rhs.processObjectID &&
        lhs.bundleID == rhs.bundleID &&
        lhs.name == rhs.name &&
        lhs.volume == rhs.volume &&
        lhs.isMuted == rhs.isMuted
    }
}
