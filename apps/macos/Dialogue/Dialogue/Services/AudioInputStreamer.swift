import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Foundation
import OSLog

/// Reliable audio input module backed by a Core Audio HAL Output Audio Unit.
///
/// Bypasses `AVAudioEngine` entirely, giving direct control over any input
/// device independent of system defaults, with deterministic format
/// negotiation and switching.
///
/// ## Usage
/// ```swift
/// let streamer = AudioInputStreamer()
/// try streamer.selectDevice(device)
/// let stream = try streamer.start(sampleRate: 16000)
/// for await buffer in stream {
///     processBuffer(buffer)
/// }
/// ```
///
/// ## Why HAL Output instead of AVAudioEngine?
/// `AVAudioEngine.inputNode` is internally bound to a single aggregate device.
/// Setting a different device via `audioUnit.setDeviceID` or
/// `AudioUnitSetProperty` is fragile, often requires aggregates, and doesn't
/// update formats/streams reliably without stopping/restarting the entire
/// engine. The HAL Output Audio Unit gives direct control over any input
/// device with deterministic format negotiation and switching.
///
/// Reference: https://developer.apple.com/library/archive/technotes/tn2091/_index.html
public final class AudioInputStreamer: @unchecked Sendable {

    // MARK: - Public Properties

    /// Publishes updated device lists when devices are added/removed.
    public let devicesPublisher = PassthroughSubject<[AudioDevice], Never>()

    /// The currently selected input device, if any.
    public private(set) var currentDevice: AudioDevice?

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "AudioInputStreamer")

    /// The HAL Output Audio Unit instance.
    private var audioUnit: AudioComponentInstance?

    /// Whether the audio unit is currently running (capturing audio).
    private var isRunning = false

    /// Whether the audio unit has been initialized with a valid format.
    /// Stays true across stop/start cycles; only reset on device change or deinit.
    private var isInitialized = false

    /// The continuation for the current AsyncStream, if active.
    private var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// The output format we deliver buffers in (mono Float32 at requested sample rate).
    private var outputFormat: AVAudioFormat?

    /// The device's native input format (channels, sample rate).
    private var deviceInputFormat: AudioStreamBasicDescription?

    /// AudioConverter for resampling/channel-mixing when the device's native
    /// format doesn't match our desired output format.
    private var audioConverter: AudioConverterRef?

    /// Number of input channels on the current device (for mono downmix).
    private var deviceChannelCount: UInt32 = 0

    /// Requested output sample rate.
    private var requestedSampleRate: Double = 16_000

    /// Buffer allocated for AudioUnitRender to fill.
    /// Uses AudioBufferList.allocate() for correct variable-size struct layout.
    private var renderBufferList: UnsafeMutableAudioBufferListPointer?
    /// Per-channel data backing pointers (one per channel, individually allocated).
    private var renderChannelDataPtrs: [UnsafeMutablePointer<Float>] = []
    /// Maximum frames the render buffers can hold.
    private var renderMaxFrames: UInt32 = 0

    /// Property listener blocks stored for removal.
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Serial queue for Core Audio callbacks.
    private let audioQueue = DispatchQueue(label: "bot.djinn.app.dialog.audio-input-streamer", qos: .userInteractive)

    // MARK: - Init / Deinit

    public init() {
        setupHALOutputUnit()
        setupDeviceListeners()
    }

    deinit {
        stop()
        teardownAudioUnit()
        removeDeviceListeners()
    }

    // MARK: - Device Enumeration

    /// List all available audio input devices.
    public func listInputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        )
        guard status == noErr else { return [] }

        var devices: [AudioDevice] = []
        for deviceID in deviceIDs {
            let inputChannels = Self.channelCount(for: deviceID, scope: kAudioObjectPropertyScopeInput)
            guard inputChannels > 0 else { continue }

            let name = Self.deviceName(for: deviceID) ?? "Unknown Device"
            let uid = Self.deviceUID(for: deviceID) ?? "\(deviceID)"
            devices.append(AudioDevice(
                audioDeviceID: deviceID,
                name: name,
                uid: uid,
                inputChannels: inputChannels
            ))
        }
        return devices
    }

    /// Returns the system default input device, if any.
    public func defaultInputDevice() -> AudioDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        let channels = Self.channelCount(for: deviceID, scope: kAudioObjectPropertyScopeInput)
        guard channels > 0 else { return nil }

        let name = Self.deviceName(for: deviceID) ?? "Default Input"
        let uid = Self.deviceUID(for: deviceID) ?? "\(deviceID)"
        return AudioDevice(
            audioDeviceID: deviceID,
            name: name,
            uid: uid,
            inputChannels: channels
        )
    }

    // MARK: - Device Selection

    /// Select a specific input device for capture.
    ///
    /// If the streamer is currently running, it stops, switches the device,
    /// re-negotiates the format, and restarts automatically.
    public func selectDevice(_ device: AudioDevice) throws {
        let wasRunning = isRunning

        // Full teardown: stop AU, uninitialize, destroy converter + buffers.
        // Device changes require complete re-negotiation.
        uninitializeAudioUnit()

        guard let au = audioUnit else {
            throw AudioInputStreamerError.audioUnitNotInitialized
        }

        // Set the device on the audio unit
        var deviceID = device.audioDeviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioInputStreamerError.deviceSelectionFailed(status)
        }

        currentDevice = device
        deviceChannelCount = UInt32(device.inputChannels)
        logger.info("Selected input device: \(device.name) (ID: \(device.audioDeviceID), channels: \(device.inputChannels))")

        // Re-negotiate format for the new device
        try negotiateFormat(on: au)

        if wasRunning {
            try startAudioUnit()
        }
    }

    // MARK: - Start / Stop

    /// Start capturing audio and return an `AsyncStream` of mono PCM buffers.
    ///
    /// Lightweight: if the audio unit is already initialized for the current
    /// device/format, this just creates a new stream and starts the AU.
    /// Full initialization only happens on first call or after a device change.
    ///
    /// - Parameter sampleRate: Desired output sample rate (default 16000 Hz).
    /// - Returns: A hot `AsyncStream<AVAudioPCMBuffer>` of mono Float32 buffers.
    public func start(sampleRate: Double = 16_000) throws -> AsyncStream<AVAudioPCMBuffer> {
        guard let au = audioUnit else {
            throw AudioInputStreamerError.audioUnitNotInitialized
        }

        // Stop any existing capture first (lightweight — no teardown)
        stopCapture()

        requestedSampleRate = sampleRate
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )

        // If no device selected yet, use the system default
        if currentDevice == nil {
            guard let defaultDevice = defaultInputDevice() else {
                throw AudioInputStreamerError.noInputDeviceAvailable
            }
            try selectDevice(defaultDevice)
        }

        // Initialize the AU + converter + buffers if not already done
        if !isInitialized {
            try negotiateFormat(on: au)
        }

        // Create the AsyncStream (no onTermination — caller manages stop)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.streamContinuation = continuation

        // Start the audio unit
        try startAudioUnit()

        logger.info("AudioInputStreamer started (sampleRate: \(sampleRate), device: \(self.currentDevice?.name ?? "unknown"))")
        return stream
    }

    /// Stop capturing audio.
    ///
    /// Lightweight: stops the AU and finishes the stream, but keeps the
    /// converter and render buffers intact so the next `start()` is fast.
    /// Full teardown only happens on device change (`selectDevice`) or deinit.
    public func stop() {
        stopCapture()
        logger.info("AudioInputStreamer stopped")
    }

    /// Stop the AU and finish the current stream without tearing down
    /// converter/buffers (lightweight stop for fast restart).
    private func stopCapture() {
        // Stop the audio unit first — this ensures no more callbacks fire.
        if isRunning, let au = audioUnit {
            AudioOutputUnitStop(au)
            isRunning = false
        }
        // Now safe to finish the stream — no callback can race with us.
        let continuation = streamContinuation
        streamContinuation = nil
        continuation?.finish()
    }

    // MARK: - HAL Output Unit Setup

    /// Create and configure the HAL Output Audio Unit for input capture.
    private func setupHALOutputUnit() {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("Failed to find HALOutput audio component")
            return
        }

        var au: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &au)
        guard status == noErr, let au else {
            logger.error("Failed to create HALOutput instance: OSStatus \(status)")
            return
        }

        // Enable input on bus 1 (input element)
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1, // bus 1 = input
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if status != noErr {
            logger.error("Failed to enable input IO: OSStatus \(status)")
        }

        // Disable output on bus 0 (we only want input, not playback)
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0, // bus 0 = output
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if status != noErr {
            logger.error("Failed to disable output IO: OSStatus \(status)")
        }

        self.audioUnit = au
        logger.info("HALOutput Audio Unit created")
    }

    // MARK: - Format Negotiation

    /// Negotiate the stream format between the device and our desired output.
    ///
    /// Reads the device's native input format, sets up the input callback,
    /// and creates an AudioConverter if resampling or channel mixing is needed.
    private func negotiateFormat(on au: AudioComponentInstance) throws {
        // Tear down old converter and buffers
        teardownConverter()
        teardownRenderBuffers()

        // Get the device's native input format (bus 1, input scope)
        var deviceASBD = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let getStatus = AudioUnitGetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1, // bus 1 = input element
            &deviceASBD,
            &size
        )
        guard getStatus == noErr else {
            throw AudioInputStreamerError.formatNegotiationFailed(getStatus)
        }

        deviceInputFormat = deviceASBD
        deviceChannelCount = deviceASBD.mChannelsPerFrame

        logger.info("Device native format: \(deviceASBD.mSampleRate) Hz, \(deviceASBD.mChannelsPerFrame) ch, formatID: \(deviceASBD.mFormatID)")

        // Set the output format of bus 1 (what we receive in the callback)
        // to the device's native format — we'll convert ourselves.
        // The HAL unit needs its output scope on bus 1 to match the device.
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: deviceASBD.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: deviceASBD.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var setStatus = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1, // bus 1
            &outputASBD,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard setStatus == noErr else {
            throw AudioInputStreamerError.formatNegotiationFailed(setStatus)
        }

        // Set up the input callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: Self.audioInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        setStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard setStatus == noErr else {
            throw AudioInputStreamerError.formatNegotiationFailed(setStatus)
        }

        // Allocate render buffers for AudioUnitRender
        let maxFrames: UInt32 = 4096
        allocateRenderBuffers(channelCount: deviceASBD.mChannelsPerFrame, maxFrames: maxFrames)

        // Set up AudioConverter if we need to resample.
        // Channel downmixing to mono is done manually in the input callback
        // BEFORE the converter, so the converter always receives mono input.
        let needsResample = deviceASBD.mSampleRate != requestedSampleRate
        if needsResample {
            try setupAudioConverter(inputSampleRate: deviceASBD.mSampleRate)
        }

        // Initialize the audio unit
        let initStatus = AudioUnitInitialize(au)
        guard initStatus == noErr else {
            throw AudioInputStreamerError.formatNegotiationFailed(initStatus)
        }

        isInitialized = true
        logger.info("Format negotiated: device \(deviceASBD.mSampleRate)Hz/\(deviceASBD.mChannelsPerFrame)ch -> output \(self.requestedSampleRate)Hz/1ch (resampler: \(needsResample))")
    }

    // MARK: - AudioConverter Setup

    /// Create an AudioConverter for mono-to-mono resampling.
    ///
    /// Channel downmixing is handled in the input callback before the
    /// converter, so both source and destination are always 1-channel.
    private func setupAudioConverter(inputSampleRate: Double) throws {
        var srcDesc = AudioStreamBasicDescription(
            mSampleRate: inputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var dstDesc = AudioStreamBasicDescription(
            mSampleRate: requestedSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&srcDesc, &dstDesc, &converter)
        guard status == noErr, let converter else {
            throw AudioInputStreamerError.converterCreationFailed(status)
        }

        self.audioConverter = converter
    }

    private func teardownConverter() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
    }

    // MARK: - Render Buffers

    /// Allocate the AudioBufferList used by AudioUnitRender.
    ///
    /// Uses `AudioBufferList.allocate(maximumBuffers:)` which correctly handles
    /// the variable-size AudioBufferList struct layout. Each channel gets its
    /// own individually allocated data buffer to avoid alignment issues.
    private func allocateRenderBuffers(channelCount: UInt32, maxFrames: UInt32) {
        teardownRenderBuffers()

        let channels = Int(channelCount)
        let frameSizeBytes = Int(maxFrames) * MemoryLayout<Float>.size

        // Use the proper Swift API for AudioBufferList allocation
        let abl = AudioBufferList.allocate(maximumBuffers: channels)
        abl.count = channels

        // Allocate separate data buffers per channel (avoids alignment/overlap issues)
        var dataPtrs: [UnsafeMutablePointer<Float>] = []
        for i in 0..<channels {
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFrames))
            ptr.initialize(repeating: 0, count: Int(maxFrames))
            dataPtrs.append(ptr)

            abl[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameSizeBytes),
                mData: UnsafeMutableRawPointer(ptr)
            )
        }

        self.renderBufferList = abl
        self.renderChannelDataPtrs = dataPtrs
        self.renderMaxFrames = maxFrames
    }

    private func teardownRenderBuffers() {
        for ptr in renderChannelDataPtrs {
            ptr.deallocate()
        }
        renderChannelDataPtrs.removeAll()

        if let abl = renderBufferList {
            // AudioBufferList.allocate returns UnsafeMutableAudioBufferListPointer
            // which must be freed via its unsafeMutablePointer
            abl.unsafeMutablePointer.deallocate()
        }
        renderBufferList = nil
        renderMaxFrames = 0
    }

    // MARK: - Audio Unit Start / Stop

    /// Start the audio unit (begin capturing audio from the device).
    private func startAudioUnit() throws {
        guard let au = audioUnit else {
            throw AudioInputStreamerError.audioUnitNotInitialized
        }
        guard !isRunning else { return }
        let status = AudioOutputUnitStart(au)
        guard status == noErr else {
            throw AudioInputStreamerError.startFailed(status)
        }
        isRunning = true
    }

    /// Uninitialize the audio unit and tear down converter + render buffers.
    /// Used when the device changes and we need a full re-negotiation.
    private func uninitializeAudioUnit() {
        // Stop capture first (lightweight)
        stopCapture()
        // Now do the heavy teardown
        if let au = audioUnit {
            AudioUnitUninitialize(au)
        }
        isInitialized = false
        teardownConverter()
        teardownRenderBuffers()
    }

    /// Dispose the audio unit entirely (only in deinit).
    private func teardownAudioUnit() {
        uninitializeAudioUnit()
        if let au = audioUnit {
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
    }

    // MARK: - Input Callback

    /// The C-function input callback invoked by the HAL Output Audio Unit
    /// when new audio data is available from the input device.
    private static let audioInputCallback: AURenderCallback = {
        (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in

        let streamer = Unmanaged<AudioInputStreamer>.fromOpaque(inRefCon).takeUnretainedValue()
        return streamer.handleInputBuffer(
            ioActionFlags: ioActionFlags,
            timeStamp: inTimeStamp,
            busNumber: inBusNumber,
            numberFrames: inNumberFrames
        )
    }

    /// Process an input buffer: pull audio from the device, downmix to mono,
    /// optionally resample, and push to the AsyncStream.
    private func handleInputBuffer(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        numberFrames: UInt32
    ) -> OSStatus {
        guard let au = audioUnit,
              let abl = renderBufferList else {
            return noErr
        }

        // Guard against frames exceeding our buffer capacity
        guard numberFrames <= renderMaxFrames else { return noErr }

        // Reset buffer sizes for this callback
        let frameSizeBytes = UInt32(numberFrames) * UInt32(MemoryLayout<Float>.size)
        for i in 0..<abl.count {
            abl[i].mDataByteSize = frameSizeBytes
        }

        // Pull audio data from the device
        let renderStatus = AudioUnitRender(
            au,
            ioActionFlags,
            timeStamp,
            1, // bus 1 = input
            numberFrames,
            abl.unsafeMutablePointer
        )
        guard renderStatus == noErr else {
            return renderStatus
        }

        let channels = Int(deviceChannelCount)
        let frames = Int(numberFrames)

        // Downmix to mono (simple average across channels)
        var monoSamples = [Float](repeating: 0, count: frames)
        if channels == 1 {
            // Single channel — direct copy
            if let channelData = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                monoSamples = Array(UnsafeBufferPointer(start: channelData, count: frames))
            }
        } else {
            for ch in 0..<channels {
                guard let channelData = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames {
                    monoSamples[frame] += channelData[frame]
                }
            }
            let scale = 1.0 / Float(channels)
            for frame in 0..<frames {
                monoSamples[frame] *= scale
            }
        }

        // If no converter needed, emit directly
        if audioConverter == nil {
            emitMonoBuffer(samples: monoSamples, sampleRate: deviceInputFormat?.mSampleRate ?? requestedSampleRate)
            return noErr
        }

        // Use AudioConverter for resampling
        convertAndEmit(monoSamples: monoSamples, inputSampleRate: deviceInputFormat?.mSampleRate ?? 48000, frameCount: frames)

        return noErr
    }

    // MARK: - Conversion

    /// Context passed to the AudioConverter's data supplier callback.
    private struct ConverterCallbackContext {
        var inputData: UnsafePointer<Float>
        var inputFrames: UInt32
        var consumed: Bool
    }

    /// Resample mono audio via AudioConverter and emit the result.
    private func convertAndEmit(monoSamples: [Float], inputSampleRate: Double, frameCount: Int) {
        guard let converter = audioConverter else { return }

        let outputFrameCount = Int(ceil(Double(frameCount) * requestedSampleRate / inputSampleRate))
        guard outputFrameCount > 0 else { return }

        var outputBuffer = [Float](repeating: 0, count: outputFrameCount)

        monoSamples.withUnsafeBufferPointer { inputPtr in
            guard let baseAddress = inputPtr.baseAddress else { return }

            var context = ConverterCallbackContext(
                inputData: baseAddress,
                inputFrames: UInt32(frameCount),
                consumed: false
            )

            var outputSize = UInt32(outputFrameCount)

            // Set up the output AudioBufferList
            var outputABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(outputFrameCount * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(mutating: nil)
                )
            )

            outputBuffer.withUnsafeMutableBufferPointer { outPtr in
                outputABL.mBuffers.mData = UnsafeMutableRawPointer(outPtr.baseAddress)

                let status = AudioConverterFillComplexBuffer(
                    converter,
                    { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                        guard let ctx = inUserData?.assumingMemoryBound(to: ConverterCallbackContext.self) else {
                            ioNumberDataPackets.pointee = 0
                            return -50 // paramErr
                        }

                        if ctx.pointee.consumed {
                            ioNumberDataPackets.pointee = 0
                            return 100 // no more data
                        }

                        ctx.pointee.consumed = true
                        ioNumberDataPackets.pointee = ctx.pointee.inputFrames

                        let bufList = UnsafeMutableAudioBufferListPointer(ioData)
                        bufList[0].mData = UnsafeMutableRawPointer(mutating: ctx.pointee.inputData)
                        bufList[0].mDataByteSize = ctx.pointee.inputFrames * UInt32(MemoryLayout<Float>.size)
                        bufList[0].mNumberChannels = 1

                        return noErr
                    },
                    &context,
                    &outputSize,
                    &outputABL,
                    nil
                )

                if status == noErr || status == 100 {
                    let actualFrames = Int(outputSize)
                    if actualFrames > 0 {
                        let slice = Array(outPtr.prefix(actualFrames))
                        emitMonoBuffer(samples: slice, sampleRate: requestedSampleRate)
                    }
                }
            }
        }
    }

    /// Create an AVAudioPCMBuffer from mono samples and push to the stream.
    private func emitMonoBuffer(samples: [Float], sampleRate: Double) {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let channelData = buffer.floatChannelData else { return }
        samples.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: samples.count)
        }

        streamContinuation?.yield(buffer)
    }

    // MARK: - Device Change Listeners

    /// Listen for device list changes and default device changes.
    private func setupDeviceListeners() {
        // Device list changes (add/remove devices)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let devices = self.listInputDevices()
            self.devicesPublisher.send(devices)
        }
        deviceListListenerBlock = devicesBlock

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            audioQueue,
            devicesBlock
        )

        // Default input device changes
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let devices = self.listInputDevices()
            self.devicesPublisher.send(devices)
        }
        defaultDeviceListenerBlock = defaultBlock

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            audioQueue,
            defaultBlock
        )
    }

    private func removeDeviceListeners() {
        if let block = deviceListListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioQueue,
                block
            )
            deviceListListenerBlock = nil
        }

        if let block = defaultDeviceListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioQueue,
                block
            )
            defaultDeviceListenerBlock = nil
        }
    }

    // MARK: - Static Helpers (Device Properties)

    private static func channelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer)
        guard status == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var totalChannels = 0
        for buffer in bufferList {
            totalChannels += Int(buffer.mNumberChannels)
        }
        return totalChannels
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name as String
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid as String
    }
}

// MARK: - Errors

public enum AudioInputStreamerError: Error, LocalizedError {
    case audioUnitNotInitialized
    case deviceSelectionFailed(OSStatus)
    case formatNegotiationFailed(OSStatus)
    case converterCreationFailed(OSStatus)
    case noInputDeviceAvailable
    case startFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .audioUnitNotInitialized:
            return "HAL Output Audio Unit not initialized"
        case .deviceSelectionFailed(let status):
            return "Failed to select input device: OSStatus \(status)"
        case .formatNegotiationFailed(let status):
            return "Format negotiation failed: OSStatus \(status)"
        case .converterCreationFailed(let status):
            return "AudioConverter creation failed: OSStatus \(status)"
        case .noInputDeviceAvailable:
            return "No input device available. Check System Settings > Sound > Input."
        case .startFailed(let status):
            return "Failed to start audio capture: OSStatus \(status)"
        }
    }
}
