import Foundation

/// SwiftPM owns dependency resolution and linking; Luxo supplies only a source overlay.
public enum SelectionPackageBuild {
    public enum Failure: Error {
        case invalidProduct, outputExists, unsafeScratch, missingBuildDescription, noLocalTargets, duplicateSource(
            String)
    }

    public static func prepare(
        workspace: URL, manifest: URL, description: URL, scratch: URL, targets: Set<String>? = nil
    ) throws -> URL {
        let workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let scratch = scratch.standardizedFileURL
        guard scratch.path.hasPrefix(workspace.appendingPathComponent(".tmp").path + "/"),
            scratch.resolvingSymlinksInPath().path == scratch.path
        else { throw Failure.unsafeScratch }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let decoded = try JSONDecoder().decode(BuildDescription.self, from: Data(contentsOf: description))
        return try prepare(
            decoded, moduleDirectory: description.deletingLastPathComponent().appendingPathComponent("Modules").path,
            workspace: workspace, manifest: manifest,
            process: SelectionCompilerProcess(workspace: workspace, scratch: scratch), targets: targets)
    }

    public static func run(
        workspace: URL, manifest: URL, product: String, output: URL, configuration: String = "debug"
    ) throws -> URL {
        guard !product.isEmpty, !product.contains("/"), !product.hasPrefix("-"),
            ["debug", "release"].contains(configuration)
        else {
            throw Failure.invalidProduct
        }
        let workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw Failure.outputExists }
        let scratch = workspace.appendingPathComponent(".tmp/luxo-package-\(UUID().uuidString)")
        guard
            scratch.deletingLastPathComponent().resolvingSymlinksInPath().path
                == workspace.appendingPathComponent(".tmp").path
        else { throw Failure.unsafeScratch }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let process = SelectionCompilerProcess(workspace: workspace, scratch: scratch)
        let arguments = [
            "build", "--package-path", workspace.path, "--scratch-path", scratch.appendingPathComponent("build").path,
            "--product", product, "--configuration", configuration, "--disable-automatic-resolution", "--jobs", "2",
        ]
        _ = try process.run("swift", arguments)
        let binPath = String(decoding: try process.run("swift", arguments + ["--show-bin-path"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bin = URL(fileURLWithPath: binPath)
        guard bin.path.hasPrefix(scratch.path + "/") else { throw Failure.missingBuildDescription }
        let description = try JSONDecoder().decode(
            BuildDescription.self, from: Data(contentsOf: bin.appendingPathComponent("description.json")))
        let overlay = try prepare(
            description, moduleDirectory: bin.appendingPathComponent("Modules").path,
            workspace: workspace, manifest: manifest, process: process)
        _ = try process.run("swift", arguments + ["-Xswiftc", "-vfsoverlay", "-Xswiftc", overlay.path])
        let executable = bin.appendingPathComponent(product)
        guard fm.isExecutableFile(atPath: executable.path) else { throw Failure.invalidProduct }
        return try export(binaryDirectory: bin, product: product, output: output)
    }

    public static func export(binaryDirectory: URL, product: String, output: URL) throws -> URL {
        let fm = FileManager.default
        guard !product.isEmpty, !product.contains("/"), product != ".", product != "..",
            fm.isExecutableFile(atPath: binaryDirectory.appendingPathComponent(product).path)
        else { throw Failure.invalidProduct }
        guard !fm.fileExists(atPath: output.path) else { throw Failure.outputExists }
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: output) } }
        let items = try fm.contentsOfDirectory(at: binaryDirectory, includingPropertiesForKeys: nil)
        for item in items
        where item.lastPathComponent == product
            || ["bundle", "resources", "dSYM", "dylib", "so"].contains(item.pathExtension)
        {
            try fm.copyItem(at: item, to: output.appendingPathComponent(item.lastPathComponent))
        }
        succeeded = true
        return output.appendingPathComponent(product)
    }

    private static func prepare(
        _ description: BuildDescription, moduleDirectory: String, workspace: URL, manifest: URL,
        process: SelectionCompilerProcess,
        targets: Set<String>? = nil
    ) throws -> URL {
        let data = try Data(contentsOf: manifest)
        let declaration = try JSONDecoder().decode(SelectionManifest.self, from: data)
        try declaration.validate()
        let commands = description.swiftCommands.values.filter {
            (targets?.contains($0.moduleName) ?? true) && $0.importPath == moduleDirectory && !$0.sources.isEmpty
                && $0.sources.allSatisfy { $0.hasPrefix(workspace.path + "/") }
                && $0.sources.contains { !$0.hasPrefix(process.scratch.path + "/") }
                && FileManager.default.fileExists(atPath: $0.moduleOutputPath)
        }.sorted { $0.moduleName < $1.moduleName }
        guard !commands.isEmpty else { throw Failure.noLocalTargets }
        var entries: [SelectionBuild.Overlay.File] = []
        var originals: [String: String] = [:]
        for command in commands {
            for source in command.sources {
                guard originals[source] == nil else { throw Failure.duplicateSource(source) }
                originals[source] = try String(contentsOfFile: source, encoding: .utf8)
            }
            let scratch = process.scratch.appendingPathComponent("module-\(entries.count)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let child = SelectionCompilerProcess(workspace: workspace, scratch: scratch)
            let prepared = try SelectionBuild.prepare(
                workspace: workspace, data: data, declaration: declaration,
                arguments: try command.analysisArguments(), compiler: command.executable, process: child,
                bootstrapModule: false)
            entries += try JSONDecoder().decode(SelectionBuild.Overlay.self, from: Data(contentsOf: prepared.overlay))
                .roots
        }
        for (path, original) in originals where try String(contentsOfFile: path, encoding: .utf8) != original {
            throw SelectionBuild.Failure.changedSource(path)
        }
        let overlay = process.scratch.appendingPathComponent("overlay.json")
        try JSONEncoder().encode(SelectionBuild.Overlay(roots: entries)).write(to: overlay)
        return overlay
    }
}

private struct BuildDescription: Decodable {
    struct Command: Decodable {
        let executable: String
        let moduleName: String
        let moduleOutputPath: String
        let sources: [String]
        let importPath: String
        let otherArguments: [String]

        func analysisArguments() throws -> [String] {
            var result = ["-module-name", moduleName, "-I", importPath]
            var index = 0
            let ignored: Set<String> = [
                "-incremental", "-enable-batch-mode", "-serialize-diagnostics", "-parseable-output",
            ]
            while index < otherArguments.count {
                let value = otherArguments[index]
                if value == "-index-store-path" { index += 2; continue }
                if ignored.contains(value) || (value.hasPrefix("-j") && Int(value.dropFirst(2)) != nil) {
                    index += 1; continue
                }
                if value == "-Xfrontend" { index += 1; continue }
                result.append(value)
                index += 1
            }
            return result + sources
        }
    }
    let swiftCommands: [String: Command]
}
