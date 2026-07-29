import AItingjiCore
import Testing

@Test
func libraryPlaceholderPolicyMatchesOnlyGeneratedNames() {
    #expect(LibraryPlaceholderPolicy.isGeneratedPersonName("新同事"))
    #expect(LibraryPlaceholderPolicy.isGeneratedPersonName("新同事 1"))
    #expect(LibraryPlaceholderPolicy.isGeneratedPersonName("新同事2"))
    #expect(!LibraryPlaceholderPolicy.isGeneratedPersonName("新同事复盘"))
    #expect(!LibraryPlaceholderPolicy.isGeneratedPersonName("老同事 1"))

    #expect(LibraryPlaceholderPolicy.isGeneratedTerminologyName("新专有名词 3"))
    #expect(!LibraryPlaceholderPolicy.isGeneratedTerminologyName("新专有名词规范"))
}
