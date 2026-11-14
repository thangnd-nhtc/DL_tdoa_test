import SwiftUI

struct TWRAccessoryView: View {
    @StateObject private var manager = TWRAccessoryManager()
    var body: some View {
        NavigationStack {
            List {
                Section("Accessory TWR / QANI") {
                    Text("Requires Qorvo Nearby Interaction accessory firmware with a genuine accessory configuration backend. A plain QM35 UCI/DL-TDoA firmware image is not sufficient.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(manager.status)
                    if let distance = manager.distance {
                        Text(String(format: "Distance: %.2f m", distance)).font(.title2.monospacedDigit())
                    }
                    Button("Scan for Accessories") { manager.scan() }.disabled(manager.isActive)
                    Button("Stop / Disconnect", role: .destructive) { manager.stop() }.disabled(!manager.isActive)
                }
                Section("Discovered Accessories") {
                    ForEach(manager.accessories) { accessory in
                        Button { manager.connect(accessory) } label: {
                            VStack(alignment: .leading) {
                                Text(accessory.name)
                                Text(accessory.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Handshake Log") {
                    ForEach(Array(manager.logs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Accessory TWR")
        }
        .onDisappear { manager.stop() }
    }
}
