import SwiftUI

/// Fixed address controls. The pager owns the changing extension-strip seam
/// so semantic selection cannot resize the viewport during a Space transition.
struct SpaceSidebarAddressBand: View {
    let space: SpaceModel
    /// Whether the site controls act for `space`; they offer nothing while it
    /// is being deleted.
    let offersSiteControls: Bool
    /// The tab this window shows in `space`.
    let selectedTabID: UUID?
    let pages: BrowserPagePool
    let capabilities: BrowserInteractionCapabilities
    let address: Binding<String>
    let isAddressEditing: Binding<Bool>
    let addressFocusRequest: Int
    let activateAddress: () -> Void
    let submitAddress: () -> Void
    let commandSurfaceNamespace: Namespace.ID
    let commandPaletteHandoff: BrowserCommandPaletteHandoff
    let siteControlPresentationChanged: (Bool) -> Void
    let siteControlContextMenuPresentationChanged: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Found once: each lookup reads the pool's observed residency, and
        // every control here asks about the same page.
        let page = displayedPage
        let secure = isSecure(page)
        let control = siteControl(page)
        return BrowserSidebarAddressField(
            configuration: addressConfiguration(page: page, isSecure: secure, hasActiveSite: control != nil)
        ) {
            if let control {
                BrowserAddressSecurityButton(
                    page: control.page,
                    isSecure: secure
                )
            }
        } trailingAccessory: {
            if let control {
                if let copyURLPage = copyURLPage(page) {
                    BrowserAddressCopyURLButton(page: copyURLPage)
                }
                BrowserSiteControlButton(configuration: control)
            }
        }
        .contentTransition(.opacity)
        .animation(
            SpacePagerSettlement.standardAnimation.unlessReducingMotion(reduceMotion),
            value: isAddressEditing.wrappedValue ? nil : address.wrappedValue
        )
        .padding(.horizontal, BrowserSidebarMetrics.layerInset)

    }

    private func addressConfiguration(
        page: BrowserPage?, isSecure: Bool, hasActiveSite: Bool
    ) -> BrowserSidebarAddressFieldConfiguration {
        BrowserSidebarAddressFieldConfiguration(
            text: address,
            isEditing: isAddressEditing,
            focusRequest: addressFocusRequest,
            isSecure: isSecure,
            progress: page?.estimatedProgress ?? 0,
            isLoading: page?.live.isLoading == true,
            hasResidentPage: page != nil,
            hasActiveSite: hasActiveSite,
            capabilities: capabilities,
            activate: activateAddress,
            submit: submitAddress,
            morphNamespace: commandSurfaceNamespace,
            spaceID: space.id,
            commandPaletteHandoff: commandPaletteHandoff,
            branding: space.settings.look
        )
    }

    private var selectedTab: TabStateModel? {
        selectedTabID.flatMap { space.shownTab($0) }
    }

    private var displayedPage: BrowserPage? {
        guard let selectedTabID else { return nil }
        let assignment = BrowserTabRuntimeAssignment(
            tabID: selectedTabID, spaceID: space.id, profileID: space.profileID
        )
        return pages.activePage(matching: assignment)
    }

    private func isSecure(_ page: BrowserPage?) -> Bool {
        if let page { return page.live.security.isSecure }
        return selectedTab?.url.flatMap(URL.init(string:))?.scheme?.lowercased() == "https"
    }

    /// The page the Copy URL button copies, while the person turned the
    /// button on and the page has an address to copy.
    private func copyURLPage(_ page: BrowserPage?) -> BrowserPage? {
        guard BrowserDeviceAppearanceStore.shared.address.showsCopyURLButton,
            let page, page.live.documentURL != nil
        else { return nil }
        return page
    }

    private func siteControl(_ page: BrowserPage?) -> BrowserSiteControlConfiguration? {
        guard offersSiteControls, let page, page.live.displayURL != nil else {
            return nil
        }
        return BrowserSiteControlConfiguration(
            page: page,
            space: space,
            selectedTabID: selectedTabID,
            permissionCenter: pages.permissionCenter,
            presentationChanged: siteControlPresentationChanged,
            contextMenuPresentationChanged:
                siteControlContextMenuPresentationChanged
        )
    }
}
