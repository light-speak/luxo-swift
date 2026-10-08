import Foundation

/// Owns both build stages; only a successfully transformed product is exported.
public enum SelectionXcodeBuild {
    public enum Failure: Error { case unsafePath, outputExists, missingProduct, changedInput(String) }

    public static func run(
        workspace: URL, manifest: URL, project: URL, scheme: String, module: String, target: String,
        destination: String, output: URL, configuration: String = "Debug", swiftFlags: String = ""
    ) throws -> URL {
        let workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let output = output.standardizedFileURL
        try validate(workspace: workspace, project: project, output: output)
        let fm = FileManager.default
        let scratch = workspace.appendingPathComponent(".tmp/luxo-xcode-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let process = SelectionCompilerProcess(workspace: workspace, scratch: scratch)
        let base = [
            "-project", project.path, "-scheme", scheme, "-configuration", configuration,
            "-destination", destination, "-derivedDataPath", scratch.appendingPathComponent("DerivedData").path,
        ]
        let inputs = try contents([manifest, project.appendingPathComponent("project.pbxproj")])
        let flags = "$(inherited) " + swiftFlags
        let first = try process.run("/usr/bin/xcodebuild", base + ["OTHER_SWIFT_FLAGS=" + flags, "build"])
        let arguments = try SelectionXcodeInvocation.extract(
            String(decoding: first, as: UTF8.self), module: module, target: target, workspace: workspace)
        let invocation = try SelectionCompilerInvocation(
            arguments: arguments, workspace: workspace, defaultModule: module)
        let sources = try contents(invocation.sources)
        let overlay = try SelectionBuild.prepareOverlay(
            workspace: workspace, manifest: manifest, scratch: scratch.appendingPathComponent("selection"),
            arguments: arguments)
        let finalFlags = flags + " -vfsoverlay \"" + overlay.path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        _ = try process.run("/usr/bin/xcodebuild", base + ["OTHER_SWIFT_FLAGS=" + finalFlags, "build"])
        try unchanged(inputs)
        try unchanged(sources)
        let settings = try process.run("/usr/bin/xcodebuild", base + ["-showBuildSettings", "-json"])
        let product = try product(settings, module: module, scratch: scratch)
        try validate(workspace: workspace, project: project, output: output)
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: product, to: output)
        return output
    }

    private static func validate(workspace: URL, project: URL, output: URL) throws {
        let scratchRoot = workspace.appendingPathComponent(".tmp").path
        guard output.path.hasPrefix(scratchRoot + "/"), output.pathExtension == "app",
            output.resolvingSymlinksInPath().path == output.path,
            URL(fileURLWithPath: scratchRoot).resolvingSymlinksInPath().path == scratchRoot,
            project.standardizedFileURL.path.hasPrefix(workspace.path + "/"), project.pathExtension == "xcodeproj",
            project.resolvingSymlinksInPath().path == project.standardizedFileURL.path
        else { throw Failure.unsafePath }
        if FileManager.default.fileExists(atPath: output.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: output.path)) != nil
        {
            throw Failure.outputExists
        }
    }

    private struct Settings: Decodable { let buildSettings: [String: String] }

    private static func product(_ data: Data, module: String, scratch: URL) throws -> URL {
        let matches = try JSONDecoder().decode([Settings].self, from: data)
            .filter { $0.buildSettings["PRODUCT_MODULE_NAME"] == module }
        guard matches.count == 1, let settings = matches.first?.buildSettings,
            let directory = settings["TARGET_BUILD_DIR"], let name = settings["FULL_PRODUCT_NAME"],
            !name.contains("/"), name.hasSuffix(".app")
        else { throw Failure.missingProduct }
        let result = URL(fileURLWithPath: directory).appendingPathComponent(name).standardizedFileURL
        guard result.path.hasPrefix(scratch.path + "/"), result.resolvingSymlinksInPath().path == result.path,
            FileManager.default.fileExists(atPath: result.path)
        else { throw Failure.missingProduct }
        return result
    }

    private static func contents(_ files: [URL]) throws -> [URL: Data] {
        var result: [URL: Data] = [:]
        for file in files { result[file] = try Data(contentsOf: file) }
        return result
    }

    private static func unchanged(_ files: [URL: Data]) throws {
        for (file, original) in files where try Data(contentsOf: file) != original {
            throw Failure.changedInput(file.path)
        }
    }
}
