import Foundation

public enum CLIArguments {
    /// Options that take a value in the next argument.
    public static let valueOptions: Set<String> = ["--hours", "--interval", "--only"]

    /// The words that are not options and not option values: `route --hours 6 review` gives `route review`.
    /// `-h` counts as a word so that `quotapilot -h` still reaches the help command.
    public static func positional(_ arguments: [String], valueOptions: Set<String> = CLIArguments.valueOptions) -> [String] {
        var words: [String] = [], skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if valueOptions.contains(argument) { skipNext = true; continue }
            if !argument.hasPrefix("-") || argument == "-h" { words.append(argument) }
        }
        return words
    }
}
