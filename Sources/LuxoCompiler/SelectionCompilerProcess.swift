import Foundation

struct SelectionCompilerProcess {
    enum Failure: Error { case failed(String, Int32, String), timeout(String) }
    let workspace: URL
    let scratch: URL

    func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let output = scratch.appendingPathComponent("output-\(UUID().uuidString)")
        let errors = scratch.appendingPathComponent("errors-\(UUID().uuidString)")
        let fm = FileManager.default
        fm.createFile(atPath: output.path, contents: nil)
        fm.createFile(atPath: errors.path, contents: nil)
        defer { try? fm.removeItem(at: output); try? fm.removeItem(at: errors) }
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.currentDirectoryURL = workspace
        process.standardOutput = stdout
        process.standardError = stderr
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        guard completed.wait(timeout: .now() + 300) == .success else {
            process.terminate()
            process.waitUntilExit()
            throw Failure.timeout(tool)
        }
        guard process.terminationStatus == 0 else {
            let diagnostic =
                try String(contentsOf: errors, encoding: .utf8) + "\n" + String(contentsOf: output, encoding: .utf8)
            throw Failure.failed(tool, process.terminationStatus, diagnostic)
        }
        let diagnostics = try Data(contentsOf: errors)
        if !diagnostics.isEmpty { FileHandle.standardError.write(diagnostics) }
        return try Data(contentsOf: output)
    }
}
