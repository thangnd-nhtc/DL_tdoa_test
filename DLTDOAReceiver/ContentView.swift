import SwiftUI

struct ContentView: View {
    @StateObject private var manager = DLTDOAManager()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    controlsCard
                    positionCard
                    anchorsCard
                    logsCard
                }
                .padding()
            }
            .navigationTitle("DL-TDoA Receiver")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                manager.isSupported ? "UWB DL-TDoA Supported" : "DL-TDoA Unavailable",
                systemImage: manager.isSupported ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(manager.isSupported ? .green : .orange)

            Text(manager.supportReason)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Location Permission:")
                    .font(.subheadline)
                Spacer()
                Text(manager.locationStatusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(manager.isAuthorizedForLocation ? .green : .red)
            }

            if !manager.isAuthorizedForLocation {
                Button("Grant Location Permission") {
                    manager.requestLocationPermission()
                }
                .buttonStyle(.bordered)
            }

            Text("Status: \(manager.statusMessage)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Configuration")
                .font(.headline)

            HStack {
                Text("Network ID (Session ID)")
                Spacer()
                TextField("42", text: $manager.networkIdentifierText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .disabled(manager.isRunning)
            }

            Picker("Discovery", selection: $manager.discoveryChoice) {
                ForEach(DiscoveryChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(manager.isRunning)

            HStack(spacing: 12) {
                Button {
                    manager.startSession()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isRunning || !manager.isSupported)

                Button(role: .destructive) {
                    manager.stopSession()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!manager.isRunning)

                Button {
                    manager.clearMeasurements()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2D Position Estimate")
                .font(.headline)

            if let pos = manager.solvedPosition {
                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("X").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2f m", pos.x)).font(.title2.monospacedDigit().bold())
                    }
                    VStack(alignment: .leading) {
                        Text("Y").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2f m", pos.y)).font(.title2.monospacedDigit().bold())
                    }
                    VStack(alignment: .leading) {
                        Text("RMS Err").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2f m", pos.residualMeters)).font(.subheadline.monospacedDigit())
                    }
                }
                Text("Solved from \(pos.anchorCount) anchors (Ref: 0x\(String(pos.referenceAnchorAddress, radix: 16)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for >= 3 anchors with valid coordinates...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var anchorsCard: some View {
        let sorted = manager.observationsByAddress.values.sorted { $0.address < $1.address }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Anchors (\(sorted.count))")
                .font(.headline)

            if sorted.isEmpty {
                Text("No DL-TDoA measurements received yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sorted) { obs in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(String(format: "Anchor 0x%04X (%d)", obs.address, obs.address))
                                .font(.subheadline.bold().monospaced())
                            Spacer()
                            Text("\(obs.measurementTypeDescription) • \(String(format: "%.1f dBm", obs.signalStrength))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(String(format: "Coord (%@): (%.3f, %.3f, %.3f)",
                                    obs.isRelative ? "rel" : "geo",
                                    obs.position3D.x, obs.position3D.y, obs.position3D.z))
                            .font(.caption.monospacedDigit())
                        Text(String(format: "rx-tx: %.9f s", obs.elapsedTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostic Log")
                .font(.headline)
            if manager.logs.isEmpty {
                Text("No events yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.logs.prefix(15), id: \.self) { line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
