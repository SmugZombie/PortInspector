import SwiftUI

@main
struct PortInspectorApp: App {
    @StateObject private var scanner = PortScanner()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(scanner)
        } label: {
            Label("Port Inspector", systemImage: "network")
        }
        .menuBarExtraStyle(.window)
    }
}
