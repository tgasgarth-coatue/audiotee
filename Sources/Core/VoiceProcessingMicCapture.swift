import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio using the Voice Processing I/O Audio Unit.
/// This provides built-in Acoustic Echo Cancellation (AEC) - the same technology
/// used by FaceTime, Zoom, etc. to remove speaker audio from mic recordings.
///
/// How it works:
/// - Voice Processing I/O is an Audio Unit that handles both input (mic) and output (speakers)
/// - It internally knows what audio is being played to speakers
/// - It subtracts that audio from the mic input, removing echo/feedback
/// - Also provides automatic gain control and noise suppression
class VoiceProcessingMicCapture {
    private var audioUnit: AudioUnit?
    private var outputHandler: AudioOutputHandler
    private var targetSampleRate: Double
    private var chunkDuration: Double
    private var converter: AudioFormatConverter?
    private var chunkBuffer: AudioChunkBuffer?  // Renamed to avoid conflict with CoreAudio.AudioBuffer
    
    // Voice Processing I/O native format (usually 48kHz)
    private var inputFormat: AudioStreamBasicDescription?
    
    init(outputHandler: AudioOutputHandler, targetSampleRate: Double = 16000, chunkDuration: Double = 0.2) {
        self.outputHandler = outputHandler
        self.targetSampleRate = targetSampleRate
        self.chunkDuration = chunkDuration
    }
    
    deinit {
        stop()
    }
    
    func start() throws {
        Logger.info("Starting Voice Processing mic capture with AEC...")
        
        // Find the Voice Processing I/O Audio Unit
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,  // Key: This has AEC built-in!
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw AudioTeeError.setupFailed
        }
        
        var status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let audioUnit = audioUnit else {
            Logger.error("Failed to create Voice Processing audio unit", context: ["status": String(status)])
            throw AudioTeeError.setupFailed
        }
        
        // Enable input (mic) on the Voice Processing I/O
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,  // Input element
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            Logger.error("Failed to enable mic input", context: ["status": String(status)])
            throw AudioTeeError.setupFailed
        }
        
        // Disable output (we don't want to play audio, just capture)
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,  // Output element
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            Logger.error("Failed to disable speaker output", context: ["status": String(status)])
            throw AudioTeeError.setupFailed
        }
        
        // Get the input format (what the mic provides after voice processing)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var inputStreamFormat = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,  // Output of input element = processed mic audio
            1,  // Input element
            &inputStreamFormat,
            &formatSize
        )
        guard status == noErr else {
            Logger.error("Failed to get input format", context: ["status": String(status)])
            throw AudioTeeError.setupFailed
        }
        
        self.inputFormat = inputStreamFormat
        Logger.info("Voice Processing input format", context: [
            "sample_rate": String(inputStreamFormat.mSampleRate),
            "channels": String(inputStreamFormat.mChannelsPerFrame),
            "bits": String(inputStreamFormat.mBitsPerChannel)
        ])
        
        // Set up format for our callback (mono Float32 at native rate)
        var monoFormat = AudioStreamBasicDescription(
            mSampleRate: inputStreamFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,  // Input element
            &monoFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            Logger.error("Failed to set output format for input element", context: ["status": String(status)])
            throw AudioTeeError.setupFailed
        }
        
        // Set up the render callback to receive processed mic audio
        var callbackStruct = AURenderCallbackStruct(
            inputProc: micInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            Logger.error("Failed to set input callback", context: ["status": String(status)])
            throw AudioTeeError.setupFailed
        }
        
        // Set up converter if we need to change sample rate
        self.chunkBuffer = AudioChunkBuffer(format: monoFormat, chunkDuration: chunkDuration)
        
        if targetSampleRate != monoFormat.mSampleRate {
            do {
                self.converter = try AudioFormatConverter.toSampleRate(targetSampleRate, from: monoFormat)
                Logger.info("Will convert to", context: ["sample_rate": String(targetSampleRate)])
            } catch {
                Logger.error("Failed to create converter", context: ["error": String(describing: error)])
            }
        }
        
        // Initialize and start the audio unit
        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            Logger.error("Failed to initialize audio unit", context: ["status": String(status)])
            throw AudioTeeError.setupFailed
        }
        
        // Send metadata before starting
        let finalFormat = converter?.targetFormatDescription ?? monoFormat
        let metadata = AudioStreamMetadata(
            sampleRate: finalFormat.mSampleRate,
            channelsPerFrame: finalFormat.mChannelsPerFrame,
            bitsPerChannel: finalFormat.mBitsPerChannel,
            isFloat: (finalFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            captureMode: "voice_processing_mic",
            deviceName: "Voice Processing I/O (AEC)",
            deviceUID: nil,
            encoding: "pcm_s16le"
        )
        outputHandler.handleMetadata(metadata)
        outputHandler.handleStreamStart()
        
        status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            Logger.error("Failed to start audio unit", context: ["status": String(status)])
            throw AudioTeeError.setupFailed
        }
        
        Logger.info("Voice Processing mic capture started with AEC enabled")
    }
    
    func stop() {
        if let audioUnit = audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
        }
        outputHandler.handleStreamStop()
        Logger.info("Voice Processing mic capture stopped")
    }
    
    /// Get the audio unit reference (for use in callback)
    func getAudioUnit() -> AudioUnit? {
        return audioUnit
    }
    
    /// Called when we receive processed (echo-cancelled) mic audio
    fileprivate func handleMicAudio(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let buffer = bufferList.pointee.mBuffers
        guard let data = buffer.mData else { return }
        
        let audioData = Data(bytes: data, count: Int(buffer.mDataByteSize))
        chunkBuffer?.append(audioData)
        
        // Process complete chunks
        chunkBuffer?.processChunks().forEach { packet in
            let processedPacket = converter?.transform(packet) ?? packet
            outputHandler.handleAudioPacket(processedPacket)
        }
    }
}

/// Callback function for receiving processed mic audio
private func micInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<VoiceProcessingMicCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    
    guard let audioUnit = capture.getAudioUnit() else {
        return noErr
    }
    
    // Allocate buffer for the audio data
    let bufferSize = inNumberFrames * 4  // Float32 mono
    let bufferData = malloc(Int(bufferSize))
    
    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: CoreAudio.AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: bufferSize,
            mData: bufferData
        )
    )
    
    // Render the processed mic audio
    let status = AudioUnitRender(
        audioUnit,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        &bufferList
    )
    
    if status == noErr {
        capture.handleMicAudio(&bufferList, frameCount: inNumberFrames)
    }
    
    free(bufferData)
    return status
}

