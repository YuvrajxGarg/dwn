import Foundation

/// Launches and supervises the Python download engine.
///
/// The engine prints `DWN_ENGINE_READY <port>` once it listens on 127.0.0.1.
/// It watches its stdin and exits when the app's end closes, so it never
/// outlives the app. If it crashes, it is restarted up to three times in a row.
@MainActor
final class Engine: ObservableObject {
    enum State: Equatable { case stopped, starting, running(port: Int), failed(String) }

    @Published private(set) var state: State = .stopped
    private(set) var api: API?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var crashCount = 0
    private var stopping = false
    private let token = UUID().uuidString + UUID().uuidString
    var onReady: (() -> Void)?

    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dwn")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.log")
    }()

    /// The bundled PyInstaller build, or for development the script named by DWN_ENGINE.
    private func command() -> (URL, [String])? {
        if let res = Bundle.main.resourceURL {
            let bin = res.appendingPathComponent("engine/dwn-engine")
            if FileManager.default.isExecutableFile(atPath: bin.path) { return (bin, []) }
        }
        if let script = ProcessInfo.processInfo.environment["DWN_ENGINE"] {
            let dir = URL(fileURLWithPath: script).deletingLastPathComponent()
            let py = dir.appendingPathComponent(".venv/bin/python")
            return (py, [script])
        }
        return nil
    }

    func start() {
        guard process == nil else { return }
        guard let (exe, args) = command() else {
            state = .failed("The download engine is missing from this copy of Dwn.")
            return
        }
        stopping = false
        state = .starting

        let p = Process()
        p.executableURL = exe
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DWN_TOKEN"] = token
        env["PYTHONUNBUFFERED"] = "1"
        // GUI apps get a minimal PATH; make Homebrew and nvm tools visible.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env

        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: Self.logURL) {
            log.truncateFile(atOffset: 0)
            p.standardError = log
        }

        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            buffer.append(chunk)
            guard let text = String(data: buffer, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("DWN_ENGINE_READY") }),
                  let port = Int(line.split(separator: " ").last ?? "") else { return }
            h.readabilityHandler = nil
            Task { @MainActor in self?.ready(port: port) }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.terminated(proc, status: proc.terminationStatus) }
        }

        do {
            try p.run()
            process = p
            stdinPipe = inp
        } catch {
            state = .failed("The download engine couldn't start: \(error.localizedDescription)")
            return
        }

        let launched = p
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if self.process === launched, self.state == .starting {
                self.state = .failed("The download engine took too long to start. Try again in a moment.")
                launched.terminate()
            }
        }
    }

    private func ready(port: Int) {
        api = API(port: port, token: token)
        state = .running(port: port)
        crashCount = 0
        onReady?()
    }

    private func terminated(_ proc: Process, status: Int32) {
        guard proc === process else { return }
        process = nil
        stdinPipe = nil
        api = nil
        if stopping { state = .stopped; return }
        crashCount += 1
        if crashCount > 3 {
            state = .failed("The download engine stopped unexpectedly several times. Its log is at ~/Library/Logs/Dwn/engine.log.")
            return
        }
        start()
    }

    func stop() {
        stopping = true
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
    }

    func restart() {
        crashCount = 0
        if let p = process {
            stopping = true
            p.terminationHandler = nil
            p.terminate()
            p.waitUntilExit()
            process = nil
        }
        api = nil
        stopping = false
        start()
    }
}
