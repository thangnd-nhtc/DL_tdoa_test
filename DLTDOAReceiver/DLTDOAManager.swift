import Foundation
import Combine
import CoreLocation
import NearbyInteraction

enum DiscoveryChoice: String, CaseIterable, Identifiable {
    case bluetoothLowEnergy = "BLE (Default)"
    case wifi = "Wi-Fi (iOS 27+)"

    var id: String { rawValue }
}

@MainActor
final class DLTDOAManager: NSObject, ObservableObject {
    @Published var isSupported: Bool = false
    @Published var supportReason: String = "Checking device capabilities..."
    @Published var locationStatusText: String = "Unknown"
    @Published var isAuthorizedForLocation: Bool = false

    @Published var isRunning: Bool = false
    @Published var statusMessage: String = "Idle"
    @Published var logs: [String] = []

    @Published var networkIdentifierText: String = "42"
    @Published var discoveryChoice: DiscoveryChoice = .bluetoothLowEnergy

    @Published var observationsByAddress: [Int: AnchorObservation] = [:]
    @Published var solvedPosition: SolvedPosition?
    @Published var totalMeasurementsReceived: Int = 0

    private let locationManager = CLLocationManager()
    private var niSession: NISession?
    private var pendingStartAfterAuth = false

    override init() {
        super.init()
        locationManager.delegate = self
        refreshCapabilities()
        updateLocationStatus(locationManager.authorizationStatus)
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
        appendLog("Requesting When-In-Use location authorization...")
        locationManager.requestWhenInUseAuthorization()
    }

    func startSession() {
        guard isSupported else {
            statusMessage = "DL-TDoA unsupported on this device/OS."
            appendLog(statusMessage)
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
            appendLog(statusMessage)
            return
        }

        guard let netID = Int(networkIdentifierText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            statusMessage = "Invalid Network Identifier (must be integer, e.g. 42)"
            appendLog(statusMessage)
            return
        }

        stopSession()

        if #available(iOS 26.0, *) {
            let session = NISession()
            session.delegate = self
            self.niSession = session

            let config: NIDLTDOAConfiguration
            if #available(iOS 27.0, *) {
                let method: NIDLTDOAConfiguration.DiscoveryMethod =
                    (discoveryChoice == .wifi) ? .wifi : .bluetoothLowEnergy
                config = NIDLTDOAConfiguration(networkIdentifier: netID, discoveryMethod: method)
                appendLog("Starting NISession with networkIdentifier=\(netID), discovery=\(discoveryChoice.rawValue)")
            } else {
                config = NIDLTDOAConfiguration(networkIdentifier: netID)
                appendLog("Starting NISession with networkIdentifier=\(netID) (default BLE discovery)")
            }

            session.run(config)
            isRunning = true
            statusMessage = "Running (Network ID: \(netID)) — scanning for anchors..."
        }
    }

    func stopSession() {
        if niSession != nil {
            niSession?.invalidate()
            niSession = nil
            appendLog("NISession invalidated.")
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
        appendLog("Cleared measurements.")
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

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(text)"
        logs.insert(line, at: 0)
        if logs.count > 100 {
            logs.removeLast(logs.count - 100)
        }
    }
}

extension DLTDOAManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.updateLocationStatus(status)
            self.appendLog("Location authorization changed: \(self.locationStatusText)")
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

            var initiatorAddr: Int? = nil
            if #available(iOS 27.0, *) {
                initiatorAddr = m.clusterInitiatorAddress
            }

            let isRel = (m.coordinatesType == .relative)
            return AnchorObservation(
                address: m.address,
                clusterInitiatorAddress: initiatorAddr,
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
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.isRunning = false
            self.niSession = nil
            self.statusMessage = "Session invalidated: \(message)"
            self.appendLog("ERROR didInvalidateWith: \(message)")
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        Task { @MainActor in
            self.statusMessage = "Session suspended"
            self.appendLog("Session suspended.")
        }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        Task { @MainActor in
            self.appendLog("Session suspension ended.")
        }
    }
}
