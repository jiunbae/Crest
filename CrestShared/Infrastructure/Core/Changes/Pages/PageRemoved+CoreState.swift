import Foundation

extension PageRemoved {
    @MainActor func apply(to state: CoreState) {
        state.removePage(pageID)
    }
}
