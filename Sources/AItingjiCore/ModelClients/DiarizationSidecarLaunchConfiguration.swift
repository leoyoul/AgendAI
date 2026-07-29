import Foundation

public enum DiarizationSidecarBackend: Equatable, Sendable {
    case production
    case testDeterministic

    public var argumentValue: String {
        switch self {
        case .production:
            return "funasr"
        case .testDeterministic:
            return "deterministic"
        }
    }
}

public struct DiarizationSidecarLaunchConfiguration: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectoryURL: URL?
    public var environment: [String: String]
    public var missingPythonMessage: String?
    public var sidecarErrorMessageTransform: @Sendable (String) -> String

    public init(
        scriptURL: URL,
        backend: DiarizationSidecarBackend,
        huggingFaceToken: String?,
        pythonExecutableURL: URL? = nil,
        workingDirectoryURL: URL? = nil,
        missingPythonMessage: String? = nil,
        sidecarErrorMessageTransform: @escaping @Sendable (String) -> String = { $0 }
    ) {
        if let pythonExecutableURL {
            self.executableURL = pythonExecutableURL
            self.arguments = [
                scriptURL.path,
                "--mode",
                "jsonl",
                "--backend",
                backend.argumentValue
            ]
        } else {
            self.executableURL = URL(fileURLWithPath: "/__tinglan_missing_voiceprint_python__")
            self.arguments = []
        }
        self.workingDirectoryURL = workingDirectoryURL
        self.missingPythonMessage = missingPythonMessage
        self.sidecarErrorMessageTransform = sidecarErrorMessageTransform
        var environment: [String: String] = [:]
        if let huggingFaceToken, !huggingFaceToken.isEmpty {
            environment["HF_TOKEN"] = huggingFaceToken
        }
        if backend == .testDeterministic {
            environment["TINGLAN_DIARIZATION_TEST_BACKEND"] = "1"
        }
        self.environment = environment
    }

    public static func == (lhs: DiarizationSidecarLaunchConfiguration, rhs: DiarizationSidecarLaunchConfiguration) -> Bool {
        lhs.executableURL == rhs.executableURL
            && lhs.arguments == rhs.arguments
            && lhs.workingDirectoryURL == rhs.workingDirectoryURL
            && lhs.environment == rhs.environment
            && lhs.missingPythonMessage == rhs.missingPythonMessage
    }
}
