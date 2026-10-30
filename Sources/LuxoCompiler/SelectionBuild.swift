import Foundation

/// An explicit compiler entry: analyze immutable snapshots, inject selections, then compile them.
public enum SelectionBuild {
    public enum Failure: Error { case incompatibleCompiler(String), changedSource(String), invalidToolchain }
    public static let compilerVersion = "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)"

    /// Consumes one current Xcode command for an explicitly selected module and target triple.
    public static func prepareXcodeOverlay(
        workspace: URL, manifest: URL, scratch: URL, buildLog: String, module: String, target: String
    ) throws -> URL {
        let workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let arguments = try SelectionXcodeInvocation.extract(
            buildLog, module: module, target: target, workspace: workspace)
        return try prepareOverlay(workspace: workspace, manifest: manifest, scratch: scratch, arguments: arguments)
    }

    /// The build system owns this new directory until all compiler jobs have completed.
    public static func prepareOverlay(
        workspace: URL, manifest: URL, scratch: URL, arguments: [String], compiler: String = "swiftc"
    ) throws -> URL {
        let workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let scratch = scratch.standardizedFileURL
        let fm = FileManager.default
        guard scratch.path.hasPrefix(workspace.appendingPathComponent(".tmp").path + "/"),
            scratch.resolvingSymlinksInPath().path == scratch.path
        else { throw Failure.invalidToolchain }
        try fm.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exclusive creation prevents a second build from replacing a live overlay.
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: scratch) } }
        let data = try Data(contentsOf: manifest)
        let declaration = try JSONDecoder().decode(SelectionManifest.self, from: data)
        try declaration.validate()
        let prepared = try prepare(
            workspace: workspace, data: data, declaration: declaration, arguments: arguments, compiler: compiler,
            process: SelectionCompilerProcess(workspace: workspace, scratch: scratch))
        succeeded = true
        return prepared.overlay
    }

    public static func run(workspace: URL, manifest: URL, arguments: [String], compiler: String = "swiftc") throws {
        let workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let data = try Data(contentsOf: manifest)
        let declaration = try JSONDecoder().decode(SelectionManifest.self, from: data)
        try declaration.validate()
        let scratch = workspace.appendingPathComponent(".tmp/luxo-selection-\(UUID().uuidString)")
        let fm = FileManager.default
        guard
            scratch.deletingLastPathComponent().resolvingSymlinksInPath().path
                == workspace.appendingPathComponent(".tmp").path
        else {
            throw Failure.invalidToolchain
        }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let process = SelectionCompilerProcess(workspace: workspace, scratch: scratch)
        let prepared = try prepare(
            workspace: workspace, data: data, declaration: declaration, arguments: arguments, compiler: compiler,
            process: process)
        _ = try process.run(compiler, prepared.arguments + ["-vfsoverlay", prepared.overlay.path])
    }

    static func prepare(
        workspace: URL, data: Data, declaration: SelectionManifest, arguments: [String], compiler: String,
        process: SelectionCompilerProcess, bootstrapModule: Bool = true
    ) throws -> (arguments: [String], overlay: URL) {
        let scratch = process.scratch
        var arguments = arguments
        if !arguments.contains("-sdk") {
            let sdk = String(decoding: try process.run("/usr/bin/xcrun", ["--show-sdk-path"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            arguments += ["-sdk", sdk]
        }
        let invocation = try SelectionCompilerInvocation(
            arguments: arguments, workspace: workspace, defaultModule: declaration.module)
        let target = try JSONDecoder().decode(TargetInfo.self, from: process.run(compiler, ["-print-target-info"]))
        guard target.compilerVersion == compilerVersion else {
            throw Failure.incompatibleCompiler(target.compilerVersion)
        }
        let snapshots = try snapshot(invocation.sources, in: scratch)
        let sources = snapshots.map(\.copy.path)
        if bootstrapModule && invocation.module == declaration.module {
            _ = try process.run(
                compiler,
                invocation.semantic + sources + [
                    "-emit-module", "-emit-module-path",
                    scratch.appendingPathComponent(declaration.module + ".swiftmodule").path,
                ])
        }
        let catalog = try catalog(
            data: data, declaration: declaration, invocation: invocation, process: process, target: target.target.triple
        )
        let rewritten = try analyze(
            snapshots, invocation: invocation, catalog: catalog, process: process, compiler: compiler)
        for (snapshot, source) in zip(snapshots, rewritten) {
            guard try String(contentsOf: snapshot.original, encoding: .utf8) == snapshot.source else {
                throw Failure.changedSource(snapshot.original.path)
            }
            try source.write(to: snapshot.copy, atomically: true, encoding: .utf8)
        }
        let overlay = scratch.appendingPathComponent("overlay.json")
        try writeOverlay(snapshots, to: overlay)
        return (invocation.replacingSources([:], workspace: workspace), overlay)
    }

    private struct Snapshot { let original: URL; let copy: URL; let source: String }
    struct Overlay: Codable {
        struct File: Codable {
            let type = "file"
            let name: String
            let contents: String
            enum CodingKeys: String, CodingKey { case type, name; case contents = "external-contents" }
        }
        let version = 0
        let externalNames = false
        let roots: [File]
        enum CodingKeys: String, CodingKey { case version, roots; case externalNames = "use-external-names" }
    }

    private static func writeOverlay(_ snapshots: [Snapshot], to file: URL) throws {
        let overlay = Overlay(roots: snapshots.map { .init(name: $0.original.path, contents: $0.copy.path) })
        try JSONEncoder().encode(overlay).write(to: file)
    }
    private struct TargetInfo: Decodable {
        struct Target: Decodable { let triple: String }
        let compilerVersion: String
        let target: Target
    }

    private static func snapshot(_ sources: [URL], in scratch: URL) throws -> [Snapshot] {
        try sources.enumerated().map { index, original in
            let directory = scratch.appendingPathComponent("source-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(original.lastPathComponent)
            let source = try String(contentsOf: original, encoding: .utf8)
            try source.write(to: copy, atomically: true, encoding: .utf8)
            return Snapshot(original: original, copy: copy, source: source)
        }
    }

    private static func catalog(
        data: Data, declaration: SelectionManifest, invocation: SelectionCompilerInvocation,
        process: SelectionCompilerProcess, target: String
    ) throws -> SelectionCatalog {
        let tool = String(
            decoding: try process.run("/usr/bin/xcrun", ["--find", "swift-symbolgraph-extract"]), as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { throw Failure.invalidToolchain }
        let modules = [declaration.module] + (declaration.runtimeModule.map { [$0] } ?? [])
        var graphs: [Data] = []
        for module in modules {
            let directory = process.scratch.appendingPathComponent("graph-" + module)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let targetArgs = invocation.graph.contains("-target") ? [] : ["-target", target]
            _ = try process.run(
                tool,
                invocation.graph + targetArgs + [
                    "-I", process.scratch.path, "-module-name", module, "-output-dir", directory.path,
                ])
            graphs.append(try Data(contentsOf: directory.appendingPathComponent(module + ".symbols.json")))
        }
        return try SelectionCatalog(manifest: data, graphs: graphs, currentModule: invocation.module)
    }

    private static func analyze(
        _ snapshots: [Snapshot], invocation: SelectionCompilerInvocation, catalog: SelectionCatalog,
        process: SelectionCompilerProcess, compiler: String
    ) throws -> [String] {
        try snapshots.map { snapshot in
            let others = snapshots.filter { $0.copy != snapshot.copy }.map(\.copy.path)
            let ast = try process.run(
                compiler,
                ["-frontend", "-dump-ast", "-dump-ast-format", "json", "-dump-usr"]
                    + invocation.semantic + ["-primary-file", snapshot.copy.path] + others)
            let root = try JSONDecoder().decode(CompilerASTValue.self, from: ast)
            let index = try SemanticCallIndex(
                root: root, compilerVersion: compilerVersion, apiSymbols: Set(catalog.apis.keys),
                source: snapshot.source)
            let selections = try ProjectionInference.infer(
                root: root, apis: catalog.apis, fields: catalog.fields, transparent: catalog.transparent)
            return try SelectionSourceRewriter.rewrite(
                source: snapshot.source, index: index, selections: selections, planFactories: catalog.planFactories)
        }
    }
}
