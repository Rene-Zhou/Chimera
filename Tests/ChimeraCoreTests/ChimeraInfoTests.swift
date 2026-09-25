import Testing
@testable import ChimeraCore

@Test func productIdentity() {
    #expect(ChimeraInfo.name == "Chimera")
    #expect(ChimeraInfo.codename == "YAMCR")
}
