import Foundation
import AudioToolbox
import CoreAudio
import AVFoundation

// Recorder — records the microphone and the system output at the same time,
// into one 2-channel WAV: L = you (mic), R = everybody else (system audio).
// Uses a Core Audio process tap + a private aggregate device, so the user's
// real input/output device selection is never touched.
//
// Two known traps (both fail silently, see build notes):
//  - the app must be launched by launchd (`open`), not by a shell, or the
//    System Audio Recording permission is checked against the terminal;
//  - the mic must NOT be the aggregate clock master (a 24 kHz BT mic pulls
//    the aggregate down and the 48 kHz tap goes silent).

struct RecorderError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class Recorder {

    struct Stats {
        let frames: Int
        let sampleRate: Double
        let micRMS: Double
        let sysRMS: Double
        var seconds: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    }

    // Live levels for the UI (racy reads are fine for a meter).
    private(set) var micPeak: Float = 0
    private(set) var sysPeak: Float = 0
    private(set) var isRecording = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rawHandle: FileHandle?
    private let ioQueue = DispatchQueue(label: "nerdsidekiq.io")

    private var micEnergy: Double = 0
    private var sysEnergy: Double = 0
    private var framesSeen: Int = 0
    private var aggRate: Float64 = 48000

    // MARK: property helpers

    private func addr(_ sel: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func getProp<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ def: T) -> T? {
        var a = a
        var size = UInt32(MemoryLayout<T>.size)
        var value = def
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        return err == noErr ? value : nil
    }

    private func getString(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
        var a = a
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString? = nil
        let err = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        guard err == noErr, let s = cf else { return nil }
        return s as String
    }

    private func streamConfig(_ obj: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32] {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, raw) == noErr else { return [] }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.map { $0.mNumberChannels }
    }

    // MARK: lifecycle

    func start(outPath: String) throws {
        guard !isRecording else { throw RecorderError(message: "already recording") }
        micEnergy = 0; sysEnergy = 0; framesSeen = 0
        micPeak = 0; sysPeak = 0

        // 1. Default input device (do NOT change it)
        guard let micID: AudioObjectID = getProp(AudioObjectID(kAudioObjectSystemObject),
                                                 addr(kAudioHardwarePropertyDefaultInputDevice),
                                                 AudioObjectID(0)), micID != 0 else {
            throw RecorderError(message: "no default input device")
        }
        guard let micUID = getString(micID, addr(kAudioDevicePropertyDeviceUID)) else {
            throw RecorderError(message: "no mic UID")
        }
        let micChans = Int(streamConfig(micID, scope: kAudioObjectPropertyScopeInput).reduce(0, +))

        // 2. System-audio process tap (needs the System Audio Recording permission)
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.name = "nerdsidekiq system tap"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(tapDesc, &tap)
        guard tapErr == noErr, tap != kAudioObjectUnknown else {
            throw RecorderError(message: "process tap failed (\(tapErr)) — System Audio Recording permission?")
        }
        tapID = tap

        // 3. Private aggregate = mic + tap. No main sub-device: the tap keeps 48 kHz.
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey:      "nerdsidekiq aggregate",
            kAudioAggregateDeviceUIDKey:       UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDesc.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]
            ],
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: 1]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard aggErr == noErr, agg != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw RecorderError(message: "aggregate device failed (\(aggErr))")
        }
        aggID = agg

        aggRate = getProp(aggID, addr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 48000
        let inputBuffers = streamConfig(aggID, scope: kAudioObjectPropertyScopeInput)
        let micChannelCount = micChans
        let totalChannels = Int(inputBuffers.reduce(0, +))
        guard totalChannels - micChannelCount > 0 else {
            teardownDevices()
            throw RecorderError(message: "tap did not attach (buffers \(inputBuffers))")
        }

        // 4. Output file: raw float32le interleaved, L = mic, R = system.
        // Raw (headerless) PCM so live_loop.py can read the tail while we
        // are still writing — a WAV header only becomes valid on close.
        try? FileManager.default.removeItem(atPath: outPath)
        FileManager.default.createFile(atPath: outPath, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: outPath)) else {
            teardownDevices()
            throw RecorderError(message: "cannot open output file \(outPath)")
        }
        rawHandle = handle

        // 5. IO proc
        var pid: AudioDeviceIOProcID?
        let createErr = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let handle = self.rawHandle else { return }

            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            var channels: [(ptr: UnsafeMutablePointer<Float>, stride: Int)] = []
            var frames = 0
            for buffer in abl {
                guard let data = buffer.mData else { continue }
                let ch = Int(buffer.mNumberChannels)
                let f = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(ch, 1))
                frames = max(frames, f)
                let base = data.assumingMemoryBound(to: Float.self)
                for c in 0..<ch { channels.append((base.advanced(by: c), ch)) }
            }
            guard frames > 0, channels.count >= micChannelCount + 1 else { return }

            var interleaved = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                var m: Float = 0
                for c in 0..<micChannelCount { m += channels[c].ptr[i * channels[c].stride] }
                if micChannelCount > 0 { m /= Float(micChannelCount) }
                var s: Float = 0
                for c in micChannelCount..<channels.count { s += channels[c].ptr[i * channels[c].stride] }
                s /= Float(channels.count - micChannelCount)
                interleaved[2 * i] = m
                interleaved[2 * i + 1] = s
                self.micPeak = max(self.micPeak, abs(m))
                self.sysPeak = max(self.sysPeak, abs(s))
                self.micEnergy += Double(m * m)
                self.sysEnergy += Double(s * s)
            }
            self.framesSeen += frames
            let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
            try? handle.write(contentsOf: data)
        }
        guard createErr == noErr, let pid else {
            teardownDevices()
            throw RecorderError(message: "IO proc failed (\(createErr))")
        }
        procID = pid

        let startErr = AudioDeviceStart(aggID, pid)
        guard startErr == noErr else {
            AudioDeviceDestroyIOProcID(aggID, pid)
            procID = nil
            teardownDevices()
            throw RecorderError(message: "AudioDeviceStart failed (\(startErr))")
        }
        isRecording = true
    }

    func resetPeaks() { micPeak = 0; sysPeak = 0 }

    func stop() -> Stats {
        guard isRecording else { return Stats(frames: 0, sampleRate: aggRate, micRMS: 0, sysRMS: 0) }
        if let pid = procID {
            AudioDeviceStop(aggID, pid)
            AudioDeviceDestroyIOProcID(aggID, pid)
            procID = nil
        }
        teardownDevices()
        // Close the file after the IO queue drains.
        ioQueue.sync { }
        try? rawHandle?.close()
        rawHandle = nil
        isRecording = false
        let micRMS = framesSeen > 0 ? (micEnergy / Double(framesSeen)).squareRoot() : 0
        let sysRMS = framesSeen > 0 ? (sysEnergy / Double(framesSeen)).squareRoot() : 0
        return Stats(frames: framesSeen, sampleRate: aggRate, micRMS: micRMS, sysRMS: sysRMS)
    }

    private func teardownDevices() {
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }
}
