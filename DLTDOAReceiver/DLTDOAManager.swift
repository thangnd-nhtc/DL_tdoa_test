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
        appendLog(.info, "OS: \(UIDevice.current.systemVersion)")
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

            let config: NIDLTDOAConfiguration
            if #available(iOS 27.0, *) {
                config = NIDLTDOAConfiguration(networkIdentifier: netID)
                appendLog(.info, "iOS 27+: DL-TDoA requires no entitlement (Apple documentation).")
            } else {
                config = NIDLTDOAConfiguration(networkIdentifier: netID)
                appendLog(.warning, "iOS 26: verify Apple DL-TDoA entitlement; BLE discovery is the default.")
            }
            appendLog(.info, "Requesting DL-TDoA NISession (networkID=\(netID), discovery=BLE)")

            session.run(config)
            isRunning = true
            statusMessage = "Session requested (Network ID: \(netID)) - waiting for DL-TDoA measurements"
        }
    }

    func stopSession() {
        if niSession != nil {
            niSession?.invalidate()
            niSession = nil
            appendLog(.warning, "NISession invalidated by user.")
        }
        isRunning = false
        if statusMessage.hasPrefix("Running") || statusMessage.hasPrefix("Session requested") {
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
            self.appendLog(.info, "Session suspension ended; restarting DL-TDoA with location authorization check.")
            self.startSession()
        }
    }
}
