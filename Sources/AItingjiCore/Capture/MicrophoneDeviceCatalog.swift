import AVFoundation
import CoreAudio
import Foundation

public struct MicrophoneDeviceDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isBuiltIn: Bool
    public let isBluetooth: Bool

    public init(id: String, name: String, isBuiltIn: Bool, isBluetooth: Bool) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isBluetooth = isBluetooth
    }
}

public enum MicrophoneSelectionPolicy {
    public static func preferredDeviceID(
        devices: [MicrophoneDeviceDescriptor],
        persistedDeviceID: String?,
        systemDefaultDeviceID: String?,
        isBluetoothOutput: Bool
    ) -> String? {
        guard !devices.isEmpty else { return nil }

        if let persistedDeviceID,
           devices.contains(where: { $0.id == persistedDeviceID }) {
            return persistedDeviceID
        }
        if isBluetoothOutput,
           let builtIn = devices.first(where: \.isBuiltIn) {
            return builtIn.id
        }
        if let systemDefaultDeviceID,
           devices.contains(where: { $0.id == systemDefaultDeviceID }) {
            return systemDefaultDeviceID
        }
        return devices.first(where: \.isBuiltIn)?.id ?? devices[0].id
    }
}

public enum MicrophoneDeviceCatalog {
    private static let builtInTransportType: UInt32 = 0x626C746E // "bltn"
    private static let bluetoothTransportType: UInt32 = 0x626C7565 // "blue"

    public static func availableDevices() -> [MicrophoneDeviceDescriptor] {
        captureDevices().map { device in
            let transportType = UInt32(bitPattern: device.transportType)
            return MicrophoneDeviceDescriptor(
                id: device.uniqueID,
                name: device.localizedName,
                isBuiltIn: transportType == builtInTransportType,
                isBluetooth: transportType == bluetoothTransportType
            )
        }
    }

    public static func systemDefaultDeviceID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    public static func captureDevice(id: String) -> AVCaptureDevice? {
        captureDevices().first { $0.uniqueID == id }
    }

    public static func isBluetoothDefaultOutput() -> Bool {
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputDeviceID = AudioDeviceID(0)
        var outputDeviceIDSize = UInt32(MemoryLayout.size(ofValue: outputDeviceID))
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            0,
            nil,
            &outputDeviceIDSize,
            &outputDeviceID
        ) == noErr, outputDeviceID != 0 else {
            return false
        }

        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType = UInt32(0)
        var transportTypeSize = UInt32(MemoryLayout.size(ofValue: transportType))
        guard AudioObjectGetPropertyData(
            outputDeviceID,
            &transportAddress,
            0,
            nil,
            &transportTypeSize,
            &transportType
        ) == noErr else {
            return false
        }
        return transportType == bluetoothTransportType
    }

    private static func captureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}
