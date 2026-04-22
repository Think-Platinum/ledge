import Foundation
import CoreAudio
import AudioToolbox
import CoreMediaIO
import os.log

/// Bridge to macOS CoreAudio for system volume and mute control.
///
/// Must be `nonisolated` — CoreAudio calls may block briefly.
nonisolated class SystemAudioBridge: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.ledge.app", category: "SystemAudio")
    private let debugLog = DebugLogger(category: "SystemAudio")

    struct AudioState: Sendable {
        var outputVolume: Float = 0     // 0.0 - 1.0
        var isOutputMuted: Bool = false
        var isInputMuted: Bool = false
        var inputVolume: Float = 0      // 0.0 - 1.0
        var isCameraInUse: Bool = false
        var cameraName: String?
    }

    /// Get the current audio state.
    func getState() -> AudioState {
        var state = AudioState()

        if let outputID = getDefaultDevice(forInput: false) {
            state.outputVolume = getVolume(deviceID: outputID, isInput: false)
            state.isOutputMuted = getMute(deviceID: outputID, isInput: false)
        }

        if let inputID = getDefaultDevice(forInput: true) {
            state.inputVolume = getVolume(deviceID: inputID, isInput: true)
            state.isInputMuted = getMute(deviceID: inputID, isInput: true)
        }

        let camera = getCameraInfo()
        state.isCameraInUse = camera.isInUse
        state.cameraName = camera.name

        return state
    }

    /// Set the system output volume (0.0 - 1.0).
    func setOutputVolume(_ volume: Float) {
        guard let deviceID = getDefaultDevice(forInput: false) else { return }
        setVolume(deviceID: deviceID, isInput: false, volume: max(0, min(1, volume)))
    }

    /// Toggle system output mute.
    func toggleOutputMute() {
        guard let deviceID = getDefaultDevice(forInput: false) else { return }
        let currentMute = getMute(deviceID: deviceID, isInput: false)
        setMute(deviceID: deviceID, isInput: false, muted: !currentMute)
    }

    /// Set system output mute state.
    func setOutputMute(_ muted: Bool) {
        guard let deviceID = getDefaultDevice(forInput: false) else { return }
        setMute(deviceID: deviceID, isInput: false, muted: muted)
    }

    /// Toggle system input (microphone) mute.
    func toggleInputMute() {
        guard let deviceID = getDefaultDevice(forInput: true) else { return }
        let currentMute = getMute(deviceID: deviceID, isInput: true)
        setMute(deviceID: deviceID, isInput: true, muted: !currentMute)
    }

    /// Set system input mute state.
    func setInputMute(_ muted: Bool) {
        guard let deviceID = getDefaultDevice(forInput: true) else { return }
        setMute(deviceID: deviceID, isInput: true, muted: muted)
    }

    /// Set the system input volume (0.0 - 1.0).
    func setInputVolume(_ volume: Float) {
        guard let deviceID = getDefaultDevice(forInput: true) else { return }
        setVolume(deviceID: deviceID, isInput: true, volume: max(0, min(1, volume)))
    }

    // MARK: - Camera Detection (CoreMediaIO)

    /// Check if any camera device is currently in use and return its name.
    private func getCameraInfo() -> (isInUse: Bool, name: String?) {
        var dataSize: UInt32 = 0
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &devicesAddress,
            0, nil,
            &dataSize
        ) == noErr else { return (false, nil) }

        let deviceCount = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard deviceCount > 0 else { return (false, nil) }

        var deviceIDs = [CMIOObjectID](repeating: 0, count: deviceCount)
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &devicesAddress,
            0, nil,
            dataSize,
            &dataSize,
            &deviceIDs
        ) == noErr else { return (false, nil) }

        for deviceID in deviceIDs {
            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )

            if CMIOObjectGetPropertyData(deviceID, &runningAddress, 0, nil, runningSize, &runningSize, &isRunning) == noErr,
               isRunning != 0 {
                // Camera is in use — get its name
                var nameAddress = CMIOObjectPropertyAddress(
                    mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
                )
                var name: Unmanaged<CFString>?
                var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

                if CMIOObjectGetPropertyData(deviceID, &nameAddress, 0, nil, nameSize, &nameSize, &name) == noErr,
                   let cfName = name?.takeUnretainedValue() {
                    return (true, cfName as String)
                }
                return (true, nil)
            }
        }

        return (false, nil)
    }

    // MARK: - Private CoreAudio Helpers

    private func getDefaultDevice(forInput: Bool) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: forInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioDeviceUnknown else {
            debugLog.debug("Failed to get default \(forInput ? "input" : "output") device: \(status)")
            return nil
        }
        return deviceID
    }

    private func getVolume(deviceID: AudioDeviceID, isInput: Bool) -> Float {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        if status != noErr {
            debugLog.debug("Failed to get volume: \(status)")
            return 0
        }
        return volume
    }

    private func setVolume(deviceID: AudioDeviceID, isInput: Bool, volume: Float) {
        var vol = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        if status != noErr {
            debugLog.debug("Failed to set volume: \(status)")
        }
    }

    private func getMute(deviceID: AudioDeviceID, isInput: Bool) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        if status != noErr {
            debugLog.debug("Failed to get mute state: \(status)")
            return false
        }
        return muted != 0
    }

    private func setMute(deviceID: AudioDeviceID, isInput: Bool, muted: Bool) {
        var muteValue: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muteValue)
        if status != noErr {
            debugLog.debug("Failed to set mute: \(status)")
        }
    }
}
