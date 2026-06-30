@preconcurrency import ApplicationServices
@preconcurrency import Cocoa
import SubtitleCore
import SubtitlesAppSupport
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, SubtitlePanelControllerDelegate {
    private static let captionSettingsURLs = [
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_FEATURE_CAPTIONS",
        "x-apple.systempreferences:com.apple.preference.universalaccess?Captioning",
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.universalaccess"
    ].compactMap(URL.init(string:))

    private let clock = SubtitlePlayerClock()
    private let panelController = SubtitlePanelController()
    private let appleTVClient = AppleTVPlaybackClient()

    private var statusItem: NSStatusItem?
    private var showHideMenuItem: NSMenuItem?
    private var playPauseMenuItem: NSMenuItem?
    private var offsetMenuItem: NSMenuItem?
    private var loadedFileMenuItem: NSMenuItem?

    private var document: SubtitleDocument?
    private var timeline: SubtitleTimeline?
    private var renderTimer: Timer?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
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
        setupKeyMonitors()
        startRenderTimer()
        panelController.show()
        refreshSubtitleText()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        renderTimer?.invalidate()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Sub"
        item.button?.toolTip = "Subtitles"

        let menu = NSMenu()
        loadedFileMenuItem = NSMenuItem(title: "No Subtitle Loaded", action: nil, keyEquivalent: "")
        loadedFileMenuItem?.isEnabled = false
        menu.addItem(loadedFileMenuItem!)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Load Subtitle...", action: #selector(loadSubtitleFromMenu), keyEquivalent: "o"))

        let showHide = NSMenuItem(title: "Hide Subtitle Window", action: #selector(toggleSubtitleWindow), keyEquivalent: "")
        showHideMenuItem = showHide
        menu.addItem(showHide)

        let playPause = NSMenuItem(title: "Play", action: #selector(togglePlayPauseFromMenu), keyEquivalent: " ")
        playPauseMenuItem = playPause
        menu.addItem(playPause)

        menu.addItem(NSMenuItem(title: "Reset to Start", action: #selector(resetPlaybackFromMenu), keyEquivalent: "r"))
        menu.addItem(.separator())

        offsetMenuItem = NSMenuItem(title: "Offset: 0.0s", action: nil, keyEquivalent: "")
        offsetMenuItem?.isEnabled = false
        menu.addItem(offsetMenuItem!)
        menu.addItem(NSMenuItem(title: "Offset -0.5s", action: #selector(decreaseOffsetFromMenu), keyEquivalent: "["))
        menu.addItem(NSMenuItem(title: "Offset +0.5s", action: #selector(increaseOffsetFromMenu), keyEquivalent: "]"))
        menu.addItem(NSMenuItem(title: "Reset Offset", action: #selector(resetOffsetFromMenu), keyEquivalent: "0"))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Caption Settings...", action: #selector(openCaptionSettingsFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Subtitles", action: #selector(quit), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
        updateMenuState()
    }

    private func setupKeyMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                _ = self?.handleTransportKey(event, fromLocalMonitor: false)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleTransportKey(event, fromLocalMonitor: true) == true {
                return nil
            }
            return event
        }
    }

    private func startRenderTimer() {
        renderTimer = Timer.scheduledTimer(
            timeInterval: 0.08,
            target: self,
            selector: #selector(renderTimerDidFire),
            userInfo: nil,
            repeats: true
        )
        renderTimer?.tolerance = 0.02
    }

    @objc private func renderTimerDidFire() {
        refreshSubtitleText()
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
        updateMenuState()
        refreshSubtitleText()
    }

    @objc private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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
            updateMenuState()
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

    private func handleTransportKey(_ event: NSEvent, fromLocalMonitor: Bool) -> Bool {
        guard isTransportKey(event), timeline != nil else {
            return false
        }

        let shouldReset = !clock.isPlaying && clock.currentMediaTime() < 0.05
        togglePlayback(resetIfAtStart: shouldReset)
        return fromLocalMonitor
    }

    private func isTransportKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasBlockingModifier = flags.contains(.command) || flags.contains(.control) || flags.contains(.shift)
        guard !hasBlockingModifier else {
            return false
        }

        return flags.isEmpty || flags == .option
    }

    private func togglePlayback(resetIfAtStart: Bool) {
        guard timeline != nil else {
            panelController.showMessage("Drop SRT or VTT subtitle here")
            return
        }

        if clock.isPlaying {
            clock.pause()
        } else {
            clock.play(resetToStart: resetIfAtStart)
        }
        updateMenuState()
        refreshSubtitleText()
    }

    private func resetPlayback() {
        clock.reset()
        clock.pause()
        syncCoordinator.markManual()
        updateMenuState()
        refreshSubtitleText()
    }

    private func adjustOffset(by delta: TimeInterval) {
        clock.adjustOffset(by: delta)
        updateMenuState()
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

    private func refreshSubtitleText() {
        let renderState = syncCoordinator.renderState(offset: clock.offset)
        lastRenderState = renderState

        guard let timeline else {
            panelController.showMessage("Drop SRT or VTT subtitle here")
            panelController.setPlaybackState(
                isPlaying: renderState.isPlaying,
                time: renderState.mediaTime,
                offset: clock.offset,
                sourceLabel: renderState.sourceLabel
            )
            updateMenuState()
            return
        }

        let activeText = timeline
            .activeCues(at: renderState.effectiveTime, offset: 0)
            .map(\.text)
            .joined(separator: "\n\n")

        panelController.showMessage(activeText)
        panelController.setPlaybackState(
            isPlaying: renderState.isPlaying,
            time: renderState.mediaTime,
            offset: clock.offset,
            sourceLabel: renderState.sourceLabel
        )
        updateMenuState()
    }

    private func updateMenuState() {
        showHideMenuItem?.title = panelController.isVisible ? "Hide Subtitle Window" : "Show Subtitle Window"
        playPauseMenuItem?.title = lastRenderState.isPlaying ? "Pause" : "Play"
        offsetMenuItem?.title = String(format: "Offset: %.1fs", clock.offset)
        loadedFileMenuItem?.title = document?.sourceURL?.lastPathComponent ?? "No Subtitle Loaded"
    }

    func subtitlePanelDidRequestPlayPause(_ panelController: SubtitlePanelController) {
        togglePlayback(resetIfAtStart: false)
    }

    func subtitlePanelDidRequestReset(_ panelController: SubtitlePanelController) {
        resetPlayback()
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

    func subtitlePanelDidRequestCaptionSettings(_ panelController: SubtitlePanelController) {
        openCaptionSettings()
    }

    func subtitlePanel(_ panelController: SubtitlePanelController, didRequestLoadURL url: URL) {
        loadSubtitle(from: url)
    }

    func subtitlePanelDidRequestClose(_ panelController: SubtitlePanelController) {
        panelController.hide()
        updateMenuState()
    }
}
