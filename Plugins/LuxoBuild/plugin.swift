import Foundation
import PackagePlugin

@main
struct LuxoBuildPlugin: CommandPlugin {
    enum Failure: Error {
        case commandFailed(Int32), invalidArguments, buildFailed(String), missingArtifact, outputExists
    }

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let options = try parse(arguments)
        guard let manifest = options["--manifest"], let product = options["--product"],
            let destination = options["--output"],
            let configuration = PackageManager.BuildConfiguration(rawValue: options["--configuration"] ?? "debug")
        else {
            throw Failure.invalidArguments
        }
        let workspace = context.package.directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: destination, relativeTo: workspace).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.outputExists }
        var parameters = PackageManager.BuildParameters(configuration: configuration)
        let initial = try packageManager.build(.product(product), parameters: parameters)
        let artifact = try executable(initial, product: product)
        let scratch = workspace.appendingPathComponent(".tmp/luxo-plugin-\(UUID().uuidString)")
        guard
            scratch.deletingLastPathComponent().resolvingSymlinksInPath().path
                == workspace.appendingPathComponent(".tmp").path
        else {
            throw Failure.invalidArguments
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let overlay = try runTool(
            context: context,
            arguments: [
                "prepare-package", "--workspace", workspace.path,
                "--manifest", manifest, "--description",
                artifact.deletingLastPathComponent().appendingPathComponent("description.json").path,
                "--scratch", scratch.path, "--targets",
                try modules(context: context, product: product).joined(separator: ","),
            ])
        parameters.otherSwiftcFlags = ["-vfsoverlay", overlay]
        let final = try executable(packageManager.build(.product(product), parameters: parameters), product: product)
        print(
            try runTool(
                context: context,
                arguments: [
                    "export-package", "--workspace", workspace.path,
                    "--bin", final.deletingLastPathComponent().path, "--product", product, "--output", output.path,
                ]))
    }

    private func runTool(context: PluginContext, arguments: [String]) throws -> String {
        let tool = try context.tool(named: "LuxoAnalyze")
        let process = Process()
        let output = Pipe()
        process.executableURL = tool.url
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.commandFailed(process.terminationStatus) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func modules(context: PluginContext, product: String) throws -> [String] {
        guard let product = context.package.products.first(where: { $0.name == product }) else {
            throw Failure.invalidArguments
        }
        let local = Set(context.package.targets.map(\.id))
        var pending = product.targets
        var seen: Set<String> = []
        var modules: Set<String> = []
        while let target = pending.popLast() {
            guard seen.insert(target.id).inserted else { continue }
            if local.contains(target.id), let source = target as? SourceModuleTarget {
                modules.insert(source.moduleName)
            }
            for dependency in target.dependencies {
                switch dependency {
                case .target(let target): pending.append(target)
                case .product(let product): pending += product.targets
                @unknown default: throw Failure.invalidArguments
                }
            }
        }
        return modules.sorted()
    }

    private func executable(_ result: PackageManager.BuildResult, product: String) throws -> URL {
        guard result.succeeded else { throw Failure.buildFailed(result.logText) }
        guard
            let artifact = result.builtArtifacts.first(where: {
                $0.kind == .executable && $0.url.lastPathComponent == product
            })
        else {
            throw Failure.missingArtifact
        }
        return artifact.url
    }

    private func parse(_ arguments: [String]) throws -> [String: String] {
        var options: [String: String] = [:]
        let allowed: Set<String> = ["--manifest", "--product", "--output", "--configuration"]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard allowed.contains(key), options[key] == nil, index + 1 < arguments.count else {
                throw Failure.invalidArguments
            }
            options[key] = arguments[index + 1]
            index += 2
        }
        return options
    }
}
