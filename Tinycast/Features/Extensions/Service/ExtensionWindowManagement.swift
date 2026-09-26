import AppKit
@preconcurrency import ApplicationServices

/// Raycast's `WindowManagement`, over the window feature's AX layer and in its top-left space.
/// See docs/features/extensions.md#window-management.
@MainActor
final class ExtensionWindowManagement {
    enum Failure: LocalizedError {
        case accessibility
        case noWindow
        case unknownWindow(String)
        case fullScreen
        case notPositionable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .accessibility: "WindowManagement needs the Accessibility permission."
            case .noWindow: "There is no active window to act on."
            case .unknownWindow(let id):
                "Unknown window id '\(id)'; read it from getActiveWindow in this command run."
            case .fullScreen: "The window is in full screen; leave full screen before moving it."
            case .notPositionable: "The window cannot be moved."
            case .writeFailed: "The window refused the new bounds."
            }
        }
    }

    private struct Handle {
        let app: NSRunningApplication
        let application: AXUIElement
        let window: AXUIElement
    }

    /// An AX element has no public identity, so an id resolves only within the bridge that issued it.
    private var handles: [String: Handle] = [:]

    func perform(
        method: String, arguments: [RenderValue], target: NSRunningApplication?
    ) throws -> Any? {
        switch method {
        case "desktops":
            return desktops(of: target)
        case "activeWindow":
            let (handle, screens) = try activeWindow(of: target)
            return describe(handle, active: true, screens: screens)
        case "windowsOnActiveDesktop":
            return try windowsOnActiveDesktop(of: target)
        case "setWindowBounds":
            try setBounds(arguments.first?.objectValue ?? [:])
            return nil
        default:
            throw ExtensionHostError.unknown("windowManagement.\(method)")
        }
    }

    func reset() {
        handles.removeAll()
    }

    // MARK: - Reading

    private static func screens() -> [WindowPlacementEngine.Screen] {
        AXScreens.converted(NSScreen.screens, geometry: AXGeometry(screens: NSScreen.screens))
    }

    private func activeWindow(
        of target: NSRunningApplication?
    ) throws -> (Handle, [WindowPlacementEngine.Screen]) {
        guard Permissions.ensureAccessibility() else { throw Failure.accessibility }
        guard let app = target, !app.isTerminated,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw Failure.noWindow }
        let application = AXWindowAccess.application(for: app.processIdentifier)
        guard let window = AXWindowAccess.targetWindow(in: application) else {
            throw Failure.noWindow
        }
        AXUIElementSetMessagingTimeout(window, AXWindowAccess.messagingTimeout)
        return (Handle(app: app, application: application, window: window), Self.screens())
    }

    /// Spaces have no public API, so a desktop is a display and its id is the display's.
    private func desktops(of target: NSRunningApplication?) -> [[String: Any]] {
        let screens = Self.screens()
        let active =
            (try? activeWindow(of: target))
            .flatMap { handle, _ in AXWindowAccess.frame(of: handle.window) }
            .flatMap { WindowPlacementEngine.screen(containing: $0, in: screens) }?.id
            ?? screens.first?.id
        return screens.map { screen in
            [
                "id": String(screen.id), "screenId": String(screen.id),
                "active": screen.id == active, "type": "User",
                "size": ["width": screen.frame.width, "height": screen.frame.height],
                "frame": Self.bounds(screen.frame),
                "visibleFrame": Self.bounds(screen.visibleFrame)
            ]
        }
    }

    private func windowsOnActiveDesktop(of target: NSRunningApplication?) throws -> [[String: Any]] {
        let (focused, screens) = try activeWindow(of: target)
        guard let frame = AXWindowAccess.frame(of: focused.window),
            let desktop = WindowPlacementEngine.screen(containing: frame, in: screens)
        else { return [] }
        let snapshot = WindowInventory.snapshot()
        return snapshot.windows.compactMap { window in
            guard let element = snapshot.elements[window.handle],
                WindowPlacementEngine.screen(containing: window.frame, in: screens)?.id
                    == desktop.id
            else { return nil }
            let handle = Handle(
                app: element.app, application: element.application, window: element.window)
            return describe(
                handle, active: CFEqual(element.window, focused.window), screens: screens)
        }
    }

    private func describe(
        _ handle: Handle, active: Bool, screens: [WindowPlacementEngine.Screen]
    ) -> [String: Any] {
        let frame = AXWindowAccess.frame(of: handle.window) ?? .zero
        let id = register(handle, frame: frame)
        var application: [String: Any] = [
            "name": handle.app.localizedName ?? "",
            "localizedName": handle.app.localizedName ?? "",
            "bundleId": handle.app.bundleIdentifier ?? NSNull()
        ]
        if let path = handle.app.bundleURL?.path { application["path"] = path }
        return [
            "id": id, "active": active, "application": application,
            "bounds": AXWindowAccess.isFullScreen(handle.window)
                ? "fullscreen" as Any : Self.bounds(frame),
            "desktopId": WindowPlacementEngine.screen(containing: frame, in: screens)
                .map { String($0.id) } ?? "",
            "positionable": AXWindowAccess.isSettable(kAXPositionAttribute, on: handle.window),
            "resizable": AXWindowAccess.isSettable(kAXSizeAttribute, on: handle.window),
            "fullScreenSettable": AXWindowAccess.isSettable(
                AXWindowAccess.fullScreenAttribute as String, on: handle.window)
        ]
    }

    /// The window server's number when it can be matched, so an id means what it does in Raycast.
    private func register(_ handle: Handle, frame: CGRect) -> String {
        let id =
            Self.windowNumber(pid: handle.app.processIdentifier, frame: frame).map(String.init)
            ?? "ax-\(handle.app.processIdentifier)-\(handles.count)"
        handles[id] = handle
        return id
    }

    /// Bounds and owner only, so the listing needs no Screen Recording grant.
    private static func windowNumber(pid: pid_t, frame: CGRect) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let listing = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return listing.first { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds)
            else { return false }
            return abs(rect.minX - frame.minX) < 1 && abs(rect.minY - frame.minY) < 1
                && abs(rect.width - frame.width) < 1 && abs(rect.height - frame.height) < 1
        }?[kCGWindowNumber as String] as? CGWindowID
    }

    private static func bounds(_ rect: CGRect) -> [String: Any] {
        [
            "position": ["x": rect.minX, "y": rect.minY],
            "size": ["width": rect.width, "height": rect.height]
        ]
    }

    // MARK: - Writing

    /// `desktopId` is ignored: moving between Spaces has no public API, and a display is a position.
    private func setBounds(_ options: [String: RenderValue]) throws {
        guard Permissions.ensureAccessibility() else { throw Failure.accessibility }
        let id = options["id"]?.stringValue ?? ""
        guard let handle = handles[id], !handle.app.isTerminated else {
            throw Failure.unknownWindow(id)
        }
        let window = handle.window
        if options["bounds"]?.stringValue == "fullscreen" {
            guard enterFullScreen(window) else { throw Failure.writeFailed }
            return
        }
        guard !AXWindowAccess.isFullScreen(window) else { throw Failure.fullScreen }
        guard let current = AXWindowAccess.frame(of: window) else { throw Failure.noWindow }

        let bounds = options["bounds"]?.objectValue ?? [:]
        let position = bounds["position"]?.objectValue ?? [:]
        let size = bounds["size"]?.objectValue ?? [:]
        let target = WindowPlacementEngine.rounded(
            CGRect(
                x: position["x"]?.doubleValue ?? current.minX,
                y: position["y"]?.doubleValue ?? current.minY,
                width: size["width"]?.doubleValue ?? current.width,
                height: size["height"]?.doubleValue ?? current.height))
        guard AXWindowAccess.isSettable(kAXPositionAttribute, on: window) else {
            throw Failure.notPositionable
        }
        let canResize =
            target.size != current.size && AXWindowAccess.isSettable(kAXSizeAttribute, on: window)

        let restoreEnhancedUI =
            canResize ? AXWindowAccess.suppressEnhancedUserInterface(on: handle.application) : {}
        defer { restoreEnhancedUI() }
        guard
            AXWindowAccess.write(
                target, anchor: .topLeading, to: window, current: current,
                canResize: canResize, canvas: nil) != nil
        else { throw Failure.writeFailed }
    }

    /// `AXFullScreen`, then the green button — the same order the window feature uses.
    private func enterFullScreen(_ window: AXUIElement) -> Bool {
        if AXWindowAccess.isFullScreen(window) { return true }
        if AXWindowAccess.isSettable(AXWindowAccess.fullScreenAttribute as String, on: window),
            AXUIElementSetAttributeValue(
                window, AXWindowAccess.fullScreenAttribute, kCFBooleanTrue) == .success
        {
            return true
        }
        guard
            let button = AXWindowAccess.element(
                window, AXWindowAccess.fullScreenButtonAttribute as String)
        else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
}
