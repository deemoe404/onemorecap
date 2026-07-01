@preconcurrency import ApplicationServices
@preconcurrency import Cocoa
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
    private static let accessibilityPermissionSettingsURLs = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.PrivacySecurity.extension?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security"
    ].compactMap(URL.init(string:))
    private static let minimumRenderDelay: TimeInterval = 0.01
    private static let boundaryEpsilon: TimeInterval = 0.001
    private static let minimumPlaybackDisplayDelay: TimeInterval = 0.01

    private struct PanelPlaybackDisplayState: Equatable {
        let isPlaying: Bool
        let playbackSeconds: Int
        let offset: TimeInterval
        let sourceLabel: String
    }

    private struct AccessibilityPermissionMenuState: Equatable {
        let title: String
        let isEnabled: Bool
    }

    private struct MenuDisplayState: Equatable {
        let showHideTitle: String
        let playPauseTitle: String
        let offsetTitle: String
        let loadedFileTitle: String
        let accessibilityPermission: AccessibilityPermissionMenuState
    }

    private let clock = SubtitlePlayerClock()
    private let panelController = SubtitlePanelController()
    private let appleTVClient = AppleTVPlaybackClient()

    private var statusItem: NSStatusItem?
    private var showHideMenuItem: NSMenuItem?
    private var playPauseMenuItem: NSMenuItem?
    private var offsetMenuItem: NSMenuItem?
    private var loadedFileMenuItem: NSMenuItem?
    private var accessibilityPermissionMenuItem: NSMenuItem?

    private var document: SubtitleDocument?
    private var timeline: SubtitleTimeline?
    private var renderTimer: Timer?
    private var playbackDisplayTimer: Timer?
    private var lastSubtitleText: String?
    private var lastPanelPlaybackDisplayState: PanelPlaybackDisplayState?
    private var lastMenuDisplayState: MenuDisplayState?
    private lazy var syncCoordinator = PlaybackSyncCoordinator(
        manualTimeProvider: { [weak self] in
            self?.clock.currentMediaTime() ?? 0
        },
        manualIsPlayingProvider: { [weak self] in
            self?.clock.isPlaying ?? false
        }
    )
    private var lastRenderState = PlaybackRenderState(
        mediaTime: 0,
        effectiveTime: 0,
        isPlaying: false,
        sourceLabel: "Manual"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController.delegate = self
        setupStatusItem()
        panelController.show()
        refreshSubtitleText()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRenderTimer()
        stopPlaybackDisplayTimer()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Sub"
        item.button?.toolTip = "Subtitles"

        let menu = NSMenu()
        menu.delegate = self
        loadedFileMenuItem = NSMenuItem(title: "No Subtitle Loaded", action: nil, keyEquivalent: "")
        loadedFileMenuItem?.isEnabled = false
        menu.addItem(loadedFileMenuItem!)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Load Subtitle...", action: #selector(loadSubtitleFromMenu), keyEquivalent: ""))

        let showHide = NSMenuItem(title: "Hide Subtitle Window", action: #selector(toggleSubtitleWindow), keyEquivalent: "")
        showHideMenuItem = showHide
        menu.addItem(showHide)

        let playPause = NSMenuItem(title: "Play", action: #selector(togglePlayPauseFromMenu), keyEquivalent: "")
        playPauseMenuItem = playPause
        menu.addItem(playPause)

        menu.addItem(NSMenuItem(title: "Reset to Start", action: #selector(resetPlaybackFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())

        offsetMenuItem = NSMenuItem(title: "Offset: 0.0s", action: nil, keyEquivalent: "")
        offsetMenuItem?.isEnabled = false
        menu.addItem(offsetMenuItem!)
        menu.addItem(NSMenuItem(title: "Offset -0.5s", action: #selector(decreaseOffsetFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Offset +0.5s", action: #selector(increaseOffsetFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset Offset", action: #selector(resetOffsetFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())

        let accessibilityPermission = NSMenuItem(
            title: "Request Accessibility Access",
            action: #selector(requestAccessibilityPermission),
            keyEquivalent: ""
        )
        accessibilityPermissionMenuItem = accessibilityPermission
        menu.addItem(accessibilityPermission)
        menu.addItem(NSMenuItem(title: "Open Caption Settings...", action: #selector(openCaptionSettingsFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Subtitles", action: #selector(quit), keyEquivalent: ""))

        item.menu = menu
        statusItem = item
        updateMenuState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
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
        lastRenderState = renderState
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

    @objc private func togglePlayPauseFromMenu() {
        togglePlayback(resetIfAtStart: false)
    }

    @objc private func resetPlaybackFromMenu() {
        resetPlayback()
    }

    @objc private func decreaseOffsetFromMenu() {
        adjustOffset(by: -0.5)
    }

    @objc private func increaseOffsetFromMenu() {
        adjustOffset(by: 0.5)
    }

    @objc private func resetOffsetFromMenu() {
        clock.setOffset(0)
        refreshSubtitleText()
    }

    @objc private func requestAccessibilityPermission() {
        let wasTrusted = AXIsProcessTrusted()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if wasTrusted || !AXIsProcessTrusted() {
            openAccessibilityPermissionSettings()
        }
        updateMenuState()
    }

    @objc private func openCaptionSettingsFromMenu() {
        openCaptionSettings()
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

    private func togglePlayback(resetIfAtStart: Bool) {
        guard timeline != nil else {
            stopRenderTimer()
            stopPlaybackDisplayTimer()
            updateSubtitleTextIfNeeded("Drop SRT or VTT subtitle here")
            return
        }

        if clock.isPlaying {
            clock.pause()
            stopRenderTimer()
            stopPlaybackDisplayTimer()
        } else {
            clock.play(resetToStart: resetIfAtStart)
        }
        refreshSubtitleText()
    }

    private func resetPlayback() {
        stopRenderTimer()
        stopPlaybackDisplayTimer()
        clock.reset()
        clock.pause()
        syncCoordinator.markManual()
        refreshSubtitleText()
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

    private func openAccessibilityPermissionSettings() {
        for url in Self.accessibilityPermissionSettingsURLs where NSWorkspace.shared.open(url) {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not open Accessibility permissions"
        alert.informativeText = "Open System Settings > Privacy & Security > Accessibility, then remove and re-enable Subtitles manually."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func refreshSubtitleText() {
        let renderState = syncCoordinator.renderState(offset: clock.offset)
        lastRenderState = renderState

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
        let state = MenuDisplayState(
            showHideTitle: panelController.isVisible ? "Hide Subtitle Window" : "Show Subtitle Window",
            playPauseTitle: lastRenderState.isPlaying ? "Pause" : "Play",
            offsetTitle: String(format: "Offset: %.1fs", clock.offset),
            loadedFileTitle: document?.sourceURL?.lastPathComponent ?? "No Subtitle Loaded",
            accessibilityPermission: accessibilityPermissionMenuState()
        )
        guard state != lastMenuDisplayState else {
            return
        }
        lastMenuDisplayState = state
        showHideMenuItem?.title = state.showHideTitle
        playPauseMenuItem?.title = state.playPauseTitle
        offsetMenuItem?.title = state.offsetTitle
        loadedFileMenuItem?.title = state.loadedFileTitle
        accessibilityPermissionMenuItem?.title = state.accessibilityPermission.title
        accessibilityPermissionMenuItem?.isEnabled = state.accessibilityPermission.isEnabled
    }

    private func accessibilityPermissionMenuState() -> AccessibilityPermissionMenuState {
        if AXIsProcessTrusted() {
            return AccessibilityPermissionMenuState(
                title: "Refresh Accessibility Access",
                isEnabled: true
            )
        }

        return AccessibilityPermissionMenuState(
            title: "Request Accessibility Access",
            isEnabled: true
        )
    }

    func subtitlePanel(_ panelController: SubtitlePanelController, didAdjustOffsetBy delta: TimeInterval) {
        adjustOffset(by: delta)
    }

    func subtitlePanelDidRequestAppleTVCalibration(_ panelController: SubtitlePanelController) {
        switch appleTVClient.calibratedSnapshot() {
        case let .success(snapshot):
            clock.pause()
            clock.seek(to: snapshot.position)
            if snapshot.state.isActivelyAdvancing {
                clock.play()
            }
            syncCoordinator.markAppleTVCalibrated()
            refreshSubtitleText()

        case let .failure(error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not calibrate Apple TV"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func subtitlePanel(_ panelController: SubtitlePanelController, didRequestLoadURL url: URL) {
        loadSubtitle(from: url)
    }

    func subtitlePanelDidRequestClose(_ panelController: SubtitlePanelController) {
        panelController.hide()
        updateMenuState()
    }
}
