import Testing
import Foundation
@testable import InfraredConverter

@Suite
struct DocumentStateTests {
    @Test
    func startsWithNoSelection() {
        let state = DocumentState()
        #expect(state.selectedFileURL == nil)
    }

    @Test
    func selectingURLUpdatesState() {
        let state = DocumentState()
        let url = URL(fileURLWithPath: "/tmp/example.orf")

        state.select(url)

        #expect(state.selectedFileURL == url)
    }
}
