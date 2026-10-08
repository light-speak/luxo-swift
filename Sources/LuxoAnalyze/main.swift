import Foundation
import LuxoCompiler

enum CommandFailure: Error { case usage(String) }

func packageOptions(_ arguments: ArraySlice<String>) throws -> [String: String] {
    let arguments = Array(arguments)
    let allowed: Set<String> = [
        "--workspace", "--manifest", "--product", "--output", "--configuration", "--description", "--scratch",
        "--targets", "--bin",
    ]
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let key = arguments[index]
        guard allowed.contains(key), options[key] == nil, index + 1 < arguments.count else {
            throw CommandFailure.usage("Invalid or repeated package option: " + key)
        }
        options[key] = arguments[index + 1]
        index += 2
    }
    return options
}

func exportPackage(_ options: [String: String], workspace: URL) throws {
    guard let bin = options["--bin"], let product = options["--product"], let output = options["--output"] else {
        throw CommandFailure.usage("Missing --bin, --product or --output")
    }
    print(
        try SelectionPackageBuild.export(
            binaryDirectory: URL(fileURLWithPath: bin, relativeTo: workspace),
            product: product, output: URL(fileURLWithPath: output, relativeTo: workspace)
        ).path)
}

func package(_ arguments: ArraySlice<String>, prepareOnly: Bool = false, exportOnly: Bool = false) throws {
    let options = try packageOptions(arguments)
    let workspace = URL(fileURLWithPath: options["--workspace"] ?? FileManager.default.currentDirectoryPath)
        .standardizedFileURL
    if exportOnly {
        try exportPackage(options, workspace: workspace)
        return
    }
    guard let manifest = options["--manifest"] else { throw CommandFailure.usage("Missing --manifest") }
    if prepareOnly {
        guard let description = options["--description"], let scratch = options["--scratch"] else {
            throw CommandFailure.usage("Missing --description or --scratch")
        }
        let overlay = try SelectionPackageBuild.prepare(
            workspace: workspace,
            manifest: URL(fileURLWithPath: manifest, relativeTo: workspace),
            description: URL(fileURLWithPath: description, relativeTo: workspace),
            scratch: URL(fileURLWithPath: scratch, relativeTo: workspace),
            targets: options["--targets"].map { Set($0.split(separator: ",").map(String.init)) })
        print(overlay.path)
        return
    }
    guard let product = options["--product"], let output = options["--output"] else {
        throw CommandFailure.usage(
            "LuxoAnalyze package --manifest <LuxoSelection.json> --product <name> --output <new directory>")
    }
    let executable = try SelectionPackageBuild.run(
        workspace: workspace,
        manifest: URL(fileURLWithPath: manifest, relativeTo: workspace), product: product,
        output: URL(fileURLWithPath: output, relativeTo: workspace),
        configuration: options["--configuration"] ?? "debug")
    print(executable.path)
}

func build(_ arguments: ArraySlice<String>, prepareOnly: Bool = false) throws {
    var workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var manifest: String?
    var compiler = "swiftc"
    var scratch: String?
    let arguments = Array(arguments)
    var index = 0
    while index < arguments.count, arguments[index] != "--" {
        let option = arguments[index]
        guard index + 1 < arguments.count else { throw CommandFailure.usage("Missing value for " + option) }
        let value = arguments[index + 1]
        switch option {
        case "--workspace": workspace = URL(fileURLWithPath: value).standardizedFileURL
        case "--manifest": manifest = value
        case "--compiler": compiler = value
        case "--scratch" where prepareOnly: scratch = value
        default: throw CommandFailure.usage("Unknown option: " + option)
        }
        index += 2
    }
    guard let manifest, index < arguments.count else {
        throw CommandFailure.usage(
            "LuxoAnalyze build --manifest <LuxoSelection.json> [--workspace <root>] -- <swiftc arguments>")
    }
    let compilerArguments = Array(arguments.dropFirst(index + 1))
    if prepareOnly {
        guard let scratch else { throw CommandFailure.usage("Missing --scratch (new directory within .tmp)") }
        print(
            try SelectionBuild.prepareOverlay(
                workspace: workspace, manifest: URL(fileURLWithPath: manifest, relativeTo: workspace),
                scratch: URL(fileURLWithPath: scratch, relativeTo: workspace), arguments: compilerArguments,
                compiler: compiler
            ).path)
        return
    }
    try SelectionBuild.run(
        workspace: workspace, manifest: URL(fileURLWithPath: manifest, relativeTo: workspace),
        arguments: compilerArguments, compiler: compiler)
}

func xcodeOptions(_ arguments: ArraySlice<String>, allowed: Set<String>) throws -> [String: String] {
    let values = Array(arguments)
    var options: [String: String] = [:]
    var index = 0
    while index < values.count {
        guard allowed.contains(values[index]), options[values[index]] == nil, index + 1 < values.count else {
            throw CommandFailure.usage("Invalid or repeated Xcode option: " + values[index])
        }
        options[values[index]] = values[index + 1]
        index += 2
    }
    return options
}

func prepareXcode(_ arguments: ArraySlice<String>) throws {
    let options = try xcodeOptions(
        arguments, allowed: ["--workspace", "--manifest", "--scratch", "--log", "--module", "--target"])
    guard let manifest = options["--manifest"], let scratch = options["--scratch"], let log = options["--log"],
        let module = options["--module"], let target = options["--target"]
    else { throw CommandFailure.usage("Missing --manifest, --scratch, --log, --module or --target") }
    let workspace = URL(fileURLWithPath: options["--workspace"] ?? FileManager.default.currentDirectoryPath)
    print(
        try SelectionBuild.prepareXcodeOverlay(
            workspace: workspace, manifest: URL(fileURLWithPath: manifest, relativeTo: workspace),
            scratch: URL(fileURLWithPath: scratch, relativeTo: workspace),
            buildLog: String(contentsOf: URL(fileURLWithPath: log, relativeTo: workspace), encoding: .utf8),
            module: module, target: target
        ).path)
}

func buildXcode(_ arguments: ArraySlice<String>) throws {
    let options = try xcodeOptions(
        arguments,
        allowed: [
            "--workspace", "--manifest", "--project", "--scheme", "--module", "--target", "--destination", "--output",
            "--configuration", "--swift-flags",
        ])
    guard let manifest = options["--manifest"], let project = options["--project"], let scheme = options["--scheme"],
        let module = options["--module"], let target = options["--target"], let destination = options["--destination"],
        let output = options["--output"]
    else {
        throw CommandFailure.usage(
            "Missing --manifest, --project, --scheme, --module, --target, --destination or --output")
    }
    let workspace = URL(fileURLWithPath: options["--workspace"] ?? FileManager.default.currentDirectoryPath)
    print(
        try SelectionXcodeBuild.run(
            workspace: workspace, manifest: URL(fileURLWithPath: manifest, relativeTo: workspace),
            project: URL(fileURLWithPath: project, relativeTo: workspace), scheme: scheme, module: module,
            target: target,
            destination: destination, output: URL(fileURLWithPath: output, relativeTo: workspace),
            configuration: options["--configuration"] ?? "Debug", swiftFlags: options["--swift-flags"] ?? ""
        ).path)
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "build": try build(CommandLine.arguments.dropFirst(2))
    case "prepare-build": try build(CommandLine.arguments.dropFirst(2), prepareOnly: true)
    case "prepare-xcode": try prepareXcode(CommandLine.arguments.dropFirst(2))
    case "xcode-build": try buildXcode(CommandLine.arguments.dropFirst(2))
    case "package": try package(CommandLine.arguments.dropFirst(2))
    case "prepare-package": try package(CommandLine.arguments.dropFirst(2), prepareOnly: true)
    case "export-package": try package(CommandLine.arguments.dropFirst(2), exportOnly: true)
    default:
        throw CommandFailure.usage("Use LuxoAnalyze package or build. API-wide hints are not a build integration.")
    }
} catch {
    FileHandle.standardError.write(Data("Luxo selection build failed: \(error)\n".utf8))
    exit(1)
}
