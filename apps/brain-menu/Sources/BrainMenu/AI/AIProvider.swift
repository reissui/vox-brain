import Foundation

enum AIProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case disabled
    case codex
    case claude
    case advanced

    static let providerNote =
        "Transcript text is sent to the selected provider; provider billing/credits apply."

    var displayName: String {
        switch self {
        case .disabled: "Disabled"
        case .codex: "Codex CLI"
        case .claude: "Claude CLI"
        case .advanced: "Custom Command"
        }
    }

    var defaultExecutableName: String? {
        switch self {
        case .disabled, .advanced: nil
        case .codex: "codex"
        case .claude: "claude"
        }
    }

    func commandPreview(executablePath: String?, model: String?) -> String? {
        guard self != .disabled else { return nil }
        let executable = executablePath ?? defaultExecutableName ?? "Choose executable"
        let modelArguments = model.map { " --model \($0)" } ?? ""
        switch self {
        case .disabled:
            return nil
        case .codex:
            return "\(executable) exec --skip-git-repo-check --ephemeral --sandbox read-only --ignore-user-config --ignore-rules --output-schema <Brain schema>\(modelArguments) -"
        case .claude:
            return "\(executable) -p --safe-mode --tools <none> --no-session-persistence --output-format json --json-schema <Brain schema>\(modelArguments)"
        case .advanced:
            return executable
        }
    }
}

enum AIContextChoice: String, Codable, CaseIterable, Equatable, Sendable {
    case rich
    case plain
}

struct AIProviderConfiguration: Equatable, Sendable {
    static let defaultTimeout: TimeInterval = 300
    static let maximumTimeout: TimeInterval = 900

    var provider: AIProvider
    var executableURL: URL?
    var arguments: [String]
    var model: String?
    var timeout: TimeInterval
    var contextChoice: AIContextChoice

    init(
        provider: AIProvider = .disabled,
        executableURL: URL? = nil,
        arguments: [String] = [],
        model: String? = nil,
        timeout: TimeInterval = AIProviderConfiguration.defaultTimeout,
        contextChoice: AIContextChoice = .rich
    ) {
        self.provider = provider
        self.executableURL = executableURL
        self.arguments = arguments
        self.model = model
        self.timeout = Self.boundedTimeout(timeout)
        self.contextChoice = contextChoice
    }

    static func boundedTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return defaultTimeout }
        return min(value, maximumTimeout)
    }

    /// Preset providers own their executable and argv, but may retain a model.
    /// Only Advanced may retain user-supplied process configuration.
    func canonicalized() -> Self {
        var canonical = self
        switch provider {
        case .disabled:
            canonical.executableURL = nil
            canonical.arguments = []
            canonical.model = nil
        case .codex, .claude:
            canonical.executableURL = nil
            canonical.arguments = []
            canonical.model = canonical.model?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if canonical.model?.isEmpty == true {
                canonical.model = nil
            }
        case .advanced:
            break
        }
        return canonical
    }
}

enum AIConnectionState: Equatable, Sendable {
    case disabled
    case missingExecutable
    case unauthenticated
    case invalidModel
    case timeout
    case schemaFailure
    case ready
}

protocol AIProviding: Sendable {
    func run(prompt: String, jsonSchema: Data) async throws -> Data
    func testConnection() async -> AIConnectionState
}

enum AIProviderError: Error, Equatable, LocalizedError, Sendable {
    case disabled
    case missingExecutable
    case invalidExecutable
    case invalidArguments
    case invalidModel
    case unauthenticated
    case timedOut
    case outputTooLarge
    case schemaFailure
    case launchFailed
    case commandFailed(exitStatus: Int32)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "The local AI provider is disabled."
        case .missingExecutable:
            "The selected provider executable could not be found."
        case .invalidExecutable:
            "The selected file is not a regular executable."
        case .invalidArguments:
            "Custom command arguments may not contain provider credentials."
        case .invalidModel:
            "The model identifier is invalid or unavailable."
        case .unauthenticated:
            "The provider CLI is not authenticated. Sign in with the CLI and try again."
        case .timedOut:
            "The provider CLI timed out."
        case .outputTooLarge:
            "The provider CLI returned more output than Brain accepts."
        case .schemaFailure:
            "The provider response did not match the required schema."
        case .launchFailed:
            "The provider CLI could not be started."
        case .commandFailed(let exitStatus):
            "The provider CLI exited unsuccessfully (status \(exitStatus))."
        }
    }
}

enum AIProviderValidation {
    private static let maximumModelLength = 128
    private static let allowedModelCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"
    )
    private static let credentialFlags = [
        "--api-key", "--apikey", "--token", "--access-token", "--auth-token",
        "--authorization", "--bearer", "-apikey",
    ]

    static func validatedModel(_ model: String?) throws -> String? {
        guard let model else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximumModelLength,
              trimmed.unicodeScalars.allSatisfy({ allowedModelCharacters.contains($0) }),
              trimmed.first?.isLetter == true || trimmed.first?.isNumber == true else {
            throw AIProviderError.invalidModel
        }
        return trimmed
    }

    static func validateAdvancedArguments(_ arguments: [String]) throws {
        let lowercased = arguments.map { $0.lowercased() }
        for (index, argument) in lowercased.enumerated() {
            if credentialFlags.contains(where: {
                argument == $0 || argument.hasPrefix("\($0)=")
            }) {
                throw AIProviderError.invalidArguments
            }
            if index > 0, credentialFlags.contains(lowercased[index - 1]) {
                throw AIProviderError.invalidArguments
            }
        }
    }
}

enum AICommandLineError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case unmatchedQuote
    case trailingEscape

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter an executable and any arguments."
        case .unmatchedQuote:
            "The command contains an unmatched quote."
        case .trailingEscape:
            "The command ends with an incomplete escape."
        }
    }
}

enum AICommandLine {
    static func parse(_ command: String) throws -> [String] {
        enum Quote {
            case single
            case double
        }

        var tokens: [String] = []
        var token = ""
        var quote: Quote?
        var isEscaping = false
        var hasTokenContent = false

        func finishToken() {
            guard hasTokenContent else { return }
            tokens.append(token)
            token = ""
            hasTokenContent = false
        }

        for character in command {
            if isEscaping {
                token.append(character)
                hasTokenContent = true
                isEscaping = false
                continue
            }

            switch quote {
            case .single:
                if character == "'" {
                    quote = nil
                } else {
                    token.append(character)
                    hasTokenContent = true
                }
            case .double:
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    isEscaping = true
                } else {
                    token.append(character)
                    hasTokenContent = true
                }
            case nil:
                if character == "'" {
                    quote = .single
                    hasTokenContent = true
                } else if character == "\"" {
                    quote = .double
                    hasTokenContent = true
                } else if character == "\\" {
                    isEscaping = true
                    hasTokenContent = true
                } else if character.isWhitespace {
                    finishToken()
                } else {
                    token.append(character)
                    hasTokenContent = true
                }
            }
        }

        guard !isEscaping else { throw AICommandLineError.trailingEscape }
        guard quote == nil else { throw AICommandLineError.unmatchedQuote }
        finishToken()
        guard !tokens.isEmpty else { throw AICommandLineError.empty }
        return tokens
    }

    static func render(executable: URL?, arguments: [String]) -> String {
        guard let executable else { return "" }
        return render(executableName: executable.path, arguments: arguments)
    }

    static func render(executableName: String, arguments: [String]) -> String {
        ([executableName] + arguments)
            .map(renderToken)
            .joined(separator: " ")
    }

    private static func renderToken(_ token: String) -> String {
        guard !token.isEmpty else { return "''" }
        let safeCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:=-"
        )
        if token.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return token
        }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum AILocalCLICommandTemplateError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedExecutable
    case missingMode
    case unsupportedArgument
    case missingModel
    case duplicateModel
    case librarianRequiresCodex

    var errorDescription: String? {
        switch self {
        case .unsupportedExecutable:
            "Use a Codex or Claude CLI command."
        case .missingMode:
            "Codex commands must start with “codex exec”; Claude commands must start with “claude -p”."
        case .unsupportedArgument:
            "The template contains an argument that is not supported."
        case .missingModel:
            "Add a model after --model, or remove the flag."
        case .duplicateModel:
            "The template can select only one model."
        case .librarianRequiresCodex:
            "The Librarian command must start with “codex exec”."
        }
    }
}

struct AILocalCLICommandTemplate: Equatable, Sendable {
    static let defaultCommand = "codex exec --skip-git-repo-check"
    static let exampleCommand =
        "codex exec --skip-git-repo-check --model gpt-5.6-sol"

    let provider: AIProvider
    let model: String?

    static func parse(_ command: String) throws -> Self {
        let tokens = try AICommandLine.parse(command)
        try AIProviderValidation.validateAdvancedArguments(Array(tokens.dropFirst()))

        switch tokens[0] {
        case "codex":
            guard tokens.count >= 2, tokens[1] == "exec" else {
                throw AILocalCLICommandTemplateError.missingMode
            }
            return try parseArguments(
                Array(tokens.dropFirst(2)),
                provider: .codex,
                ignoredFlags: ["--skip-git-repo-check", "-"]
            )
        case "claude":
            guard tokens.count >= 2, ["-p", "--print"].contains(tokens[1]) else {
                throw AILocalCLICommandTemplateError.missingMode
            }
            return try parseArguments(
                Array(tokens.dropFirst(2)),
                provider: .claude,
                ignoredFlags: []
            )
        default:
            throw AILocalCLICommandTemplateError.unsupportedExecutable
        }
    }

    static func render(configuration: AIProviderConfiguration) -> String {
        switch configuration.provider {
        case .disabled:
            ""
        case .codex:
            render(provider: .codex, model: configuration.model)
        case .claude:
            render(provider: .claude, model: configuration.model)
        case .advanced:
            configuration.executableURL.map {
                AICommandLine.render(
                    executableName: $0.lastPathComponent,
                    arguments: configuration.arguments
                )
            } ?? ""
        }
    }

    static func render(provider: AIProvider, model: String?) -> String {
        let base = switch provider {
        case .codex:
            defaultCommand
        case .claude:
            "claude -p"
        case .disabled, .advanced:
            ""
        }
        guard let model, !model.isEmpty else { return base }
        return "\(base) --model \(model)"
    }

    private static func parseArguments(
        _ arguments: [String],
        provider: AIProvider,
        ignoredFlags: Set<String>
    ) throws -> Self {
        var model: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if ignoredFlags.contains(argument) {
                index += 1
                continue
            }
            if argument == "--model" || argument == "-m" {
                guard model == nil else {
                    throw AILocalCLICommandTemplateError.duplicateModel
                }
                guard arguments.indices.contains(index + 1) else {
                    throw AILocalCLICommandTemplateError.missingModel
                }
                model = try AIProviderValidation.validatedModel(arguments[index + 1])
                index += 2
                continue
            }
            if argument.hasPrefix("--model=") {
                guard model == nil else {
                    throw AILocalCLICommandTemplateError.duplicateModel
                }
                model = try AIProviderValidation.validatedModel(
                    String(argument.dropFirst("--model=".count))
                )
                guard model != nil else {
                    throw AILocalCLICommandTemplateError.missingModel
                }
                index += 1
                continue
            }
            throw AILocalCLICommandTemplateError.unsupportedArgument
        }
        return Self(provider: provider, model: model)
    }
}
