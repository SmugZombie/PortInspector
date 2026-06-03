import SwiftUI

struct PortRowView: View {
    let entry: PortEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    // State badge
                    Text(entry.state.label)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(entry.state.color)
                        .cornerRadius(3)
                        .frame(width: 74, alignment: .leading)

                    // Port
                    Text(entry.port == 0 ? "—" : "\(entry.port)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(width: 52, alignment: .trailing)

                    // Proto
                    Text(entry.proto)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 36)

                    // Process name
                    Text(entry.processName)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)

                    // PID
                    Text("PID \(entry.pid)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 64, alignment: .trailing)

                    // User
                    Text(entry.user)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 64, alignment: .trailing)

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                Color.primary.opacity(expanded ? 0.05 : 0)
            )

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if entry.remoteAddress != "-" {
                        DetailRow(label: "Remote", value: entry.remoteAddress)
                    }
                    DetailRow(label: "Local",   value: entry.localAddress)
                    DetailRow(label: "Path",    value: entry.execPath)
                    DetailRow(label: "Elapsed", value: entry.elapsed)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
            }

            Divider()
                .opacity(0.4)
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}
