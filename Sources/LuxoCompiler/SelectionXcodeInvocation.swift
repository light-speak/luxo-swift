import Foundation

/// Reads literal driver arguments; never evaluates the build log as a shell program.
enum SelectionXcodeInvocation {
    enum Failure: Error { case malformedWords, unsupported(String), missingValue(String), unsafeFile(String) }

    static func extract(_ log: String, module: String, target: String, workspace: URL) throws -> [String] {
        var matches: [[String]] = []
        for line in log.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            let prefix = "builtin-SwiftDriver -- "
            guard text.hasPrefix(prefix) else { continue }
            let command = try words(String(text.dropFirst(prefix.count)))
            guard let tool = command.first, URL(fileURLWithPath: tool).lastPathComponent == "swiftc" else {
                throw Failure.unsupported(text)
            }
            let args = Array(command.dropFirst())
            guard value("-module-name", in: args) == module, value("-target", in: args) == target else { continue }
            matches.append(try analysis(args, workspace: workspace))
        }
        guard matches.count == 1 else { throw Failure.unsupported("Expected exactly one matching SwiftDriver command") }
        return matches[0]
    }

    private static func value(_ flag: String, in arguments: [String]) -> String? {
        let positions = arguments.indices.filter { arguments[$0] == flag }
        guard positions.count == 1, let index = positions.first, index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func words(_ text: String) throws -> [String] {
        var result: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in text {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { result.append(word); word = ""; started = false }
            } else {
                word.append(character)
                started = true
            }
        }
        guard quote == nil, !escaped else { throw Failure.malformedWords }
        if started { result.append(word) }
        return result
    }

    static func analysis(_ arguments: [String], workspace: URL) throws -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("@") {
                result += try sources(String(argument.dropFirst()), workspace: workspace)
            } else if retainedPairs.contains(argument) || ignoredPairs.contains(argument) {
                guard index + 1 < arguments.count else { throw Failure.missingValue(argument) }
                if retainedPairs.contains(argument) { result += [argument, arguments[index + 1]] }
                index += 1
            } else if argument == "-Xfrontend" {
                index += try skipFrontend(arguments, at: index)
            } else if argument == "-working-directory" {
                guard index + 1 < arguments.count else { throw Failure.missingValue(argument) }
                guard
                    URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.path
                        == workspace.standardizedFileURL.path
                else { throw Failure.unsupported(argument) }
                index += 1
            } else if ignoredFlags.contains(argument) || (argument.hasPrefix("-j") && Int(argument.dropFirst(2)) != nil)
            {
                // Output, scheduling and diagnostic flags do not change the type-checked program.
            } else if retainedFlags.contains(argument) || argument.hasSuffix(".swift")
                || (argument.hasPrefix("-D") && argument.count > 2)
            {
                result.append(argument)
            } else {
                throw Failure.unsupported(argument)
            }
            index += 1
        }
        return result
    }

    private static func sources(_ path: String, workspace: URL) throws -> [String] {
        let file = URL(fileURLWithPath: path, relativeTo: workspace).standardizedFileURL
        guard file.path.hasPrefix(workspace.path + "/"), file.pathExtension == "SwiftFileList",
            file.resolvingSymlinksInPath() == file
        else { throw Failure.unsafeFile(path) }
        let values = try words(String(contentsOf: file, encoding: .utf8))
        guard !values.isEmpty, values.allSatisfy({ $0.hasSuffix(".swift") && !$0.hasPrefix("-") }) else {
            throw Failure.unsafeFile(path)
        }
        return values
    }

    private static func skipFrontend(_ arguments: [String], at index: Int) throws -> Int {
        guard index + 1 < arguments.count else { throw Failure.missingValue("-Xfrontend") }
        if arguments[index + 1] == "-serialize-debugging-options" { return 1 }
        if arguments[index + 1] == "-const-gather-protocols-file", index + 3 < arguments.count,
            arguments[index + 2] == "-Xfrontend"
        {
            return 3
        }
        throw Failure.unsupported("-Xfrontend " + arguments[index + 1])
    }

    private static let retainedPairs: Set<String> = [
        "-module-name", "-target", "-sdk", "-swift-version", "-I", "-F", "-D", "-Xcc",
        "-module-cache-path", "-resource-dir", "-enable-experimental-feature", "-enable-upcoming-feature",
    ]
    private static let retainedFlags: Set<String> = ["-parse-as-library", "-enable-testing"]
    private static let ignoredPairs: Set<String> = [
        "-output-file-map", "-index-store-path", "-emit-module-path", "-emit-objc-header-path",
        "-clang-scanner-module-cache-path", "-sdk-module-cache-path", "-clang-build-session-file",
        "-num-threads",
    ]
    private static let ignoredFlags: Set<String> = [
        "-Onone", "-O", "-Osize", "-g", "-c", "-enable-batch-mode", "-incremental",
        "-use-frontend-parseable-output", "-save-temps", "-no-color-diagnostics", "-explicit-module-build",
        "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-validate-clang-modules-once",
        "-emit-const-values", "-emit-objc-header", "-experimental-emit-module-separately", "-disable-cmo",
        "-whole-module-optimization",
    ]
}
