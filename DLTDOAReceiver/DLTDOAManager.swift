import Foundation
import Combine
import CoreLocation
import NearbyInteraction
import UIKit

enum LogLevel: String, CaseIterable {
    case info = "INFO"
    case success = "OK"
    case packet = "PKT"
    case warning = "WARN"
    case error = "ERR"
}

struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var timeString: String {
        Self.formatter.string(from: timestamp)
    }

    var formattedLine: String {
        "[\(timeString)] [\(level.rawValue)] \(message)"
    }
}

@MainActor
final class DLTDOAManager: NSObject, ObservableObject {
    @Published var isSupported: Bool = false
    @Published var supportReason: String = "Checking device capabilities..."
    @Published var locationStatusText: String = "Unknown"
    @Published var isAuthorizedForLocation: Bool = false

    @Published var isRunning: Bool = false
    @Published var statusMessage: String = "Idle"
    @Published var logs: [LogEntry] = []
    @Published var logRawPackets: Bool = true

    @Published var networkIdentifierText: String = "42"

    @Published var observationsByAddress: [Int: AnchorObservation] = [:]
    @Published var solvedPosition: SolvedPosition?
    @Published var totalMeasurementsReceived: Int = 0

    private let locationManager = CLLocationManager()
    private var niSession: NISession?
    private var pendingStartAfterAuth = false
    private var lastPacketLogTime: Date = .distantPast

    override init() {
        super.init()
        locationManager.delegate = self
        refreshCapabilities()
        updateLocationStatus(locationManager.authorizationStatus)
        appendLog(.info, "App initialized. \(supportReason)")
    }

    func refreshCapabilities() {
        if #available(iOS 26.0, *) {
            let cap = NISession.deviceCapabilities
            isSupported = cap.supportsDLTDOAMeasurement
            supportReason = isSupported
                ? "Device supports DL-TDoA (UWB)"
                : "This iPhone / OS does not report supportsDLTDOAMeasurement"
        } else {
            isSupported = false
            supportReason = "Requires iOS 26.0 or later for NIDLTDOAConfiguration"
        }
    }

    func requestLocationPermission() {
        appendLog(.info, "Requesting When-In-Use location authorization...")
        locationManager.requestWhenInUseAuthorization()
    }

    func startSession() {
        guard isSupported else {
            statusMessage = "DL-TDoA unsupported on this device/OS."
            appendLog(.error, statusMessage)
            return
        }

        let auth = locationManager.authorizationStatus
        if auth == .notDetermined {
            pendingStartAfterAuth = true
            statusMessage = "Waiting for location authorization..."
            requestLocationPermission()
            return
        }

        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else {
            statusMessage = "Location authorization denied. Enable in Settings."
            appendLog(.error, statusMessage)
            return
        }

        guard let netID = Int(networkIdentifierText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            statusMessage = "Invalid Network Identifier (must be integer, e.g. 42)"
            appendLog(.error, statusMessage)
            return
        }

        stopSession()

        if #available(iOS 26.0, *) {
            let session = NISession()
            session.delegate = self
            self.niSession = session

            let config = NIDLTDOAConfiguration(networkIdentifier: netID)
            appendLog(.success, "Starting NISession (networkID=\(netID), discovery=BLE)")

            session.run(config)
            isRunning = true
            statusMessage = "Running (Network ID: \(netID)) — scanning for anchors..."
        }
    }

    func startExperimentalOOBHexSession() {
        let auth = locationManager.authorizationStatus
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else {
            statusMessage = "Location authorization required."
            appendLog(.error, statusMessage)
            return
        }

        let netID = UInt32(max(0, Int(networkIdentifierText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 42))
        stopSession()

        // Build FiRa OOB-style TLV frame matching test_3anchors_1tag.py (session=netID, ch=9, preamble=10, slot=2400, interval=200ms, slots=25)
        var bytes: [UInt8] = [
            0x01, 0x00, 0x00, 0x00,             // FiRa OOB v1.0, Vendor 0x0000
            0x00, 0x04,                         // Session ID (LE)
            UInt8(netID & 0xFF),
            UInt8((netID >> 8) & 0xFF),
            UInt8((netID >> 16) & 0xFF),
            UInt8((netID >> 24) & 0xFF),
            0x01, 0x01, 0x08,                   // Device Role: 0x08 (DT-Tag)
            0x02, 0x01, 0x05,                   // Ranging Round Usage: 0x05 (DL-TDoA)
            0x03, 0x01, 0x01,                   // Multi-Node Mode: 0x01 (One-to-Many)
            0x04, 0x01, 0x09,                   // Channel: 9
            0x14, 0x01, 0x0A,                   // Preamble Code Index: 10
            0x08, 0x02, 0x60, 0x09,             // Slot Duration: 2400 RSTU (2ms)
            0x09, 0x04, 0xC8, 0x00, 0x00, 0x00, // Ranging Interval: 200ms
            0x1B, 0x01, 0x19,                   // Slots Per Ranging Round: 25 (0x19)
            0x05, 0x01, 0x00,                   // STS Config: 0x00 (Static STS)
            0x07, 0x02, 0xA1, 0x00              // Anchor MAC: 00:a1 (LE)
        ]
        let oobData = Data(bytes)
        let hexStr = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        appendLog(.info, "Testing NINearbyAccessoryConfiguration(data:) (\(oobData.count)B): \(hexStr)")

        do {
            let config = try NINearbyAccessoryConfiguration(data: oobData)
            let session = NISession()
            session.delegate = self
            self.niSession = session
            session.run(config)
            isRunning = true
            statusMessage = "Running Experimental OOB Hex..."
            appendLog(.success, "NINearbyAccessoryConfiguration accepted payload! Running NISession...")
        } catch {
            let nsErr = error as NSError
            statusMessage = "OOB Hex rejected: \(nsErr.localizedDescription)"
            appendLog(.error, "NINearbyAccessoryConfiguration rejected payload [\(nsErr.domain):\(nsErr.code)]: \(nsErr.localizedDescription)")
        }
    }

    func startExperimentalTWRAccessorySession() {
        let auth = locationManager.authorizationStatus
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else {
            statusMessage = "Location authorization required."
            appendLog(.error, statusMessage)
            return
        }

        stopSession()

        // Apple NI Accessory Protocol Release R2 AccessoryConfigurationData (49 bytes total)
        let r2Bytes: [UInt8] = [
            0x01, 0x00,                         // Major Version = 1
            0x00, 0x00,                         // Minor Version = 0
            0x14,                               // Preferred Update Rate = 20 (User Interactive per Release-R2 Table 3-3)
            0x00, 0x00, 0x00, 0x00, 0x00,       // RFU (10 bytes)
            0x00, 0x00, 0x00, 0x00, 0x00,
            0x21,                               // UWB Config Data Length = 33 bytes
            // UWB Config Data (33 bytes)
            0x01, 0x00,                         // uwb_spec_ver_major
            0x01, 0x00,                         // uwb_spec_ver_minor
            0x42, 0x01, 0x00, 0x00,             // manufacturer_id
            0x01, 0x00, 0x00, 0x00,             // model_id
            0x00, 0x00, 0x00, 0x00,             // mw_version
            0x00,                               // ranging_role (0 = Responder)
            0xA1, 0x00,                         // device_mac_address (00:a1)
            0x19, 0x00,                         // clock_drift (25 ppm)
            0x03,                               // supported_device_roles
            0x02,                               // supported_ranging_methods (DS-TWR)
            0x01,                               // supported_sts_config (Static STS)
            0x03,                               // supported_multinode_modes
            0x01,                               // supported_hopping_modes
            0x01,                               // supported_tof_report
            0x01,                               // supported_aoa_azimuth
            0x01,                               // supported_aoa_elevation
            0x01,                               // supported_aoa_fom
            0x02,                               // supported_channel_number (Ch 9)
            0x00,                               // supported_uwb_initiation_time
            0x0A                                // supported_preamble_code_index (10)
        ]
        let configData = Data(r2Bytes)
        appendLog(.info, "Testing Release-R2 TWR AccessoryConfigurationData (\(configData.count)B)...")

        do {
            let config = try NINearbyAccessoryConfiguration(data: configData)
            let session = NISession()
            session.delegate = self
            self.niSession = session
            session.run(config)
            isRunning = true
            statusMessage = "Running R2 TWR Config — listening for UWB..."
            appendLog(.success, "NINearbyAccessoryConfiguration(R2) accepted! Listening for nearbyObjects / DLTDOA...")
        } catch {
            let nsErr = error as NSError
            statusMessage = "R2 Config rejected: \(nsErr.localizedDescription)"
            appendLog(.error, "NINearbyAccessoryConfiguration(R2) rejected [\(nsErr.domain):\(nsErr.code)]: \(nsErr.localizedDescription)")
        }
    }

    func stopSession() {
        if niSession != nil {
            niSession?.invalidate()
            niSession = nil
            appendLog(.warning, "NISession invalidated by user.")
        }
        isRunning = false
        if statusMessage.hasPrefix("Running") {
            statusMessage = "Stopped"
        }
    }

    func clearMeasurements() {
        observationsByAddress.removeAll()
        solvedPosition = nil
        totalMeasurementsReceived = 0
        appendLog(.info, "Cleared anchor measurements.")
    }

    func clearLogs() {
        logs.removeAll()
    }

    func copyLogsToClipboard() {
        let text = logs.map(\.formattedLine).joined(separator: "\n")
        UIPasteboard.general.string = text
        appendLog(.info, "Copied \(logs.count) log lines to clipboard.")
    }

    private func updateLocationStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            locationStatusText = "Not Determined"
            isAuthorizedForLocation = false
        case .restricted:
            locationStatusText = "Restricted"
            isAuthorizedForLocation = false
        case .denied:
            locationStatusText = "Denied"
            isAuthorizedForLocation = false
        case .authorizedWhenInUse:
            locationStatusText = "Authorized (When In Use)"
            isAuthorizedForLocation = true
        case .authorizedAlways:
            locationStatusText = "Authorized (Always)"
            isAuthorizedForLocation = true
        @unknown default:
            locationStatusText = "Unknown (\(status.rawValue))"
            isAuthorizedForLocation = false
        }
    }

    private func appendLog(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        logs.insert(entry, at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
    }
}

extension DLTDOAManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.updateLocationStatus(status)
            self.appendLog(self.isAuthorizedForLocation ? .success : .warning,
                           "Location authorization: \(self.locationStatusText)")
            if self.pendingStartAfterAuth {
                self.pendingStartAfterAuth = false
                if self.isAuthorizedForLocation {
                    self.startSession()
                } else {
                    self.statusMessage = "Location authorization required for DL-TDoA."
                }
            }
        }
    }
}

extension DLTDOAManager: NISessionDelegate {
    @available(iOS 26.0, *)
    nonisolated func session(_ session: NISession, didUpdateDLTDOA measurements: [NIDLTDOAMeasurement]) {
        let now = Date()
        let parsed: [AnchorObservation] = measurements.map { m in
            let typeDesc: String
            switch m.measurementType {
            case .poll: typeDesc = "poll"
            case .response: typeDesc = "response"
            case .final: typeDesc = "final"
            @unknown default: typeDesc = "unknown(\(m.measurementType.rawValue))"
            }

            let isRel = (m.coordinatesType == .relative)
            return AnchorObservation(
                address: m.address,
                clusterInitiatorAddress: nil,
                position2D: SIMD2<Double>(m.coordinates.x, m.coordinates.y),
                position3D: m.coordinates,
                isRelative: isRel,
                receiveTime: m.receiveTime,
                transmitTime: m.transmitTime,
                signalStrength: m.signalStrength,
                measurementTypeDescription: typeDesc,
                updatedAt: now
            )
        }

        Task { @MainActor in
            self.totalMeasurementsReceived += parsed.count
            for obs in parsed {
                self.observationsByAddress[obs.address] = obs
            }
            let allObs = Array(self.observationsByAddress.values)
            self.solvedPosition = DLTDOASolver.solve2D(observations: allObs)
            self.statusMessage = "Receiving DL-TDoA (\(allObs.count) anchors, \(self.totalMeasurementsReceived) msgs)"

            if self.logRawPackets && now.timeIntervalSince(self.lastPacketLogTime) >= 0.5 {
                self.lastPacketLogTime = now
                let summary = parsed.map {
                    String(format: "0x%04X(%@, %.1fdBm, dt=%.6fs)",
                           $0.address, $0.measurementTypeDescription, $0.signalStrength, $0.elapsedTime)
                }.joined(separator: " | ")
                self.appendLog(.packet, "Rx \(parsed.count): \(summary)")
            }
        }
    }

    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        let summary = nearbyObjects.map { obj in
            let dist = obj.distance.map { String(format: "%.2fm", $0) } ?? "nil"
            return "dist=\(dist)"
        }.joined(separator: ", ")
        Task { @MainActor in
            self.appendLog(.packet, "didUpdate nearbyObjects (\(nearbyObjects.count)): \(summary)")
        }
    }

    nonisolated func session(_ session: NISession, didGenerateShareableConfigurationData shareableConfigurationData: Data, for object: NINearbyObject) {
        let hex = shareableConfigurationData.map { String(format: "%02X", $0) }.joined(separator: " ")
        Task { @MainActor in
            self.appendLog(.info, "Generated shareableConfigData (\(shareableConfigurationData.count)B): \(hex)")
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        let nsErr = error as NSError
        let message = "\(error.localizedDescription) [\(nsErr.domain):\(nsErr.code)]"
        Task { @MainActor in
            self.isRunning = false
            self.niSession = nil
            self.statusMessage = "Session invalidated: \(error.localizedDescription)"
            self.appendLog(.error, "didInvalidateWith: \(message)")
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        Task { @MainActor in
            self.statusMessage = "Session suspended"
            self.appendLog(.warning, "Session suspended by system.")
        }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        Task { @MainActor in
            self.appendLog(.info, "Session suspension ended.")
        }
    }
}
