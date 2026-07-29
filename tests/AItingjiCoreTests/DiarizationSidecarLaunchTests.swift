import AItingjiCore
import Foundation
import Testing

@Test
func productionDiarizationLaunchUsesFunASRBackend() {
    let launch = DiarizationSidecarLaunchConfiguration(
        scriptURL: URL(fileURLWithPath: "/repo/Tools/voiceprint_sidecar/server.py"),
        backend: .production,
        huggingFaceToken: "hf-token",
        pythonExecutableURL: URL(fileURLWithPath: "/repo/.voiceprint-py312/bin/python")
    )

    #expect(launch.arguments.contains("--backend"))
    #expect(launch.arguments.contains("funasr"))
    #expect(!launch.arguments.contains("deterministic"))
    #expect(launch.environment["HF_TOKEN"] == "hf-token")
}

@Test
func productionDiarizationLaunchDoesNotInjectTokenWhenTokenIsNil() {
    let launch = DiarizationSidecarLaunchConfiguration(
        scriptURL: URL(fileURLWithPath: "/repo/Tools/voiceprint_sidecar/server.py"),
        backend: .production,
        huggingFaceToken: nil,
        pythonExecutableURL: URL(fileURLWithPath: "/repo/.voiceprint-py312/bin/python")
    )

    #expect(launch.environment["HF_TOKEN"] == nil)
}

@Test
func productionDiarizationLaunchUsesMissingExecutableWhenPythonIsUnavailable() {
    let launch = DiarizationSidecarLaunchConfiguration(
        scriptURL: URL(fileURLWithPath: "/Applications/会小纪.app/Contents/Resources/voiceprint_sidecar/server.py"),
        backend: .production,
        huggingFaceToken: nil,
        pythonExecutableURL: nil,
        missingPythonMessage: "请先运行 setup_voiceprint_sidecar.sh"
    )

    #expect(launch.executableURL.path == "/__tinglan_missing_voiceprint_python__")
    #expect(launch.arguments.isEmpty)
    #expect(launch.missingPythonMessage == "请先运行 setup_voiceprint_sidecar.sh")
}

@Test
func deterministicDiarizationBackendIsExplicitlyTestOnly() {
    let launch = DiarizationSidecarLaunchConfiguration(
        scriptURL: URL(fileURLWithPath: "/repo/Tools/voiceprint_sidecar/server.py"),
        backend: .testDeterministic,
        huggingFaceToken: nil,
        pythonExecutableURL: URL(fileURLWithPath: "/repo/.voiceprint-py312/bin/python")
    )

    #expect(launch.arguments.contains("deterministic"))
    #expect(launch.environment["TINGLAN_DIARIZATION_TEST_BACKEND"] == "1")
}
