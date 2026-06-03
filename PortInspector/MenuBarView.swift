import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var scanner: PortScanner

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            filterBar
            Divider()
            portList
            Divider()
            footerBar
        }
        .frame(width: 600)
        .background(.background)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Label("Port Inspector", systemImage: "network")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            if let updated = scanner.lastUpdated {
                Text(updated, style: .relative) + Text(" ago")
            } else {
                Text("—")
            }
            Text("•")
                .foregroundColor(.secondary)
            if scanner.isScanning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            } else {
                Button {
                    Task { await scanner.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }

            Text("•")
                .foregroundColor(.secondary)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    // MARK: - Filter

    private var filterBar: some View {
        Picker("", selection: $scanner.scanFilter) {
            ForEach(ScanFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - List

    private var portList: some View {
        Group {
            if let error = scanner.errorMessage {
                errorView(error)
            } else if scanner.entries.isEmpty && !scanner.isScanning {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        columnHeader
                        ForEach(scanner.entries) { entry in
                            PortRowView(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 460)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("STATE")
                .frame(width: 74, alignment: .leading)
            Text("PORT")
                .frame(width: 52, alignment: .trailing)
            Text("PROTO")
                .frame(width: 36)
            Text("PROCESS")
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            Text("PID")
                .frame(width: 64, alignment: .trailing)
            Text("USER")
                .frame(width: 64, alignment: .trailing)
            Image(systemName: "chevron.down")
                .font(.system(size: 9))
                .opacity(0)
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No ports found")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private func errorView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(16)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            let listening = scanner.entries.filter { $0.state == .listen }.count
            let active    = scanner.entries.filter { $0.state == .established }.count
            let udp       = scanner.entries.filter { $0.state == .udp }.count

            SummaryChip(count: listening, label: "listening", color: .green)
            SummaryChip(count: active,    label: "active",    color: .cyan)
            SummaryChip(count: udp,       label: "UDP",       color: .purple)

            Spacer()

            Text("Auto-refresh: 5s")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct SummaryChip: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}
