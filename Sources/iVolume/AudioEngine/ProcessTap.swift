import CoreAudio
import Foundation
import os.log

/// Owns the Core Audio objects needed to capture and re-route one process's audio output at an
/// adjustable gain: a process tap, a private aggregate device that combines that tap with the
/// real output device, and an IOProc that copies tapped frames to the output scaled by gain.
final class ProcessTap {
    let processObjectID: AudioObjectID
    let pid: pid_t
    let bundleID: String

    private static let debugLevelsEnabled = ProcessInfo.processInfo.environment["IVOLUME_DEBUG_LEVELS"] == "1"
    private static let levelsLog = OSLog(subsystem: "com.antonioconopio.iVolume", category: "levels")

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var activeOutputDeviceID: AudioObjectID = kAudioObjectUnknown

    /// Backing storage for the gain read on the real-time IO thread. A 4-byte-aligned Float32
    /// load/store is a single atomic bus transaction on arm64 and x86_64, so the audio thread can
    /// read it without a lock, and this UI-thread setter never blocks on the audio thread.
    private let gainStorage: UnsafeMutablePointer<Float32> = {
        let pointer = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        pointer.pointee = 1.0
        return pointer
    }()

    var gain: Float {
        get { gainStorage.pointee }
        set { gainStorage.pointee = max(0, newValue) }
    }

    var isActive: Bool { tapID != kAudioObjectUnknown }

    init(processObjectID: AudioObjectID, pid: pid_t, bundleID: String) {
        self.processObjectID = processObjectID
        self.pid = pid
        self.bundleID = bundleID
    }

    deinit {
        invalidate()
        gainStorage.deallocate()
    }

    /// Creates the tap, aggregate device, and IOProc against `outputDeviceID`, and starts IO.
    /// No-op if already active against the same device.
    func activate(outputDeviceID: AudioObjectID) throws {
        if isActive, activeOutputDeviceID == outputDeviceID {
            return
        }
        if isActive {
            invalidate()
        }

        let tapUUID = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.uuid = tapUUID
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = kAudioObjectUnknown
        try checkStatus(
            AudioHardwareCreateProcessTap(description, &newTapID),
            "AudioHardwareCreateProcessTap for pid \(pid)"
        )
        tapID = newTapID

        guard let outputUID = CAProperty.string(outputDeviceID, kAudioDevicePropertyDeviceUID) else {
            invalidate()
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, message: "Output device has no UID")
        }

        // These composition values must bridge to genuine CFNumber, not CFBoolean: Core Audio's
        // HAL reads them with CFNumberGetValue, and Swift's Bool boxes to the distinct CFBoolean
        // singletons (kCFBooleanTrue/False) when put in `Any` — which silently fails that check,
        // leaving e.g. "private" un-set and the aggregate device published system-wide instead of
        // hidden to this process. Use plain Int 1/0 so it bridges to a real CFNumber.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "iVolume-\(pid)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: 1
                ] as [String: Any]
            ]
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let createStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID)
        guard createStatus == noErr else {
            invalidate()
            throw CoreAudioError(status: createStatus, message: "AudioHardwareCreateAggregateDevice for pid \(pid)")
        }
        aggregateDeviceID = newAggregateID
        activeOutputDeviceID = outputDeviceID

        do {
            try startIOProc()
        } catch {
            invalidate()
            throw error
        }
    }

    /// Tears down the IOProc, aggregate device, and tap, in that order. Safe to call repeatedly.
    func invalidate() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        activeOutputDeviceID = kAudioObjectUnknown
    }

    private func startIOProc() throws {
        let gainPointer = gainStorage
        let pid = self.pid
        var newIOProcID: AudioDeviceIOProcID?

        let status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, nil) {
            _, inInputData, _, outOutputData, _ in
            ProcessTap.copyScaled(
                from: inInputData,
                to: outOutputData,
                gain: gainPointer.pointee,
                pid: pid
            )
        }
        try checkStatus(status, "AudioDeviceCreateIOProcIDWithBlock for pid \(pid)")
        ioProcID = newIOProcID

        try checkStatus(
            AudioDeviceStart(aggregateDeviceID, newIOProcID),
            "AudioDeviceStart for pid \(pid)"
        )
    }

    /// Real-time safe: no allocation, no locks, no Swift runtime calls beyond raw arithmetic.
    /// Copies each input buffer into the matching output buffer scaled by `gain`. Buffer/channel
    /// count mismatches between the tap and the output device are handled by only copying the
    /// buffers/frames that exist on both sides; any remaining output buffers are left as the
    /// zeroed silence the HAL hands us.
    private static func copyScaled(
        from input: UnsafePointer<AudioBufferList>,
        to output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float32,
        pid: pid_t
    ) {
        let inputBufferCount = Int(input.pointee.mNumberBuffers)
        let outputBufferCount = Int(output.pointee.mNumberBuffers)
        let bufferCount = min(inputBufferCount, outputBufferCount)

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

        var peakBefore: Float32 = 0
        var peakAfter: Float32 = 0

        for i in 0..<bufferCount {
            let inBuffer = inputBuffers[i]
            let outBuffer = outputBuffers[i]
            guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }

            let sampleCount = min(Int(inBuffer.mDataByteSize), Int(outBuffer.mDataByteSize)) / MemoryLayout<Float32>.size
            let inSamples = inData.assumingMemoryBound(to: Float32.self)
            let outSamples = outData.assumingMemoryBound(to: Float32.self)

            if debugLevelsEnabled {
                for frame in 0..<sampleCount {
                    let sample = inSamples[frame]
                    peakBefore = max(peakBefore, abs(sample))
                    let scaled = sample * gain
                    outSamples[frame] = scaled
                    peakAfter = max(peakAfter, abs(scaled))
                }
            } else {
                for frame in 0..<sampleCount {
                    outSamples[frame] = inSamples[frame] * gain
                }
            }
        }

        if debugLevelsEnabled {
            os_log(
                .debug, log: levelsLog,
                "pid=%d gain=%.3f peakBefore=%.5f peakAfter=%.5f", pid, gain, peakBefore, peakAfter
            )
        }
    }
}
