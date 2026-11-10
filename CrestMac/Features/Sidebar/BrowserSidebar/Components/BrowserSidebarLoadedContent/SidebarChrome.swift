import SwiftUI

/// The window's address and navigation stay in place while Space contents move
/// underneath. Their native field and popover identities belong to this leaf.
struct SidebarChrome: View {
    let context: BrowserSidebarContext
    let pages: BrowserPagePool
    let address: Binding<String>
    let isAddressEditing: Binding<Bool>
    let addressFocusRequest: Int
    let activateAddress: () -> Void
    let submitAddress: () -> Void
    let commandSurfaceNamespace: Namespace.ID
    let commandPaletteHandoff: BrowserCommandPaletteHandoff

    var body: some View {
        if let space = selectedSpace {
            let isLocked = context.spaceAccess.isLocked(space)

            VStack(spacing: 0) {
                SidebarNavigationStrip(context: context, pages: pages)

                if context.utilityPresentation.surface == nil {
                    SidebarAddressBandHost(
                        space: space,
                        context: context,
                        pages: pages,
                        address: address,
                        isAddressEditing: isAddressEditing,
                        addressFocusRequest: addressFocusRequest,
                        activateAddress: activateAddress,
                        submitAddress: submitAddress,
                        commandSurfaceNamespace: commandSurfaceNamespace,
                        commandPaletteHandoff: commandPaletteHandoff,
                        siteControlPresentationChanged: {
                            context.utilityPresentation.setSiteControlPresented($0)
                        },
                        siteControlContextMenuPresentationChanged: {
                            context.utilityPresentation.setSiteControlContextMenuPresented($0)
                        }
                    )
                }
            }
            .modifier(SpaceColorScheme(branding: space.settings.look))
            .modifier(SpaceForegroundBlend(spaces: context.availableSpaces, selectedSpaceID: space.id))
            .blur(radius: isLocked ? BrowserSidebarMetrics.lockedSpaceBlurRadius : 0)
            .redacted(reason: isLocked ? .placeholder : [])
            .allowsHitTesting(!isLocked)
            .accessibilityHidden(isLocked)
        }
    }

    /// The Space the window shows, unless it is being deleted.
    private var selectedSpace: SpaceModel? {
        context.browser.shownSpace
    }
}

/// The navigation controls, which follow the active tab's history and loading.
/// Their reads stay in this leaf, so a tab switch redraws the strip without
/// running the chrome around it again.
private struct SidebarNavigationStrip: View {
    let context: BrowserSidebarContext
    let pages: BrowserPagePool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BrowserSidebarNavigationControls(
            port: BrowserSidebarNavigationPort(
                pages: pages, browser: context.browser, showHistory: context.chromeActions.presentHistory),
            capabilities: context.capabilities
        )
        .contentTransition(.opacity)
        .background {
            // Only the empty navigation-strip background acts as the
            // title bar. Controls and tab gestures keep their input.
            BrowserWindowTitleBarSurface()
        }
        // Another tab's history shows at once, as every browser switches
        // tabs; a fade on each switch redraws the strip every frame.
        .animation(nil, value: pages.activeTabID)
        .animation(
            SpacePagerSettlement.standardAnimation.unlessReducingMotion(reduceMotion),
            value: [pages.canGoBack, pages.canGoForward, pages.activePage?.live.isLoading == true]
        )
    }
}

/// The address band, reading the Space's selected tab in its own body so a
/// tab switch does not run the chrome around it again.
private struct SidebarAddressBandHost: View {
    let space: SpaceModel
    let context: BrowserSidebarContext
    let pages: BrowserPagePool
    let address: Binding<String>
    let isAddressEditing: Binding<Bool>
    let addressFocusRequest: Int
    let activateAddress: () -> Void
    let submitAddress: () -> Void
    let commandSurfaceNamespace: Namespace.ID
    let commandPaletteHandoff: BrowserCommandPaletteHandoff
    let siteControlPresentationChanged: (Bool) -> Void
    let siteControlContextMenuPresentationChanged: (Bool) -> Void

    var body: some View {
        SpaceSidebarAddressBand(
            space: space,
            offersSiteControls: !context.browser.isDeleting(space.id),
            selectedTabID: context.browser.selectedTabID(in: space.id),
            pages: pages,
            capabilities: context.capabilities,
            address: address,
            isAddressEditing: isAddressEditing,
            addressFocusRequest: addressFocusRequest,
            activateAddress: activateAddress,
            submitAddress: submitAddress,
            commandSurfaceNamespace: commandSurfaceNamespace,
            commandPaletteHandoff: commandPaletteHandoff,
            siteControlPresentationChanged: siteControlPresentationChanged,
            siteControlContextMenuPresentationChanged: siteControlContextMenuPresentationChanged
        )
    }
}
