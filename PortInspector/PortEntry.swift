import SwiftUI

enum PortState: String, Hashable {
    case listen = "LISTEN"
    case established = "ACTIVE"
    case closeWait = "CLOSE_WAIT"
    case synSent = "SYN_SENT"
    case udp = "UDP"
    case other = "-"

    var color: Color {
        switch self {
        case .listen:      return .green
        case .established: return .cyan
        case .closeWait:   return .orange
        case .synSent:     return .yellow
        case .udp:         return .purple
        case .other:       return .gray
        }
    }

    var label: String { rawValue }
}

struct PortEntry: Identifiable, Hashable {
    // Stable identity across refreshes — ForEach uses this to diff rows.
    // Random UUID() would give every entry a new ID on each scan, breaking LazyVStack.
    var id: String { "\(proto)|\(port)|\(pid)" }
    let proto: String
    let port: Int
    let state: PortState
    let localAddress: String
    let remoteAddress: String
    let pid: String
    let user: String
    let processName: String
    let elapsed: String
    let execPath: String
}

enum ScanFilter: String, CaseIterable, Identifiable {
    case listening = "Listening"
    case active    = "Active"
    case all       = "All"

    var id: String { rawValue }
}
