@preconcurrency import Cocoa
import CoreServices
import SubtitleCore
import SubtitlesAppSupport
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SubtitlePanelControllerDelegate {
    private static let captionSettingsURLs = [
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_FEATURE_CAPTIONS",
        "x-apple.systempreferences:com.apple.preference.universalaccess?Captioning",
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.universalaccess"
    ].compactMap(URL.init(string:))
    private static let automationPermissionSettingsURLs = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
        "x-apple.systempreferences:com.apple.PrivacySecurity.extension?Privacy_Automation",
        "x-apple.systempreferences:com.apple.preference.security"
    ].compactMap(URL.init(string:))
    private static let accessibilityPermissionSettingsURLs = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.PrivacySecurity.extension?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security"
    ].compactMap(URL.init(string:))
    private static let minimumRenderDelay: TimeInterval = 0.01
    private static let boundaryEpsilon: TimeInterval = 0.001
    private static let minimumPlaybackDisplayDelay: TimeInterval = 0.01
    private static let statusItemIconPointSize = NSSize(width: 18, height: 18)
    private static let automationPermissionKnownGrantedDefaultsKey = "automationPermissionKnownGranted"

    private struct PanelPlaybackDisplayState: Equatable {
        let isPlaying: Bool
        let playbackSeconds: Int
        let offset: TimeInterval
        let sourceLabel: String
    }

    private struct SettingsMenuState: Equatable {
        let title: String
        let isEnabled: Bool
        let isGranted: Bool
    }

    private struct PermissionGrantState: Equatable {
        let automationGranted: Bool
        let accessibilityGranted: Bool

        static let unavailable = PermissionGrantState(
            automationGranted: false,
            accessibilityGranted: false
        )
    }

    private enum AutomationPermissionProbeResult {
        case granted
        case denied
        case unavailable
    }

    private struct MenuDisplayState: Equatable {
        let showHideTitle: String
        let loadedFileTitle: String
        let automationPermission: SettingsMenuState?
        let accessibilityPermission: SettingsMenuState?
        let canCheckForUpdates: Bool
    }

    private let clock = SubtitlePlayerClock()
    private let panelController = SubtitlePanelController()
    private let updateController: any AppUpdateControlling
    private let playbackClientsByID: [String: any ExternalPlaybackClient]
    private let playbackTargets: [ExternalPlaybackTarget]
    private let defaultPlaybackTargetID: String?
    private let accessibilityPermissionGranted: () -> Bool
    private let permissionGrantQueue = DispatchQueue(label: "app.onemorecap.permission-grants", qos: .utility)
    private let showsAutomationSettings: Bool
    private let showsAccessibilitySettings: Bool
    private let showsUpdateMenu: Bool

    private var statusItem: NSStatusItem?
    private var showHideMenuItem: NSMenuItem?
    private var loadedFileMenuItem: NSMenuItem?
    private var permissionMenuItem: NSMenuItem?
    private var automationPermissionMenuItem: NSMenuItem?
    private var accessibilityPermissionMenuItem: NSMenuItem?
    private var checkForUpdatesMenuItem: NSMenuItem?

    private var document: SubtitleDocument?
    private var timeline: SubtitleTimeline?
    private var renderTimer: Timer?
    private var playbackDisplayTimer: Timer?
    private var lastSubtitleText: String?
    private var lastPanelPlaybackDisplayState: PanelPlaybackDisplayState?
    private var lastMenuDisplayState: MenuDisplayState?
    private var permissionGrantState = PermissionGrantState.unavailable
    private lazy var syncCoordinator = PlaybackSyncCoordinator(
        manualTimeProvider: { [weak self] in
            self?.clock.currentMediaTime() ?? 0
        },
        manualIsPlayingProvider: { [weak self] in
            self?.clock.isPlaying ?? false
        }
    )

    init(configuration: SubtitlesAppConfiguration) {
        var clientsByID: [String: any ExternalPlaybackClient] = [:]
        var targets: [ExternalPlaybackTarget] = []
        for client in configuration.playbackClients where clientsByID[client.target.id] == nil {
            clientsByID[client.target.id] = client
            targets.append(client.target)
        }

        updateController = configuration.updateController
        playbackClientsByID = clientsByID
        playbackTargets = targets
        defaultPlaybackTargetID = configuration.defaultPlaybackTargetID
        accessibilityPermissionGranted = configuration.accessibilityPermissionGranted
        showsAutomationSettings = configuration.showsAutomationSettings
        showsAccessibilitySettings = configuration.showsAccessibilitySettings
        showsUpdateMenu = configuration.showsUpdateMenu
        super.init()
        permissionGrantState = PermissionGrantState(
            automationGranted: UserDefaults.standard.bool(forKey: Self.automationPermissionKnownGrantedDefaultsKey),
            accessibilityGranted: false
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateController.onCanCheckForUpdatesChanged = { [weak self] in
            self?.updateMenuState()
        }
        panelController.delegate = self
        panelController.setSyncTargets(playbackTargets, defaultTargetID: defaultPlaybackTargetID)
        setupStatusItem()
        panelController.show()
        refreshSubtitleText()
        refreshPermissionGrantState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRenderTimer()
        stopPlaybackDisplayTimer()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusItemButton(item)

        let menu = NSMenu()
        menu.delegate = self
        loadedFileMenuItem = NSMenuItem(title: "No Subtitle Loaded", action: nil, keyEquivalent: "")
        loadedFileMenuItem?.isEnabled = false
        menu.addItem(loadedFileMenuItem!)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Load Subtitle...", action: #selector(loadSubtitleFromMenu), keyEquivalent: ""))

        let showHide = NSMenuItem(title: "Hide Subtitle", action: #selector(toggleSubtitleWindow), keyEquivalent: "")
        showHideMenuItem = showHide
        menu.addItem(showHide)

        menu.addItem(.separator())

        if showsAutomationSettings || showsAccessibilitySettings {
            let permissionSettings = NSMenuItem(title: "Permission", action: nil, keyEquivalent: "")
            let permissionSettingsMenu = NSMenu(title: "Permission")

            if showsAutomationSettings {
                let automationPermission = NSMenuItem(
                    title: "Automation...",
                    action: #selector(openAutomationPermissionSettingsFromMenu),
                    keyEquivalent: ""
                )
                automationPermissionMenuItem = automationPermission
                permissionSettingsMenu.addItem(automationPermission)
            }
            if showsAccessibilitySettings {
                let accessibilityPermission = NSMenuItem(
                    title: "Accessibility...",
                    action: #selector(openAccessibilityPermissionSettingsFromMenu),
                    keyEquivalent: ""
                )
                accessibilityPermissionMenuItem = accessibilityPermission
                permissionSettingsMenu.addItem(accessibilityPermission)
            }

            permissionSettings.submenu = permissionSettingsMenu
            permissionMenuItem = permissionSettings
            menu.addItem(permissionSettings)
        }
        menu.addItem(NSMenuItem(title: "Caption Settings...", action: #selector(openCaptionSettingsFromMenu), keyEquivalent: ""))

        if showsUpdateMenu {
            menu.addItem(.separator())

            let checkForUpdates = NSMenuItem(
                title: "Check for Updates...",
                action: #selector(checkForUpdatesFromMenu),
                keyEquivalent: ""
            )
            checkForUpdatesMenuItem = checkForUpdates
            menu.addItem(checkForUpdates)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(AppMetadata.displayName)", action: #selector(quit), keyEquivalent: ""))

        item.menu = menu
        statusItem = item
        updateMenuState()
    }

    private func configureStatusItemButton(_ item: NSStatusItem) {
        guard let button = item.button else {
            return
        }

        button.toolTip = AppMetadata.displayName
        button.setAccessibilityLabel(AppMetadata.displayName)

        if let image = Self.statusItemIcon() {
            item.length = NSStatusItem.squareLength
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            item.length = NSStatusItem.variableLength
            button.image = nil
            button.imagePosition = .noImage
            button.title = AppMetadata.statusItemTitle
        }
    }

    private static func statusItemIcon() -> NSImage? {
        let image = NSImage(named: "MenuBarIcon")
            ?? Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
                .flatMap(NSImage.init(contentsOf:))
        image?.isTemplate = true
        image?.size = statusItemIconPointSize
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
        refreshPermissionGrantState()
    }

    private func stopRenderTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    private func stopPlaybackDisplayTimer() {
        playbackDisplayTimer?.invalidate()
        playbackDisplayTimer = nil
    }

    private func scheduleRenderTimerIfNeeded(
        renderState: PlaybackRenderState,
        timeline: SubtitleTimeline?
    ) {
        stopRenderTimer()

        guard renderState.isPlaying,
              let timeline,
              let nextBoundary = timeline.nextBoundary(after: renderState.mediaTime, offset: clock.offset) else {
            return
        }

        let intervalUntilBoundary = nextBoundary - renderState.mediaTime
        guard intervalUntilBoundary.isFinite, intervalUntilBoundary > 0 else {
            return
        }

        let interval = intervalUntilBoundary <= Self.boundaryEpsilon
            ? Self.minimumRenderDelay
            : max(Self.minimumRenderDelay, intervalUntilBoundary)
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(renderTimerDidFire),
            userInfo: nil,
            repeats: false
        )
        timer.tolerance = min(0.05, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    private func schedulePlaybackDisplayTimerIfNeeded(renderState: PlaybackRenderState) {
        stopPlaybackDisplayTimer()

        guard renderState.isPlaying, timeline != nil else {
            return
        }

        let timer = Timer(
            timeInterval: playbackDisplayDelay(after: renderState.mediaTime),
            target: self,
            selector: #selector(playbackDisplayTimerDidFire),
            userInfo: nil,
            repeats: false
        )
        timer.tolerance = min(0.1, timer.timeInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        playbackDisplayTimer = timer
    }

    private func playbackDisplayDelay(after mediaTime: TimeInterval) -> TimeInterval {
        let clamped = max(0, mediaTime)
        let fractional = clamped - floor(clamped)
        let delay = fractional == 0 ? 1 : 1 - fractional
        return max(Self.minimumPlaybackDisplayDelay, delay)
    }

    @objc private func renderTimerDidFire() {
        renderTimer = nil
        refreshSubtitleText()
    }

    @objc private func playbackDisplayTimerDidFire() {
        playbackDisplayTimer = nil
        let renderState = syncCoordinator.renderState(offset: clock.offset)
        updatePanelPlaybackStateIfNeeded(renderState)
        updateMenuState()
        schedulePlaybackDisplayTimerIfNeeded(renderState: renderState)
    }

    @objc private func loadSubtitleFromMenu() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Load Subtitle"
        openPanel.prompt = "Load"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [
            UTType(filenameExtension: "srt"),
            UTType(filenameExtension: "vtt"),
            UTType(filenameExtension: "webvtt")
        ].compactMap { $0 }

        let shouldRestorePanel = panelController.isVisible
        if shouldRestorePanel {
            panelController.hide()
            updateMenuState()
        }

        // Status-item apps are not always active after a menu action, and the overlay
        // window intentionally sits above normal app panels.
        DispatchQueue.main.async { [weak self, openPanel] in
            guard let self else {
                return
            }

            NSApplication.shared.activate(ignoringOtherApps: true)
            let response = openPanel.runModal()

            if shouldRestorePanel && !self.panelController.isVisible {
                self.panelController.show()
            }
            self.updateMenuState()

            guard response == .OK, let url = openPanel.url else {
                return
            }
            self.loadSubtitle(from: url)
        }
    }

    @objc private func toggleSubtitleWindow() {
        if panelController.isVisible {
            panelController.hide()
        } else {
            panelController.show()
        }
        updateMenuState()
    }

    @objc private func openCaptionSettingsFromMenu() {
        openCaptionSettings()
    }

    @objc private func openAutomationPermissionSettingsFromMenu() {
        openAutomationPermissionSettings()
    }

    @objc private func openAccessibilityPermissionSettingsFromMenu() {
        openAccessibilityPermissionSettings()
    }

    @objc private func checkForUpdatesFromMenu() {
        updateController.checkForUpdates()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func loadSubtitle(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let parsed = try SubtitleParser.parse(data: data, sourceURL: url)
            document = parsed
            timeline = SubtitleTimeline(document: parsed)
            clock.reset()
            syncCoordinator.markManual()
            panelController.show()
            panelController.setLoadedFileName(url.lastPathComponent)
            refreshSubtitleText()
        } catch {
            presentLoadError(error, url: url)
        }
    }

    private func presentLoadError(_ error: Error, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not load subtitle"
        alert.informativeText = "\(url.lastPathComponent)\n\(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func adjustOffset(by delta: TimeInterval) {
        clock.adjustOffset(by: delta)
        refreshSubtitleText()
    }

    private func openCaptionSettings() {
        for url in Self.captionSettingsURLs where NSWorkspace.shared.open(url) {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not open Caption Settings"
        alert.informativeText = "Open System Settings > Accessibility > Subtitles and Captioning manually."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openAutomationPermissionSettings() {
        for url in Self.automationPermissionSettingsURLs where NSWorkspace.shared.open(url) {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not open Automation permissions"
        alert.informativeText = "Open System Settings > Privacy & Security > Automation, then allow One More Cap to read QuickTime Player."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openAccessibilityPermissionSettings() {
        for url in Self.accessibilityPermissionSettingsURLs where NSWorkspace.shared.open(url) {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not open Accessibility permissions"
        alert.informativeText = "Open System Settings > Privacy & Security > Accessibility, then allow One More Cap."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func refreshSubtitleText() {
        let renderState = syncCoordinator.renderState(offset: clock.offset)

        guard let timeline else {
            updateSubtitleTextIfNeeded("Drop SRT or VTT subtitle here")
            updatePanelPlaybackStateIfNeeded(renderState)
            updateMenuState()
            scheduleRenderTimerIfNeeded(renderState: renderState, timeline: nil)
            schedulePlaybackDisplayTimerIfNeeded(renderState: renderState)
            return
        }

        let activeText = timeline
            .activeCues(at: renderState.effectiveTime, offset: 0)
            .map(\.text)
            .joined(separator: "\n\n")

        updateSubtitleTextIfNeeded(activeText)
        updatePanelPlaybackStateIfNeeded(renderState)
        updateMenuState()
        scheduleRenderTimerIfNeeded(renderState: renderState, timeline: timeline)
        schedulePlaybackDisplayTimerIfNeeded(renderState: renderState)
    }

    private func updateSubtitleTextIfNeeded(_ text: String) {
        guard text != lastSubtitleText else {
            return
        }
        lastSubtitleText = text
        panelController.showMessage(text)
    }

    private func updatePanelPlaybackStateIfNeeded(_ renderState: PlaybackRenderState) {
        let playbackSeconds = Int(max(0, renderState.mediaTime))
        let displayState = PanelPlaybackDisplayState(
            isPlaying: renderState.isPlaying,
            playbackSeconds: playbackSeconds,
            offset: clock.offset,
            sourceLabel: renderState.sourceLabel
        )
        guard displayState != lastPanelPlaybackDisplayState else {
            return
        }
        lastPanelPlaybackDisplayState = displayState
        panelController.setPlaybackState(
            isPlaying: renderState.isPlaying,
            time: TimeInterval(playbackSeconds),
            offset: clock.offset,
            sourceLabel: renderState.sourceLabel
        )
    }

    private func updateMenuState() {
        let automationPermission = showsAutomationSettings
            ? settingsMenuState(title: "Automation...", isGranted: permissionGrantState.automationGranted)
            : nil
        let accessibilityPermission = showsAccessibilitySettings
            ? settingsMenuState(title: "Accessibility...", isGranted: permissionGrantState.accessibilityGranted)
            : nil
        let state = MenuDisplayState(
            showHideTitle: panelController.isVisible ? "Hide Subtitle" : "Show Subtitle",
            loadedFileTitle: document?.sourceURL?.lastPathComponent ?? "No Subtitle Loaded",
            automationPermission: automationPermission,
            accessibilityPermission: accessibilityPermission,
            canCheckForUpdates: !updateController.isConfigured || updateController.canCheckForUpdates
        )
        guard state != lastMenuDisplayState else {
            return
        }
        lastMenuDisplayState = state
        showHideMenuItem?.title = state.showHideTitle
        loadedFileMenuItem?.title = state.loadedFileTitle
        permissionMenuItem?.title = "Permission"
        automationPermissionMenuItem?.title = state.automationPermission?.title ?? "Automation..."
        automationPermissionMenuItem?.isEnabled = state.automationPermission?.isEnabled ?? false
        automationPermissionMenuItem?.state = state.automationPermission?.isGranted == true ? .on : .off
        accessibilityPermissionMenuItem?.title = state.accessibilityPermission?.title ?? "Accessibility..."
        accessibilityPermissionMenuItem?.isEnabled = state.accessibilityPermission?.isEnabled ?? false
        accessibilityPermissionMenuItem?.state = state.accessibilityPermission?.isGranted == true ? .on : .off
        checkForUpdatesMenuItem?.isEnabled = state.canCheckForUpdates
    }

    private func settingsMenuState(title: String, isGranted: Bool) -> SettingsMenuState {
        SettingsMenuState(
            title: title,
            isEnabled: true,
            isGranted: isGranted
        )
    }

    private func refreshPermissionGrantState() {
        let shouldCheckAutomation = showsAutomationSettings
        let shouldCheckAccessibility = showsAccessibilitySettings
        let accessibilityPermissionGranted = accessibilityPermissionGranted
        let previousAutomationGranted = permissionGrantState.automationGranted

        permissionGrantQueue.async { [weak self] in
            let automationGranted = switch shouldCheckAutomation ? Self.automationPermissionProbeResult() : .denied {
            case .granted:
                true
            case .denied:
                false
            case .unavailable:
                previousAutomationGranted
            }
            Self.cacheKnownAutomationPermissionGranted(automationGranted)

            let nextState = PermissionGrantState(
                automationGranted: automationGranted,
                accessibilityGranted: shouldCheckAccessibility ? accessibilityPermissionGranted() : false
            )

            DispatchQueue.main.async { [weak self] in
                guard let self, permissionGrantState != nextState else {
                    return
                }

                permissionGrantState = nextState
                updateMenuState()
            }
        }
    }

    private static func automationPermissionProbeResult() -> AutomationPermissionProbeResult {
        var target = AEAddressDesc()
        let bundleIdentifier = QuickTimePlaybackClient.bundleIdentifier
        let createStatus = bundleIdentifier.withCString { pointer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                pointer,
                bundleIdentifier.utf8.count,
                &target
            )
        }
        guard createStatus == noErr else {
            return .unavailable
        }
        defer {
            AEDisposeDesc(&target)
        }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )
        if status == noErr {
            return .granted
        }
        if status == OSStatus(errAEEventNotPermitted)
            || status == OSStatus(errAEEventWouldRequireUserConsent) {
            return .denied
        }
        if status == OSStatus(procNotFound) {
            return .unavailable
        }
        return .denied
    }

    private static func cacheKnownAutomationPermissionGranted(_ isGranted: Bool) {
        UserDefaults.standard.set(isGranted, forKey: automationPermissionKnownGrantedDefaultsKey)
    }

    private func setKnownAutomationPermissionGranted(_ isGranted: Bool) {
        Self.cacheKnownAutomationPermissionGranted(isGranted)
        guard showsAutomationSettings, permissionGrantState.automationGranted != isGranted else {
            return
        }

        permissionGrantState = PermissionGrantState(
            automationGranted: isGranted,
            accessibilityGranted: permissionGrantState.accessibilityGranted
        )
        updateMenuState()
    }

    func subtitlePanel(_ panelController: SubtitlePanelController, didAdjustOffsetBy delta: TimeInterval) {
        adjustOffset(by: delta)
    }

    func subtitlePanel(_ panelController: SubtitlePanelController, didRequestPlaybackSyncWith targetID: String) {
        guard let client = playbackClientsByID[targetID] else {
            presentPlaybackSyncError(
                messageText: "Could not sync playback",
                informativeText: "The selected playback target is not available in this build."
            )
            return
        }

        switch client.currentSnapshot() {
        case let .success(snapshot):
            if client.target.id == ExternalPlaybackTarget.quickTime.id {
                setKnownAutomationPermissionGranted(true)
            }
            clock.pause()
            clock.seek(to: snapshot.position)
            if snapshot.state.isActivelyAdvancing {
                clock.play()
            }
            syncCoordinator.markSynced(with: "\(client.target.displayName) synced")
            refreshSubtitleText()

        case let .failure(error):
            if case .automationPermissionDenied = error {
                setKnownAutomationPermissionGranted(false)
            }
            presentPlaybackSyncError(
                messageText: "Could not sync \(client.target.displayName)",
                informativeText: error.localizedDescription
            )
        }
    }

    private func presentPlaybackSyncError(messageText: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func subtitlePanel(_ panelController: SubtitlePanelController, didRequestLoadURL url: URL) {
        loadSubtitle(from: url)
    }

    func subtitlePanelDidRequestClose(_ panelController: SubtitlePanelController) {
        panelController.hide()
        updateMenuState()
    }
}
