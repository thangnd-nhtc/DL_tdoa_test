import SwiftUI

@main
struct DLTDOAReceiverApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("DL-TDoA", systemImage: "dot.radiowaves.left.and.right") }
                TWRAccessoryView()
                    .tabItem { Label("Accessory TWR", systemImage: "antenna.radiowaves.left.and.right") }
            }
        }
    }
}
