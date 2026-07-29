import AItingjiCore
import Foundation
import Testing

@Test
func diarizationRuntimeResolverFindsProjectRootUnderDocumentsWhenCurrentDirectoryIsNotRepository() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let currentDirectory = URL(fileURLWithPath: "/Applications")
    let expectedScript = "/Users/tester/Documents/AgendAI/Tools/voiceprint_sidecar/server.py"

    let root = DiarizationSidecarRuntimeResolver.resolveProjectRoot(
        currentDirectoryURL: currentDirectory,
        homeDirectoryURL: home,
        fileExists: { $0 == expectedScript }
    )

    #expect(root.path == "/Users/tester/Documents/AgendAI")
}

@Test
func diarizationRuntimeResolverFindsPy312PythonUnderDocumentsWhenCurrentDirectoryIsNotRepository() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let currentDirectory = URL(fileURLWithPath: "/Applications")
    let expectedPython = "/Users/tester/Documents/AgendAI/.voiceprint-py312/bin/python"

    let python = DiarizationSidecarRuntimeResolver.resolvePythonExecutable(
        projectRootURL: currentDirectory,
        homeDirectoryURL: home,
        isExecutableFile: { $0 == expectedPython }
    )

    #expect(python?.path == expectedPython)
}

@Test
func diarizationRuntimeResolverReturnsEnvironmentRootWithExecutable() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let projectRoot = URL(fileURLWithPath: "/Applications/会小纪.app/Contents/Resources")
    let appSupport = URL(fileURLWithPath: "/Users/tester/Library/Application Support")
    let expectedPython = "/Users/tester/Documents/AgendAI/.voiceprint-py312/bin/python"

    let environment = DiarizationSidecarRuntimeResolver.resolvePythonEnvironment(
        projectRootURL: projectRoot,
        homeDirectoryURL: home,
        applicationSupportURL: appSupport,
        isExecutableFile: { $0 == expectedPython }
    )

    #expect(environment?.rootURL.path == "/Users/tester/Documents/AgendAI")
    #expect(environment?.executableURL.path == expectedPython)
}

@Test
func diarizationRuntimeResolverPrefersApplicationSupportPythonForInstalledApp() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let projectRoot = URL(fileURLWithPath: "/Applications/会小纪.app/Contents/Resources")
    let appSupport = URL(fileURLWithPath: "/Users/tester/Library/Application Support")
    let expectedPython = "/Users/tester/Library/Application Support/会小纪/VoiceprintSidecar/.voiceprint-py312/bin/python"

    let python = DiarizationSidecarRuntimeResolver.resolvePythonExecutable(
        projectRootURL: projectRoot,
        homeDirectoryURL: home,
        applicationSupportURL: appSupport,
        isExecutableFile: { $0 == expectedPython }
    )

    #expect(python?.path == expectedPython)
}

@Test
func diarizationRuntimeResolverDoesNotFallbackToProjectPythonWhenDisabled() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let projectRoot = URL(fileURLWithPath: "/Applications/会小纪.app/Contents/Resources")
    let appSupport = URL(fileURLWithPath: "/Users/tester/Library/Application Support")
    let projectPython = "/Users/tester/Documents/AgendAI/.voiceprint-py312/bin/python"

    let python = DiarizationSidecarRuntimeResolver.resolvePythonExecutable(
        projectRootURL: projectRoot,
        homeDirectoryURL: home,
        applicationSupportURL: appSupport,
        allowProjectFallback: false,
        isExecutableFile: { $0 == projectPython }
    )

    #expect(python == nil)
}

@Test
func diarizationRuntimeResolverBuildsSetupScriptPath() {
    let projectRoot = URL(fileURLWithPath: "/Users/tester/Documents/AgendAI")

    let setupScript = DiarizationSidecarRuntimeResolver.setupScriptURL(projectRootURL: projectRoot)

    #expect(setupScript.path == "/Users/tester/Documents/AgendAI/scripts/setup_voiceprint_sidecar.sh")
}

@Test
func diarizationRuntimeResolverExplainsMissingPythonEnvironment() {
    let projectRoot = URL(fileURLWithPath: "/Users/tester/Documents/AgendAI")
    let resourceSetupScript = URL(fileURLWithPath: "/Applications/会小纪.app/Contents/Resources/scripts/setup_voiceprint_sidecar.sh")

    let message = DiarizationSidecarRuntimeResolver.missingPythonEnvironmentMessage(
        projectRootURL: projectRoot,
        setupScriptURL: resourceSetupScript
    )

    #expect(message.contains("/Users/tester/Documents/AgendAI/.voiceprint-py312/bin/python"))
    #expect(message.contains("sh /Applications/会小纪.app/Contents/Resources/scripts/setup_voiceprint_sidecar.sh"))
}

@Test
func diarizationRuntimeResolverExplainsMissingFunASRDependency() {
    let projectRoot = URL(fileURLWithPath: "/Users/tester/Documents/AgendAI")

    let message = DiarizationSidecarRuntimeResolver.missingDependencyMessage(
        "ModuleNotFoundError: No module named 'funasr'",
        projectRootURL: projectRoot
    )

    #expect(message?.contains("本机说话人分离依赖缺失") == true)
    #expect(message?.contains("setup_voiceprint_sidecar.sh") == true)
}

@Test
func diarizationRuntimeResolverUsesBundledSidecarAndSetupScriptsForInstalledApp() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let currentDirectory = URL(fileURLWithPath: "/Users/tester/Documents/AgendAI")
    let bundleResources = URL(fileURLWithPath: "/Applications/会小纪.app/Contents/Resources")
    let bundledServer = "/Applications/会小纪.app/Contents/Resources/voiceprint_sidecar/server.py"
    let bundledSetup = "/Applications/会小纪.app/Contents/Resources/scripts/setup_voiceprint_sidecar.sh"

    let scriptURL = DiarizationSidecarRuntimeResolver.resolveSidecarScriptURL(
        currentDirectoryURL: currentDirectory,
        homeDirectoryURL: home,
        bundleResourcesURL: bundleResources,
        fileExists: { $0 == bundledServer }
    )
    let setupURL = DiarizationSidecarRuntimeResolver.resolveSetupScriptURL(
        currentDirectoryURL: currentDirectory,
        homeDirectoryURL: home,
        bundleResourcesURL: bundleResources,
        fileExists: { $0 == bundledSetup }
    )

    #expect(scriptURL?.path == bundledServer)
    #expect(setupURL?.path == bundledSetup)
}

@Test
func diarizationRuntimeResolverKeepsInstalledSidecarEnvironmentInApplicationSupport() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let bundleResources = URL(fileURLWithPath: "/Applications/会小纪.app/Contents/Resources")
    let appSupport = URL(fileURLWithPath: "/Users/tester/Library/Application Support")
    let expectedPython = "/Users/tester/Library/Application Support/会小纪/VoiceprintSidecar/.voiceprint-py312/bin/python"

    let environment = DiarizationSidecarRuntimeResolver.resolvePythonEnvironment(
        projectRootURL: bundleResources,
        homeDirectoryURL: home,
        applicationSupportURL: appSupport,
        allowProjectFallback: false,
        isExecutableFile: { $0 == expectedPython }
    )

    #expect(environment?.rootURL.path == "/Users/tester/Library/Application Support/会小纪/VoiceprintSidecar")
    #expect(environment?.executableURL.path == expectedPython)
}
