import Foundation
import Combine

@MainActor
class PortScanner: ObservableObject {
    @Published var entries: [PortEntry] = []
    @Published var isScanning = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var scanFilter: ScanFilter = .listening {
        didSet { Task { await refresh() } }
    }

    private var autoRefreshTask: Task<Void, Never>?

    init() {
        Task { await refresh() }
        startAutoRefresh()
    }

    deinit { autoRefreshTask?.cancel() }

    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        do {
            entries = try await scan(filter: scanFilter)
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
        isScanning = false
    }

    // MARK: - Private

    private func run(_ path: String, _ args: [String]) async throws -> String {
        try await Task.detached(priority: .background) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let out = Pipe()
            proc.standardOutput = out
            // Discard stderr — unread Pipe buffers deadlock if the child writes > 64 KB to stderr
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            // Must drain stdout BEFORE waitUntilExit; if output exceeds the pipe buffer
            // (~64 KB on macOS) the child blocks on write while we wait for it to exit → deadlock.
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    private func scan(filter: ScanFilter) async throws -> [PortEntry] {
        let lsofArgs: [String]
        switch filter {
        case .listening: lsofArgs = ["-nP", "-iTCP", "-sTCP:LISTEN"]
        case .active:    lsofArgs = ["-nP", "-iTCP", "-sTCP:ESTABLISHED"]
        case .all:       lsofArgs = ["-nP", "-iTCP", "-iUDP"]
        }

        let lsofOut = try await run("/usr/sbin/lsof", lsofArgs)

        struct RawEntry {
            var proto, pid, local, remote: String
            var port: Int
            var state: PortState
        }

        var rawEntries: [RawEntry] = []
        var pids = Set<String>()

        for line in lsofOut.components(separatedBy: .newlines).dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9 else { continue }

            let pid   = String(cols[1])
            let proto = String(cols[7])
            let name  = cols[8...].joined(separator: " ")

            let state: PortState
            if      name.contains("(LISTEN)")      { state = .listen }
            else if name.contains("(ESTABLISHED)") { state = .established }
            else if name.contains("(CLOSE_WAIT)")  { state = .closeWait }
            else if name.contains("(SYN_SENT)")    { state = .synSent }
            else if proto.contains("UDP")          { state = .udp }
            else                                   { state = .other }

            let cleaned = name
                .replacingOccurrences(of: #"\([A-Z_]+\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            let parts  = cleaned.components(separatedBy: "->")
            let local  = parts[0].trimmingCharacters(in: .whitespaces)
            let remote = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "-"

            var port = 0
            if let r = local.range(of: #":\d+$"#, options: .regularExpression) {
                port = Int(local[r].dropFirst()) ?? 0
            }

            rawEntries.append(RawEntry(proto: proto, pid: pid, local: local, remote: remote, port: port, state: state))
            pids.insert(pid)
        }

        // Batch process details via two ps invocations.
        // We split into two calls because comm= (the executable path) may contain spaces,
        // so it must be the last column to allow correct parsing.
        var processMap: [String: (user: String, name: String, elapsed: String, path: String)] = [:]

        let validPids = pids.filter { $0 != "-" }
        if !validPids.isEmpty {
            let pidList = validPids.joined(separator: ",")

            // First pass: pid, user, etime — none of these fields have spaces
            let psInfo = try await run("/bin/ps", ["-p", pidList, "-o", "pid=,user=,etime="])
            var infoMap: [String: (user: String, elapsed: String)] = [:]
            for line in psInfo.components(separatedBy: .newlines) {
                let p = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard p.count >= 3 else { continue }
                infoMap[p[0]] = (user: p[1], elapsed: p[2])
            }

            // Second pass: pid and comm= (full executable path, may have spaces — must be last)
            let psComm = try await run("/bin/ps", ["-p", pidList, "-o", "pid=,comm="])
            for line in psComm.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                // Split on first space only: [pid, rest-of-line-is-path]
                guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
                let pid      = String(trimmed[..<spaceIdx])
                let fullPath = String(trimmed[trimmed.index(after: spaceIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !pid.isEmpty, !fullPath.isEmpty else { continue }

                let displayName = fullPath.hasPrefix("/")
                    ? URL(fileURLWithPath: fullPath).lastPathComponent
                    : String(fullPath.components(separatedBy: .whitespaces).first ?? fullPath)

                let info = infoMap[pid]
                processMap[pid] = (
                    user:    info?.user    ?? "-",
                    name:    displayName,
                    elapsed: info?.elapsed ?? "-",
                    path:    fullPath
                )
            }
        }

        // Deduplicate and build final entries
        var seen   = Set<String>()
        var result = [PortEntry]()

        for raw in rawEntries {
            let key = "\(raw.proto)|\(raw.port)|\(raw.pid)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let d = processMap[raw.pid]
            result.append(PortEntry(
                proto:         raw.proto,
                port:          raw.port,
                state:         raw.state,
                localAddress:  raw.local,
                remoteAddress: raw.remote,
                pid:           raw.pid,
                user:          d?.user    ?? "-",
                processName:   d?.name    ?? "-",
                elapsed:       d?.elapsed ?? "-",
                execPath:      d?.path    ?? "-"
            ))
        }

        return result.sorted { $0.port < $1.port }
    }
}
