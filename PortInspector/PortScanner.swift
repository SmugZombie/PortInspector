import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.portinspector.app", category: "scanner")

enum PortScannerError: LocalizedError {
    case timeout(String)
    case nonZeroExit(String, Int32)

    var errorDescription: String? {
        switch self {
        case .timeout(let cmd):     return "'\(cmd)' timed out — try running as administrator"
        case .nonZeroExit(let cmd, let code): return "'\(cmd)' exited with status \(code)"
        }
    }
}

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
        logger.info("Scan started (filter: \(self.scanFilter.rawValue))")
        do {
            entries = try await scan(filter: scanFilter)
            lastUpdated = Date()
            logger.info("Scan complete — \(self.entries.count) entries")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Scan failed: \(error.localizedDescription)")
        }
        isScanning = false
    }

    // MARK: - Private

    // Run an executable, draining stdout and stderr concurrently on GCD threads
    // so the pipe buffer never fills. Kills the process after `timeout` seconds.
    private func run(
        _ path: String,
        _ args: [String],
        timeout: TimeInterval = 12
    ) async throws -> String {

        logger.debug("run: \(path) \(args.joined(separator: " "))")

        return try await withCheckedThrowingContinuation { continuation in
            // DispatchQueue.global has an unbounded thread pool — safe for blocking reads.
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                proc.standardOutput = stdoutPipe
                proc.standardError  = stderrPipe

                // Only one resume; guard against double-fire from timeout + normal exit.
                var resumed = false
                let lock = NSLock()
                func finish(_ result: Result<String, Error>) {
                    lock.lock()
                    let first = !resumed
                    resumed = true
                    lock.unlock()
                    guard first else { return }
                    switch result {
                    case .success(let s): continuation.resume(returning: s)
                    case .failure(let e): continuation.resume(throwing: e)
                    }
                }

                // Kill the process if it takes too long.
                let timeoutWork = DispatchWorkItem {
                    if proc.isRunning {
                        logger.error("Timeout — terminating \(path)")
                        proc.terminate()
                    }
                    finish(.failure(PortScannerError.timeout((path as NSString).lastPathComponent)))
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutWork
                )

                // Drain stderr on its own thread so it never blocks the process.
                DispatchQueue.global(qos: .background).async {
                    _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                }

                do {
                    try proc.run()
                } catch {
                    timeoutWork.cancel()
                    logger.error("proc.run() threw: \(error.localizedDescription)")
                    finish(.failure(error))
                    return
                }

                // readDataToEndOfFile blocks until the process closes its stdout (exits).
                // This MUST come before waitUntilExit — if the output exceeds the pipe
                // buffer (~64 KB) and we wait first, the process blocks on write → deadlock.
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                timeoutWork.cancel()

                let status = proc.terminationStatus
                logger.debug("\(path) exited \(status), \(data.count) bytes")

                if status != 0 {
                    // lsof exits non-zero when some files are inaccessible — still return output.
                    logger.warning("\(path) non-zero exit \(status) (output still usable)")
                }

                finish(.success(String(data: data, encoding: .utf8) ?? ""))
            }
        }
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

            rawEntries.append(RawEntry(
                proto: proto, pid: pid,
                local: local, remote: remote,
                port: port, state: state
            ))
            pids.insert(pid)
        }

        logger.debug("lsof parsed \(rawEntries.count) raw entries for \(pids.count) PIDs")

        // Batch process details — two ps calls so the last (variable-width) column
        // is always comm=, making space-safe parsing straightforward.
        var processMap: [String: (user: String, name: String, elapsed: String, path: String)] = [:]

        let validPids = pids.filter { $0 != "-" }
        if !validPids.isEmpty {
            let pidList = validPids.joined(separator: ",")

            // Pass 1: PID + user + etime (no spaces in any field)
            let psInfo = try await run("/bin/ps", ["-p", pidList, "-o", "pid=,user=,etime="])
            var infoMap: [String: (user: String, elapsed: String)] = [:]
            for line in psInfo.components(separatedBy: .newlines) {
                let p = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard p.count >= 3 else { continue }
                infoMap[p[0]] = (user: p[1], elapsed: p[2])
            }

            // Pass 2: PID + comm= (comm is last so it safely captures spaces in paths/names)
            let psComm = try await run("/bin/ps", ["-p", pidList, "-o", "pid=,comm="])
            for line in psComm.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let space = trimmed.firstIndex(of: " ") else { continue }
                let pid      = String(trimmed[..<space])
                let fullPath = String(trimmed[trimmed.index(after: space)...])
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
