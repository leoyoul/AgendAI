import AItingjiCore
import Testing

private let builtInMicrophone = MicrophoneDeviceDescriptor(
    id: "built-in",
    name: "MacBook Pro麦克风",
    isBuiltIn: true,
    isBluetooth: false
)

private let bluetoothMicrophone = MicrophoneDeviceDescriptor(
    id: "bluetooth",
    name: "蓝牙耳机",
    isBuiltIn: false,
    isBluetooth: true
)

private let usbMicrophone = MicrophoneDeviceDescriptor(
    id: "usb",
    name: "USB 麦克风",
    isBuiltIn: false,
    isBluetooth: false
)

@Test
func persistedMicrophoneSelectionWinsWhenDeviceStillExists() {
    let selected = MicrophoneSelectionPolicy.preferredDeviceID(
        devices: [builtInMicrophone, bluetoothMicrophone],
        persistedDeviceID: bluetoothMicrophone.id,
        systemDefaultDeviceID: bluetoothMicrophone.id,
        isBluetoothOutput: true
    )

    #expect(selected == bluetoothMicrophone.id)
}

@Test
func bluetoothOutputDefaultsToBuiltInMicrophone() {
    let selected = MicrophoneSelectionPolicy.preferredDeviceID(
        devices: [bluetoothMicrophone, builtInMicrophone],
        persistedDeviceID: nil,
        systemDefaultDeviceID: bluetoothMicrophone.id,
        isBluetoothOutput: true
    )

    #expect(selected == builtInMicrophone.id)
}

@Test
func nonBluetoothOutputUsesSystemDefaultMicrophone() {
    let selected = MicrophoneSelectionPolicy.preferredDeviceID(
        devices: [builtInMicrophone, usbMicrophone],
        persistedDeviceID: nil,
        systemDefaultDeviceID: usbMicrophone.id,
        isBluetoothOutput: false
    )

    #expect(selected == usbMicrophone.id)
}

@Test
func missingPersistedMicrophoneFallsBackToBuiltInForBluetoothOutput() {
    let selected = MicrophoneSelectionPolicy.preferredDeviceID(
        devices: [bluetoothMicrophone, builtInMicrophone],
        persistedDeviceID: "disconnected",
        systemDefaultDeviceID: bluetoothMicrophone.id,
        isBluetoothOutput: true
    )

    #expect(selected == builtInMicrophone.id)
}

@Test
func microphoneSelectionReturnsNilWhenNoDeviceExists() {
    let selected = MicrophoneSelectionPolicy.preferredDeviceID(
        devices: [],
        persistedDeviceID: nil,
        systemDefaultDeviceID: nil,
        isBluetoothOutput: true
    )

    #expect(selected == nil)
}
