import Foundation
import AudioToolbox
import CoreAudio
import AVFoundation

// nerdsidekiq — records the microphone and the system output at the same time,
// into one 2-channel WAV: L = you (mic), R = everybody else (system audio).
//
// Uses a Core Audio process tap + a private aggregate device, so the user's
// real input/output device selection is never touched.

// MARK: - Core Audio property helpers

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getProp<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ def: T) -> T? {
    var a = a
    var size = UInt32(MemoryLayout<T>.size)
    var value = def
    let err = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
    }
    return err == noErr ? value : nil
}

func getString(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
    var a = a
    var size = UInt32(MemoryLayout<CFString?>.size)
    var cf: CFString? = nil
    let err = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
    }
    guard err == noErr, let s = cf else { return nil }
    return s as String
}

func streamConfig(_ obj: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32] {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, raw) == noErr else { return [] }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.map { $0.mNumberChannels }
}

// MARK: - Arguments

var seconds: Double = 10
var outPath = FileManager.default.currentDirectoryPath + "/capture.wav"
var tapOnly = false      // diagnostic: aggregate contains the tap and nothing else
var publicTap = false    // diagnostic: non-private tap
var mainSub = "none"     // which sub-device drives the aggregate clock
var forceRate: Float64 = 0
var args = Array(CommandLine.arguments.dropFirst())
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--seconds", "-s": seconds = Double(args.removeFirst()) ?? 10
    case "--out", "-o":     outPath = args.removeFirst()
    case "--tap-only":      tapOnly = true
    case "--public-tap":    publicTap = true
    case "--main":          mainSub = args.removeFirst()   // mic | none
    case "--rate":          forceRate = Float64(args.removeFirst()) ?? 0
    default: FileHandle.standardError.write("unknown argument: \(flag)\n".data(using: .utf8)!)
    }
}
if !outPath.hasPrefix("/") { outPath = FileManager.default.currentDirectoryPath + "/" + outPath }

func log(_ s: String) {
    print(s)
    fflush(stdout)
}

func die(_ s: String) -> Never {
    FileHandle.standardError.write("ERROR: \(s)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 1. Microphone permission

let micSem = DispatchSemaphore(value: 0)
var micGranted = false
AVCaptureDevice.requestAccess(for: .audio) { ok in
    micGranted = ok
    micSem.signal()
}
micSem.wait()
guard micGranted else { die("microphone permission denied — System Settings > Privacy & Security > Microphone") }
log("[ok] microphone permission granted")

// MARK: - 2. Find the default input device (do NOT change it)

guard let micID: AudioObjectID = getProp(AudioObjectID(kAudioObjectSystemObject),
                                         addr(kAudioHardwarePropertyDefaultInputDevice),
                                         AudioObjectID(0)), micID != 0 else {
    die("no default input device")
}
guard let micUID = getString(micID, addr(kAudioDevicePropertyDeviceUID)) else { die("no mic UID") }
let micName = getString(micID, addr(kAudioObjectPropertyName)) ?? "?"
let micChans = streamConfig(micID, scope: kAudioObjectPropertyScopeInput).reduce(0, +)
let micRate: Float64 = getProp(micID, addr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
log("[ok] mic: \(micName) — \(micChans) ch @ \(Int(micRate)) Hz")

// MARK: - 3. Create the system-audio process tap

// Global tap: every process except this one. This is what needs the
// "System Audio Recording" (NSAudioCaptureUsageDescription) permission.
let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDesc.uuid = UUID()
tapDesc.name = "nerdsidekiq system tap"
tapDesc.isPrivate = !publicTap    // private = does not appear in other apps' device lists
tapDesc.muteBehavior = .unmuted   // you still hear the call normally

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapErr = AudioHardwareCreateProcessTap(tapDesc, &tapID)
guard tapErr == noErr, tapID != kAudioObjectUnknown else {
    die("AudioHardwareCreateProcessTap failed (\(tapErr)) — most likely the System Audio Recording permission was denied")
}
log("[ok] system audio tap created (id \(tapID), private=\(tapDesc.isPrivate))")

// Read the tap's own negotiated format. If the tap is dead this is empty.
var tapFmtAddr = addr(AudioObjectPropertySelector(kAudioTapPropertyFormat))
var tapFmt = AudioStreamBasicDescription()
var tapFmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
let tapFmtErr = AudioObjectGetPropertyData(tapID, &tapFmtAddr, 0, nil, &tapFmtSize, &tapFmt)
if tapFmtErr == noErr {
    log("[ok] tap format: \(Int(tapFmt.mSampleRate)) Hz, \(tapFmt.mChannelsPerFrame) ch, \(tapFmt.mBitsPerChannel) bit")
} else {
    log("[!!] could not read tap format (err \(tapFmtErr))")
}

// MARK: - 4. Private aggregate device = mic + tap, with drift correction

let aggUID = UUID().uuidString
var aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey:      "nerdsidekiq aggregate",
    kAudioAggregateDeviceUIDKey:       aggUID,
    kAudioAggregateDeviceIsPrivateKey: true,   // invisible to the user's device list
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: tapDesc.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]
    ],
]
if tapOnly {
    log("[dx] tap-only aggregate (microphone excluded)")
    aggDesc[kAudioAggregateDeviceSubDeviceListKey] = []
} else {
    // The tap runs at 48 kHz. A Bluetooth microphone runs at 24 kHz. If the mic
    // is made the clock master the aggregate drops to 24 kHz and the tap goes
    // silent, so by default no main sub-device is set and the tap keeps its rate.
    if mainSub == "mic" { aggDesc[kAudioAggregateDeviceMainSubDeviceKey] = micUID }
    aggDesc[kAudioAggregateDeviceSubDeviceListKey] = [
        [kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: 1]
    ]
}
log("[dx] main sub-device: \(mainSub)")

var aggID = AudioObjectID(kAudioObjectUnknown)
let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard aggErr == noErr, aggID != kAudioObjectUnknown else {
    AudioHardwareDestroyProcessTap(tapID)
    die("AudioHardwareCreateAggregateDevice failed (\(aggErr))")
}

func cleanup() {
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
}

if forceRate > 0 {
    var rateAddr = addr(kAudioDevicePropertyNominalSampleRate)
    var r = forceRate
    let e = AudioObjectSetPropertyData(aggID, &rateAddr, 0, nil,
                                       UInt32(MemoryLayout<Float64>.size), &r)
    log("[dx] force sample rate \(Int(forceRate)) -> err \(e)")
}
let aggRate: Float64 = getProp(aggID, addr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 48000
let inputBuffers = streamConfig(aggID, scope: kAudioObjectPropertyScopeInput)
log("[ok] aggregate device @ \(Int(aggRate)) Hz, input buffers: \(inputBuffers)")

// Channel map: the sub-device (mic) comes first, then the tap.
let micChannelCount = tapOnly ? 0 : Int(micChans)
let totalChannels = Int(inputBuffers.reduce(0, +))
let tapChannelCount = totalChannels - micChannelCount
guard tapChannelCount > 0 else {
    cleanup()
    die("aggregate device exposes no tap channels (got \(inputBuffers)) — the tap did not attach")
}
log("[ok] channel map: mic = 0..<\(micChannelCount), system = \(micChannelCount)..<\(totalChannels)")

// MARK: - 5. Output file: L = mic, R = system

let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                              sampleRate: aggRate,
                              channels: 2,
                              interleaved: false)!
let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: aggRate,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: false,
]
try? FileManager.default.removeItem(atPath: outPath)
guard let outFile = try? AVAudioFile(forWriting: URL(fileURLWithPath: outPath),
                                     settings: settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false) else {
    cleanup()
    die("cannot open output file \(outPath)")
}

// MARK: - 6. IO proc

let ioQueue = DispatchQueue(label: "nerdsidekiq.io")
var micPeak: Float = 0
var sysPeak: Float = 0
var micEnergy: Double = 0
var sysEnergy: Double = 0
var framesSeen: Int = 0

var procID: AudioDeviceIOProcID?
let createErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) {
    _, inInputData, _, _, _ in

    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

    // Flatten every input buffer into one channel list.
    var channels: [(ptr: UnsafeMutablePointer<Float>, stride: Int)] = []
    var frames = 0
    for buffer in abl {
        guard let data = buffer.mData else { continue }
        let ch = Int(buffer.mNumberChannels)
        let f = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(ch, 1))
        frames = max(frames, f)
        let base = data.assumingMemoryBound(to: Float.self)
        for c in 0..<ch {
            channels.append((base.advanced(by: c), ch))   // interleaved inside each buffer
        }
    }
    guard frames > 0, channels.count >= micChannelCount + 1 else { return }

    guard let pcm = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
    pcm.frameLength = AVAudioFrameCount(frames)
    let left = pcm.floatChannelData![0]   // mic
    let right = pcm.floatChannelData![1]  // system

    for i in 0..<frames {
        // mic: average of its channels
        var m: Float = 0
        for c in 0..<micChannelCount {
            m += channels[c].ptr[i * channels[c].stride]
        }
        if micChannelCount > 0 { m /= Float(micChannelCount) }

        // system: average of the tap channels
        var s: Float = 0
        for c in micChannelCount..<channels.count {
            s += channels[c].ptr[i * channels[c].stride]
        }
        s /= Float(channels.count - micChannelCount)

        left[i] = m
        right[i] = s
        micPeak = max(micPeak, abs(m))
        sysPeak = max(sysPeak, abs(s))
        micEnergy += Double(m * m)
        sysEnergy += Double(s * s)
    }
    framesSeen += frames
    try? outFile.write(from: pcm)
}
guard createErr == noErr, let procID else {
    cleanup()
    die("AudioDeviceCreateIOProcIDWithBlock failed (\(createErr))")
}

let startErr = AudioDeviceStart(aggID, procID)
guard startErr == noErr else {
    cleanup()
    die("AudioDeviceStart failed (\(startErr))")
}

log("[rec] recording \(seconds)s -> \(outPath)")

// Live level meter, one line per second.
var elapsed = 0.0
while elapsed < seconds {
    Thread.sleep(forTimeInterval: 1.0)
    elapsed += 1.0
    let mp = micPeak, sp = sysPeak
    micPeak = 0; sysPeak = 0
    func bar(_ v: Float) -> String {
        let n = min(20, Int(v * 40))
        return String(repeating: "#", count: n).padding(toLength: 20, withPad: ".", startingAt: 0)
    }
    log(String(format: "  t=%2.0fs  mic [%@] %.3f   sys [%@] %.3f", elapsed, bar(mp), mp, bar(sp), sp))
}

AudioDeviceStop(aggID, procID)
AudioDeviceDestroyIOProcID(aggID, procID)
cleanup()

let micRMS = framesSeen > 0 ? (micEnergy / Double(framesSeen)).squareRoot() : 0
let sysRMS = framesSeen > 0 ? (sysEnergy / Double(framesSeen)).squareRoot() : 0
log("")
log(String(format: "[done] %d frames (%.2fs) written to %@", framesSeen, Double(framesSeen) / aggRate, outPath))
log(String(format: "       mic RMS = %.5f    system RMS = %.5f", micRMS, sysRMS))
if micRMS < 0.0001 { log("       WARNING: microphone channel is silent") }
if sysRMS < 0.0001 { log("       WARNING: system audio channel is silent") }
