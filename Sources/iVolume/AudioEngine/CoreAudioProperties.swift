import CoreAudio
import Foundation

/// Thin, typed wrappers around `AudioObjectGetPropertyData`/`AudioObjectSetPropertyData`.
/// Only the accessors this app actually needs are implemented (no generic catch-all).
enum CAProperty {

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func objectIDArray(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = propertyAddress(selector)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var values = [AudioObjectID](repeating: 0, count: count)
        let status = values.withUnsafeMutableBytes { buffer -> OSStatus in
            var size = dataSize
            return AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? values : []
    }

    static func uint32(
        _ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var addr = propertyAddress(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func pid(_ objectID: AudioObjectID) -> pid_t? {
        var addr = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func deviceID(
        _ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectID? {
        var addr = propertyAddress(selector, scope: scope)
        var value: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func string(
        _ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = propertyAddress(selector, scope: scope)
        var cfValue: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfValue) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfValue else { return nil }
        return cfValue.takeRetainedValue() as String
    }

    static func streamDescription(
        _ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> AudioStreamBasicDescription? {
        var addr = propertyAddress(selector)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? value : nil
    }
}

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let message: String

    var description: String { "\(message) (OSStatus \(status))" }
}

@discardableResult
func checkStatus(_ status: OSStatus, _ message: @autoclosure () -> String) throws -> OSStatus {
    guard status == noErr else {
        throw CoreAudioError(status: status, message: message())
    }
    return status
}
