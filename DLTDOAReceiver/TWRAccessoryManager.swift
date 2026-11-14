import Foundation
import Combine
import CoreBluetooth
import NearbyInteraction

/// Qorvo QANI message transport. Requires compatible accessory firmware, not a plain UCI device.
@MainActor
final class TWRAccessoryManager: NSObject, ObservableObject {
    struct Accessory: Identifiable {
        let id: UUID
        let name: String
        fileprivate let peripheral: CBPeripheral
    }
    @Published private(set) var accessories: [Accessory] = []
    @Published private(set) var status = "Idle"
    @Published private(set) var isActive = false
    @Published private(set) var distance: Float?
    @Published private(set) var logs: [String] = []
    private static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let qorvoService = CBUUID(string: "2E938FD0-6A61-11ED-A1EB-0242AC120002")
    private var rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private var txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var session: NISession?
    private var configuration: NINearbyAccessoryConfiguration?
    private var timeout: Task<Void, Never>?
    private enum Phase { case idle, scanning, connecting, discovering, initializing, configuring, starting, ranging, stopping }
    private var phase: Phase = .idle

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    private func report(_ message: String) {
        status = message
        logs.append(message)
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }
    private func armTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.fail("Handshake timed out. Verify accessory firmware and QANI backend.")
        }
    }
    func scan() {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            report("Nearby Interaction ranging is not supported on this device."); return
        }
        guard central.state == .poweredOn else { report("Enable Bluetooth and grant Bluetooth permission in Settings."); return }
        guard phase == .idle else { report("Stop the current connection before scanning again."); return }
        accessories = []
        isActive = true
        phase = .scanning
        report("Scanning for Qorvo/NUS accessories…")
        central.scanForPeripherals(withServices: [Self.qorvoService, Self.nusService])
        armTimeout()
    }
    func connect(_ accessory: Accessory) {
        guard phase == .scanning else { return }
        central.stopScan()
        peripheral = accessory.peripheral
        peripheral?.delegate = self
        phase = .connecting
        report("Connecting to \(accessory.name)…")
        central.connect(accessory.peripheral)
        armTimeout()
    }
    func stop() {
        central.stopScan()
        timeout?.cancel()
        // Best effort: write ACK or peer 0x03 completes cleanup; disconnect timeout is bounded.
        if let peripheral, peripheral.state == .connected, writer != nil {
            phase = .stopping
            session?.delegate = nil
            session?.invalidate()
            session = nil
            if write(Data([0x0C])) {
                report("Stopping accessory…")
                armTimeout()
                return
            }
        }
        cleanup()
        report("Stopped")
    }
    private func cleanup() {
        timeout?.cancel()
        central.stopScan()
        session?.delegate = nil
        session?.invalidate()
        session = nil
        configuration = nil
        writer = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        distance = nil
        isActive = false
        phase = .idle
    }
    private func fail(_ message: String) { cleanup(); report(message) }
    @discardableResult private func write(_ data: Data) -> Bool {
        guard let peripheral, let writer, peripheral.state == .connected else { return false }
        guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            fail("QANI payload exceeds negotiated BLE write length; unsupported transport MTU."); return false
        }
        peripheral.writeValue(data, for: writer, type: .withResponse)
        return true
    }
}

extension TWRAccessoryManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            fail(central.state == .unauthorized ? "Bluetooth permission denied. Enable it in Settings." : "Bluetooth unavailable or powered off.")
        } else if !isActive { report("Bluetooth ready. Scan to select an accessory.") }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .scanning, !accessories.contains(where: { $0.id == peripheral.identifier }) else { return }
        accessories.append(Accessory(id: peripheral.identifier, name: peripheral.name ?? "Unnamed accessory", peripheral: peripheral))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        phase = .discovering
        report("Discovering QANI transport…")
        peripheral.discoverServices([Self.qorvoService, Self.nusService])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        fail("Connection failed: \(error?.localizedDescription ?? "unknown error")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        fail("Accessory disconnected: \(error?.localizedDescription ?? "connection closed")")
    }
}

extension TWRAccessoryManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.qorvoService }) ?? peripheral.services?.first(where: { $0.uuid == Self.nusService }) else { fail("QANI/NUS service not found."); return }
        if service.uuid == Self.qorvoService {
            rxUUID = CBUUID(string: "2E93998A-6A61-11ED-A1EB-0242AC120002")
            txUUID = CBUUID(string: "2E939AF2-6A61-11ED-A1EB-0242AC120002")
        } else {
            rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
            txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        }
        peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil,
              let rx = service.characteristics?.first(where: { $0.uuid == rxUUID }), rx.properties.contains(.write),
              let tx = service.characteristics?.first(where: { $0.uuid == txUUID }), tx.properties.contains(.notify) else {
            fail("Required writable RX / notifying TX characteristics are missing."); return
        }
        writer = rx
        peripheral.setNotifyValue(true, for: tx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == txUUID else { return }
        guard error == nil, characteristic.isNotifying else { fail("Could not subscribe to accessory notifications."); return }
        phase = .initializing
        report("Requesting real accessory configuration (0x0A)…")
        write(Data([0x0A]))
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error { fail("BLE write failed: \(error.localizedDescription)"); return }
        if phase == .stopping { cleanup(); report("Stopped (stop command acknowledged)") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == txUUID else { return }
        guard error == nil, let data = characteristic.value, let message = data.first else { fail("Invalid BLE notification."); return }
        switch message {
        case 0x01:
            guard phase == .initializing, data.count > 1 else { fail("Unexpected or empty accessory configuration."); return }
            do {
                let config = try NINearbyAccessoryConfiguration(data: Data(data.dropFirst()))
                let ni = NISession()
                ni.delegateQueue = .main
                ni.delegate = self
                session = ni
                configuration = config
                phase = .configuring
                report("Accessory configuration accepted; waiting for Apple shareable configuration…")
                ni.run(config)
                armTimeout()
            } catch { fail("Invalid accessory configuration: \(error.localizedDescription). Firmware must supply genuine QANI configuration.") }
        case 0x02:
            guard phase == .starting else { fail("Unexpected accessory start notification."); return }
            phase = .ranging
            timeout?.cancel()
            report("Accessory UWB session started; waiting for measurements…")
        case 0x03:
            cleanup()
            report("Accessory UWB session stopped")
        default:
            report("Ignored unknown QANI message 0x\(String(message, radix: 16))")
        }
    }
}

extension TWRAccessoryManager: NISessionDelegate {
    func session(_ session: NISession, didGenerateShareableConfigurationData shareableConfigurationData: Data, for object: NINearbyObject) {
        guard self.session === session, phase == .configuring,
              object.discoveryToken == configuration?.accessoryDiscoveryToken else { return }
        phase = .starting
        report("Sending Apple shareable configuration (0x0B)…")
        write(Data([0x0B]) + shareableConfigurationData)
        armTimeout()
    }
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard self.session === session, phase == .ranging,
              let object = nearbyObjects.first(where: { $0.discoveryToken == configuration?.accessoryDiscoveryToken }) else { return }
        distance = object.distance
    }
    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard self.session === session else { return }
        fail("Nearby Interaction invalidated: \(error.localizedDescription). Check Nearby Interaction permission in Settings.")
    }
    func sessionWasSuspended(_ session: NISession) {
        guard self.session === session else { return }
        stop()
    }
    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard self.session === session else { return }
        distance = nil
        stop()
    }
}
