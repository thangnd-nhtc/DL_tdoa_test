import SwiftUI

enum LogFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case packets = "PKT"
    case errors = "ERR"

    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var manager = DLTDOAManager()
    @State private var logFilter: LogFilter = .all

    private var filteredLogs: [LogEntry] {
        switch logFilter {
        case .all:
            return manager.logs
        case .packets:
            return manager.logs.filter { $0.level == .packet }
        case .errors:
            return manager.logs.filter { $0.level == .error || $0.level == .warning }
        }
    }

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
            .background(Color(.systemGroupedBackground))
            .navigationTitle("DL-TDoA Receiver")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(manager.isRunning ? Color.green : Color.gray.opacity(0.5))
                            .frame(width: 9, height: 9)
                        Text(manager.isRunning ? "LIVE" : "IDLE")
                            .font(.caption.bold().monospaced())
                            .foregroundStyle(manager.isRunning ? .green : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                }
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    manager.isSupported ? "UWB DL-TDoA Supported" : "DL-TDoA Unavailable",
                    systemImage: manager.isSupported ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(manager.isSupported ? .green : .orange)
                Spacer()
            }

            Text(manager.supportReason)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Location Permission")
                    .font(.subheadline)
                Spacer()
                Text(manager.locationStatusText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (manager.isAuthorizedForLocation ? Color.green : Color.red).opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(manager.isAuthorizedForLocation ? .green : .red)
            }

            if !manager.isAuthorizedForLocation {
                Button("Grant Location Permission") {
                    manager.requestLocationPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                Text(manager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Configuration")
                .font(.headline)

            HStack {
                Text("Network ID (Session ID)")
                    .font(.subheadline)
                Spacer()
                TextField("42", text: $manager.networkIdentifierText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .disabled(manager.isRunning)
            }

            HStack {
                Text("Discovery")
                    .font(.subheadline)
                Spacer()
                Text("BLE (iOS 26)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
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
                .accessibilityLabel("Clear measurements")
            }

            HStack(spacing: 8) {
                Button {
                    manager.startExperimentalOOBHexSession()
                } label: {
                    Label("Test FiRa OOB", systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
                .disabled(manager.isRunning)

                Button {
                    manager.startExperimentalTWRAccessorySession()
                } label: {
                    Label("Test R2 TWR", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.small)
                .disabled(manager.isRunning)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("2D Position Estimate")
                    .font(.headline)
                Spacer()
                if let pos = manager.solvedPosition {
                    Text("\(pos.anchorCount) anchors")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }

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
                Text("Ref Anchor: 0x\(String(pos.referenceAnchorAddress, radix: 16))")
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var anchorsCard: some View {
        let sorted = manager.observationsByAddress.values.sorted { $0.address < $1.address }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Anchors (\(sorted.count))")
                    .font(.headline)
                Spacer()
                Text("\(manager.totalMeasurementsReceived) msgs")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if sorted.isEmpty {
                Text("No DL-TDoA measurements received yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sorted) { obs in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(String(format: "0x%04X", obs.address))
                                .font(.subheadline.bold().monospaced())
                            Text(obs.measurementTypeDescription.uppercased())
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.15), in: Capsule())
                                .foregroundStyle(.indigo)
                            Spacer()
                            Text(String(format: "%.1f dBm", obs.signalStrength))
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(obs.signalStrength > -75 ? .green : .orange)
                        }
                        Text(String(format: "Coord (%@): (%.3f, %.3f, %.3f)",
                                    obs.isRelative ? "rel" : "geo",
                                    obs.position3D.x, obs.position3D.y, obs.position3D.z))
                            .font(.caption.monospacedDigit())
                        Text(String(format: "rx - tx: %.9f s", obs.elapsedTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Diagnostic Log", systemImage: "terminal.fill")
                    .font(.headline)
                Spacer()
                Button {
                    manager.copyLogsToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(manager.logs.isEmpty)

                Button {
                    manager.clearLogs()
                } label: {
                    Image(systemName: "xmark.bin")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(manager.logs.isEmpty)
            }

            HStack {
                Picker("Filter", selection: $logFilter) {
                    ForEach(LogFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("PKT", isOn: $manager.logRawPackets)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }

            if filteredLogs.isEmpty {
                Text("No log entries matching filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredLogs) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.level.rawValue)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 36, alignment: .center)
                                    .padding(.vertical, 2)
                                    .background(color(for: entry.level).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.timeString)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(entry.message)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            Divider()
                        }
                    }
                    .padding(10)
                }
                .frame(height: 240)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .packet: return .purple
        case .warning: return .orange
        case .error: return .red
        }
    }
}
