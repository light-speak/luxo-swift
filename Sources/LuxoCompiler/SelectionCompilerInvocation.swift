import Foundation

/// Separates semantic compiler options from linker/output options without shell evaluation.
struct SelectionCompilerInvocation {
    enum Failure: Error {
        case missingValue(String), unsupportedOption(String), noSources, sourceOutsideWorkspace(String),
            duplicateSource(String), invalidModule
    }
    let original: [String]
    let sources: [URL]
    let semantic: [String]
    let graph: [String]
    let module: String

    init(arguments: [String], workspace: URL, defaultModule: String) throws {
        var sources: [URL] = []
        var semantic: [String] = []
        var graph: [String] = []
        var module = defaultModule
        var position = 0
        let semanticPairs: Set<String> = [
            "-I", "-F", "-sdk", "-target", "-swift-version", "-D", "-Xcc",
            "-module-cache-path", "-plugin-path", "-package-name", "-entry-point-function-name", "-resource-dir",
            "-enable-experimental-feature", "-enable-upcoming-feature",
        ]
        let outputPairs: Set<String> = ["-o", "-L", "-l", "-Xlinker", "-emit-module-path", "-num-threads"]
        let flags: Set<String> = [
            "-O", "-Onone", "-Osize", "-g", "-emit-executable", "-emit-library", "-emit-module",
            "-whole-module-optimization",
        ]
        while position < arguments.count {
            let argument = arguments[position]
            if semanticPairs.contains(argument) || outputPairs.contains(argument) || argument == "-module-name" {
                guard position + 1 < arguments.count else { throw Failure.missingValue(argument) }
                let value = arguments[position + 1]
                if semanticPairs.contains(argument) { semantic += [argument, value] }
                if [
                    "-I", "-F", "-sdk", "-target", "-swift-version", "-Xcc", "-module-cache-path", "-plugin-path",
                    "-resource-dir",
                ].contains(argument) {
                    graph += [argument, value]
                }
                if argument == "-module-name" { module = value }
                position += 2
                continue
            }
            if argument.hasSuffix(".swift") && !argument.hasPrefix("-") {
                let url = URL(fileURLWithPath: argument, relativeTo: workspace).standardizedFileURL
                guard url.path.hasPrefix(workspace.path + "/"), url.resolvingSymlinksInPath().path == url.path else {
                    throw Failure.sourceOutsideWorkspace(argument)
                }
                guard !sources.contains(url) else { throw Failure.duplicateSource(argument) }
                sources.append(url)
            } else if argument.hasPrefix("-D"), argument.count > 2 {
                semantic += ["-D", String(argument.dropFirst(2))]
            } else if ["-parse-as-library", "-enable-testing"].contains(argument) {
                semantic.append(argument)
            } else if !flags.contains(argument) {
                throw Failure.unsupportedOption(argument)
            }
            position += 1
        }
        guard !sources.isEmpty else { throw Failure.noSources }
        guard SelectionManifest.validIdentifier(module) else { throw Failure.invalidModule }
        self.original = arguments
        self.sources = sources
        self.semantic = semantic + ["-module-name", module]
        self.graph = graph
        self.module = module
    }

    func replacingSources(_ replacements: [String: String], workspace: URL) -> [String] {
        original.map { argument in
            let path = URL(fileURLWithPath: argument, relativeTo: workspace).standardizedFileURL.path
            return replacements[path] ?? argument
        } + (original.contains("-module-name") ? [] : ["-module-name", module])
    }
}
