import AudioToolbox
@preconcurrency import AVFAudio
import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os.log

/// Captures all system audio output using Core Audio Taps (macOS 14.2+).
/// Delivers PCM16 24 kHz mono chunks suitable for OpenAI Realtime API.
nonisolated final class SystemAudioCapture: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.lstn2.app", category: "SystemAudioCapture")

    enum State: Equatable {
        case idle
        case capturing
        case error(String)
    }

    /// Called on the audio I/O thread with PCM16 24 kHz mono data (~100 ms per chunk).
    var onAudioChunk: ((Data) -> Void)?

    private let lock = NSLock()
    private var _state: State = .idle
    var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    // Core Audio objects
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?

    // Output format: PCM16 24 kHz mono (OpenAI Realtime API requirement)
    private static let targetSampleRate: Double = 24000
    private static let targetChannels: AVAudioChannelCount = 1

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: targetChannels,
        interleaved: true
    )!

    /// Check if system audio capture permission is already granted without triggering a prompt.
    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request system audio capture permission. Uses preflight check first to avoid
    /// unnecessary System Settings popups on rebuilds. Only triggers the macOS prompt
    /// when permission hasn't been granted yet.
    func requestPermission() async -> Bool {
        // Fast path: already granted — no prompt needed
        if CGPreflightScreenCaptureAccess() {
            Self.log.info("System audio capture permission already granted (preflight)")
            return true
        }

        // Not yet granted — request via CGRequestScreenCaptureAccess which shows
        // a proper system dialog pointing the user to System Settings.
        Self.log.info("Requesting screen capture access via system dialog")
        let requested = CGRequestScreenCaptureAccess()
        if requested {
            Self.log.info("System audio capture permission granted after request")
            return true
        }

        // Fall back to SCShareableContent which may also trigger a prompt
        do {
            _ = try await SCShareableContent.current
            Self.log.info("System audio capture permission granted via SCShareableContent")
            return true
        } catch {
            Self.log.error("System audio capture permission denied: \(error.localizedDescription)")
            return false
        }
    }

    func startCapture() throws {
        guard state != .capturing else { return }
        Self.log.info("Starting system audio capture via Core Audio Taps")
        state = .idle

        do {
            try setupTap()
            try setupAggregateDevice()
            try startAudioDevice()
            state = .capturing
            Self.log.info("System audio capture started")
        } catch {
            cleanup()
            let msg = error.localizedDescription
            state = .error(msg)
            Self.log.error("Failed to start system audio capture: \(msg)")
            throw error
        }
    }

    func stopCapture() {
        guard state == .capturing else { return }
        Self.log.info("Stopping system audio capture")
        cleanup()
        state = .idle
    }

    deinit {
        cleanup()
    }

    // MARK: - Setup

    private func setupTap() throws {
        // Global tap: capture all system audio, exclude our own process
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var ownObjectID = AudioObjectID(kAudioObjectUnknown)

        // Translate our PID to a Core Audio process object (best-effort; if it fails we still
        // create the tap — CATapDescription will just not exclude us, which is fine).
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ownPID
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let lookupErr = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid,
            &dataSize, &ownObjectID
        )

        let tapDescription: CATapDescription
        if lookupErr == noErr, ownObjectID != kAudioObjectUnknown {
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownObjectID])
        } else {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [])
        }
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.name = "LSTN2-system-tap"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else {
            throw SystemAudioError.tapCreationFailed(status)
        }
        tapID = newTapID
        Self.log.debug("Created process tap #\(newTapID)")

        // Read the tap's native audio format
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDesc = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(
            tapID, &formatAddress, 0, nil, &formatSize, &streamDesc
        )
        guard formatStatus == noErr,
              let srcFormat = AVAudioFormat(streamDescription: &streamDesc) else {
            throw SystemAudioError.formatReadFailed
        }
        tapFormat = srcFormat
        Self.log.info("Tap format: \(srcFormat.sampleRate) Hz, \(srcFormat.channelCount) ch")

        // Set up converter: tap's native format → PCM16 24 kHz mono
        guard let conv = AVAudioConverter(from: srcFormat, to: outputFormat) else {
            throw SystemAudioError.converterCreationFailed
        }
        converter = conv
    }

    private func setupAggregateDevice() throws {
        // Read the default system output device UID
        var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &size, &outputDeviceID
        )
        guard err == noErr else { throw SystemAudioError.defaultOutputReadFailed(err) }

        // Read the output device UID string
        propAddr.mSelector = kAudioDevicePropertyDeviceUID
        var outputUID: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        err = withUnsafeMutablePointer(to: &outputUID) { ptr in
            AudioObjectGetPropertyData(outputDeviceID, &propAddr, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw SystemAudioError.deviceUIDReadFailed(err) }

        // Read the tap's UID string
        var tapUIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapUID: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        err = withUnsafeMutablePointer(to: &tapUID) { ptr in
            AudioObjectGetPropertyData(tapID, &tapUIDAddr, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw SystemAudioError.tapUIDReadFailed(err) }

        // Create aggregate device that combines the output device and the tap
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LSTN2-aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID as String]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID as String,
                ]
            ],
        ]

        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)
        guard err == noErr else {
            throw SystemAudioError.aggregateDeviceCreationFailed(err)
        }
        aggregateDeviceID = newDeviceID
        Self.log.debug("Created aggregate device #\(newDeviceID)")
    }

    private func startAudioDevice() throws {
        guard tapFormat != nil else { throw SystemAudioError.formatReadFailed }

        var status = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            { (_, _, inInputData, _, _, _, inClientData) -> OSStatus in
                guard let inClientData else { return noErr }
                let capture = Unmanaged<SystemAudioCapture>.fromOpaque(inClientData)
                    .takeUnretainedValue()
                capture.handleAudioData(inInputData)
                return noErr
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &ioProcID
        )
        guard status == noErr else { throw SystemAudioError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else { throw SystemAudioError.deviceStartFailed(status) }
    }

    // MARK: - Audio Processing (called on I/O thread)

    private func handleAudioData(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let converter, let tapFormat, let onAudioChunk else { return }

        let bufferList = inputData.pointee
        let firstBuffer = bufferList.mBuffers
        guard firstBuffer.mData != nil, firstBuffer.mDataByteSize > 0 else { return }

        // Wrap the input data as an AVAudioPCMBuffer
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else { return }

        // Calculate output frame count based on sample rate ratio
        let ratio = Self.targetSampleRate / tapFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        // Convert: tap format → PCM16 24 kHz mono
        var error: NSError?
        nonisolated(unsafe) let sendableInputBuffer = inputBuffer
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return sendableInputBuffer
        }
        if error != nil { return }

        guard outputBuffer.frameLength > 0 else { return }

        // Extract raw PCM16 bytes
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: outputBuffer.int16ChannelData![0], count: byteCount)
        onAudioChunk(data)
    }

    // MARK: - Cleanup

    private func cleanup() {
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
        tapFormat = nil
    }
}

// MARK: - Audio Frame Tags
// Binary WebSocket frames are prefixed with a 1-byte tag to distinguish audio sources.
// The backend uses these tags to route audio to the correct transcription session.

enum AudioFrameTag: UInt8 {
    case system = 0x02
    case mic = 0x01
}

// MARK: - Mic Audio Capture (AVAudioEngine)

/// Captures microphone audio using AVAudioEngine.
/// Delivers PCM16 24 kHz mono chunks suitable for OpenAI Realtime API.
/// Unlike sounddevice in the Python backend, this runs in the Swift app process
/// and inherits the app's microphone TCC permission.
nonisolated final class MicAudioCapture: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.lstn2.app", category: "MicAudioCapture")

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var _isCapturing = false

    var isCapturing: Bool {
        get { lock.withLock { _isCapturing } }
        set { lock.withLock { _isCapturing = newValue } }
    }

    /// Called with PCM16 24 kHz mono data chunks.
    var onAudioChunk: ((Data) -> Void)?

    // Output format: PCM16 24 kHz mono (OpenAI Realtime API requirement)
    private static let targetSampleRate: Double = 24000
    private static let targetChannels: AVAudioChannelCount = 1

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: targetChannels,
        interleaved: true
    )!

    func startCapture() throws {
        guard !isCapturing else { return }
        Self.log.info("Starting mic audio capture via AVAudioEngine")

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicCaptureError.noInputAvailable
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicCaptureError.converterCreationFailed
        }

        Self.log.info("Mic input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")

        inputNode.installTap(onBus: 0, bufferSize: 4800, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        eng.prepare()
        try eng.start()

        lock.withLock {
            self.engine = eng
            self.converter = conv
            self._isCapturing = true
        }
        Self.log.info("Mic audio capture started")
    }

    func stopCapture() {
        let eng: AVAudioEngine? = lock.withLock {
            guard _isCapturing else { return nil }
            _isCapturing = false
            let e = engine
            engine = nil
            converter = nil
            return e
        }
        guard let eng else { return }
        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
        Self.log.info("Mic audio capture stopped")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = lock.withLock({ self.converter }),
              let onAudioChunk else { return }

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var error: NSError?
        nonisolated(unsafe) let inputBuffer = buffer
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if error != nil { return }
        guard outputBuffer.frameLength > 0 else { return }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: outputBuffer.int16ChannelData![0], count: byteCount)
        onAudioChunk(data)
    }

    deinit {
        stopCapture()
    }
}

nonisolated enum MicCaptureError: LocalizedError {
    case converterCreationFailed
    case noInputAvailable

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            "Failed to create audio format converter for microphone."
        case .noInputAvailable:
            "No microphone input available."
        }
    }
}

// MARK: - Errors

nonisolated enum SystemAudioError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case formatReadFailed
    case converterCreationFailed
    case defaultOutputReadFailed(OSStatus)
    case deviceUIDReadFailed(OSStatus)
    case tapUIDReadFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s):
            "Failed to create audio process tap (error \(s)). Check System Settings > Privacy & Security > Screen & System Audio Recording."
        case .formatReadFailed:
            "Failed to read audio tap format."
        case .converterCreationFailed:
            "Failed to create audio format converter."
        case .defaultOutputReadFailed(let s):
            "Failed to read default output device (error \(s))."
        case .deviceUIDReadFailed(let s):
            "Failed to read device UID (error \(s))."
        case .tapUIDReadFailed(let s):
            "Failed to read tap UID (error \(s))."
        case .aggregateDeviceCreationFailed(let s):
            "Failed to create aggregate audio device (error \(s))."
        case .ioProcCreationFailed(let s):
            "Failed to create audio I/O proc (error \(s))."
        case .deviceStartFailed(let s):
            "Failed to start audio device (error \(s))."
        }
    }
}
