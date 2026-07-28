import AppKit
import Carbon.HIToolbox
import RTICore

/// Builds the runtime command palette / menu / hotkey entries. Extracted
/// from AppDelegate so the coordinator stays focused on wiring and
/// lifecycle, not on enumerating every affordance in the app.
///
/// Commands are built in named sections rather than one giant array so
/// adding a new command is a one-line change in the right section. The
/// top-level `build` concatenates all sections.
///
/// `MenuCoordinator` and `HotkeyCoordinator` consume this same list — one
/// registry, three consumers (palette, menu, hotkeys).
enum CommandBuilder {
    @MainActor
    static func buildCommands(
        windows: WindowCoordinator,
        session: SessionCoordinator,
        llm: LLMController,
        modes: ModeStore
    ) -> [RTICommand] {
        sessionCommands(windows: windows, session: session)
            + navigationCommands(windows: windows)
            + tabCommands(windows: windows)
            + actionCommands(llm: llm)
            + assistantProviderCommands()
            + transcriptionCommands()
            + panelCommands(windows: windows, llm: llm)
            + appCommands(windows: windows)
            + modeSwitchCommands(modes: modes, llm: llm)
    }

    // MARK: - Transcription provider (menu quick-switch)

    @MainActor
    private static func assistantProviderCommands() -> [RTICommand] {
        LLMProviders.all.map { provider in
            RTICommand(
                id: "llm.provider.\(provider.id)",
                title: "Assistant: \(provider.displayName)",
                keywords: ["assistant", "llm", "provider", "model", "openai", "deepseek", "openrouter", "switch"],
                perform: { LLMProviders.activeId = provider.id },
                menuSection: .panels,
                menuParent: "Assistant model",
                menuStateProvider: { LLMProviders.activeId == provider.id }
            )
        }
    }

    /// Quick-switch the live speech-to-text engine from the menubar, with a
    /// checkmark on the active one. Applies to the next session — a mid-session
    /// swap would tear down and rebuild both audio legs and risk dropping the
    /// meeting, so we don't hot-swap a live recording.
    @MainActor
    private static func transcriptionCommands() -> [RTICommand] {
        guard STTProviders.all.count > 1 else { return [] }
        return STTProviders.all.map { provider in
            RTICommand(
                id: "stt.provider.\(provider.id)",
                title: "Transcription: \(provider.displayName)",
                keywords: ["transcription", "stt", "provider", "engine", "soniox", "model", "switch"],
                perform: { STTProviders.activeId = provider.id },
                menuSection: .panels,
                menuParent: "Transcription model",
                menuStateProvider: { STTProviders.activeId == provider.id }
            )
        }
    }

    // MARK: - Tab navigation (palette only)

    /// Jump straight to an overlay tab. The tabs are one click away in the
    /// overlay's top bar, so these carry no global hotkey and don't appear in
    /// the menubar — they stay searchable in the command palette only, to keep
    /// both the hotkey set and the menu uncluttered.
    @MainActor
    private static func tabCommands(windows: WindowCoordinator) -> [RTICommand] {
        func tabCmd(_ tab: String, _ title: String) -> RTICommand {
            RTICommand(
                id: "view.tab.\(tab)",
                title: title,
                keywords: ["tab", "switch", "jump", "go", tab],
                perform: { [weak windows] in
                    windows?.showOverlay()
                    NotificationCenter.default.post(name: .rtiSelectTab, object: tab)
                }
            )
        }
        return [
            tabCmd("setup", "Go to Setup"),
            tabCmd("assist", "Go to Assist"),
            tabCmd("transcript", "Go to Transcript"),
            tabCmd("notes", "Go to Notes"),
            tabCmd("guide", "Go to Guide"),
            tabCmd("findings", "Go to Intel"),
        ]
    }

    // MARK: - Section builders

    @MainActor
    private static func sessionCommands(
        windows _: WindowCoordinator,
        session: SessionCoordinator
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "mic.mute.toggle",
                title: "Mute / Unmute My Mic",
                keywords: ["microphone", "mute", "silence", "input"],
                perform: { session.micMuted.toggle() },
                menuSection: .session,
                menuStateProvider: { session.micMuted }
            ),
            RTICommand(
                id: "session.start",
                title: "Start Recording",
                subtitle: "⌘⇧R",
                keywords: ["record", "begin", "transcribe", "finish", "stop", "new"],
                perform: { session.toggleSession() },
                menuSection: .session,
                menuTitleProvider: {
                    switch session.phase {
                    case .recording, .paused: "Finish Recording  ⌘⇧R"
                    case .summarizing, .done: "New Recording  ⌘⇧R"
                    case .finishing: "Saving…"
                    case .idle: "Start Recording  ⌘⇧R"
                    }
                },
                hotkeyKeyCode: UInt32(kVK_ANSI_R),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
            RTICommand(
                id: "session.pause",
                title: "Pause / Resume Recording",
                subtitle: "⌘⇧P",
                keywords: ["pause", "resume", "hold", "suspend"],
                isAvailable: { session.phase == .recording || session.phase == .paused },
                perform: { session.togglePause() },
                menuSection: .session,
                menuTitleProvider: {
                    session.isPaused ? "Resume Recording  ⌘⇧P" : "Pause Recording  ⌘⇧P"
                },
                hotkeyKeyCode: UInt32(kVK_ANSI_P),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
        ]
    }

    @MainActor
    private static func navigationCommands(
        windows: WindowCoordinator
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "overlay.toggle",
                title: "Show Chat Panel  ⌘\\",
                subtitle: "⌘\\",
                keywords: ["panel", "show", "hide"],
                perform: { [weak windows] in windows?.toggleOverlay() },
                menuSection: .navigation,
                hotkeyKeyCode: UInt32(kVK_ANSI_Backslash),
                hotkeyModifiers: UInt32(cmdKey)
            ),
            RTICommand(
                id: "view.sessions",
                title: "Past Sessions",
                keywords: ["history", "archive", "library", "previous"],
                perform: { [weak windows] in windows?.showSessionsControl(tab: .sessions) },
                menuSection: .navigation
            ),
            RTICommand(
                id: "view.brief",
                title: "Pre-meeting Brief",
                keywords: ["brief", "prep", "prepare", "agenda", "meeting"],
                perform: { [weak windows] in windows?.showMeetingBrief() },
                menuSection: .navigation
            ),
        ]
    }

    /// Translate an AssistantAction hotkey letter to a Carbon virtual key code.
    private static func carbonKeyCode(for key: String) -> UInt32? {
        let map: [String: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
            "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
            "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
            "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
            "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
            "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
            "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
        ]
        return map[key.uppercased()].map(UInt32.init)
    }

    /// Translate AssistantAction modifier flags to Carbon modifier mask.
    private static func carbonModifiers(_ m: ActionHotkey.Modifiers) -> UInt32 {
        var r = 0
        if m.contains(.command) { r |= cmdKey }
        if m.contains(.option) { r |= optionKey }
        if m.contains(.shift) { r |= shiftKey }
        return UInt32(r)
    }

    @MainActor
    private static func actionCommands(
        llm: LLMController
    ) -> [RTICommand] {
        [
            // ⌘⏎ is the remappable "primary" hotkey — it dispatches whatever
            // quick action the user picked (Assist by default; e.g. Recap in
            // a meeting where they're a passive listener).
            RTICommand(
                id: "chat.primary",
                title: "Primary Action (remappable)",
                subtitle: "⌘⏎",
                keywords: ["help", "suggestion", "assist", "primary"],
                perform: { llm.sendPrimary() },
                menuTitleProvider: { "\(AssistantAction.byID(llm.primaryActionID)?.label ?? "Assist")  ⌘⏎" },
                hotkeyKeyCode: UInt32(kVK_Return),
                hotkeyModifiers: UInt32(cmdKey)
            ),
        ] + AssistantAction.all.map { action in
            // Every quick action's palette entry + global hotkey is derived
            // from the one AssistantAction catalogue.
            RTICommand(
                id: "chat.\(action.id)",
                title: action.paletteTitle,
                subtitle: action.hotkey?.display,
                keywords: action.keywords,
                perform: { llm.perform(actionID: action.id) },
                hotkeyKeyCode: action.hotkey.flatMap { carbonKeyCode(for: $0.key) },
                hotkeyModifiers: action.hotkey.map { carbonModifiers($0.modifiers) }
            )
        } + [
            // One-shot recap depth overrides — not in the catalogue (they don't
            // change the sticky default ⌘⌥R uses; set that in the ✦ "Recap
            // depth" submenu).
            RTICommand(
                id: "chat.recap.brief",
                title: "Recap (brief)",
                keywords: ["recap", "short", "tldr", "length"],
                perform: { llm.sendRecap(depth: .brief) }
            ),
            RTICommand(
                id: "chat.recap.detailed",
                title: "Recap (detailed)",
                keywords: ["recap", "long", "full", "thorough", "length"],
                perform: { llm.sendRecap(depth: .detailed) }
            ),
            RTICommand(
                id: "note.toggle",
                title: "Toggle Note Entry",
                subtitle: "⌘⌥N",
                keywords: ["note", "annotate", "inline", "mark"],
                perform: {
                    guard SessionCoordinator.shared.isRunning else { return }
                    let state = OverlayInputState.shared
                    state.mode = state.isNoteMode ? .chat : .liveNote
                },
                menuSection: .actions,
                menuTitleProvider: {
                    "Note Mode  ⌘⌥N"
                },
                hotkeyKeyCode: UInt32(kVK_ANSI_N),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "capture.screen",
                title: "Capture Screen  ⌘⇧H",
                subtitle: "⌘H",
                keywords: ["screenshot", "ocr"],
                perform: { ScreenshotManager.shared.captureAndAttach() },
                menuSection: .actions,
                hotkeyKeyCode: UInt32(kVK_ANSI_H),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
        ] + AssistantAction.primaryEligibleActions.map { action in
            RTICommand(
                id: "primary.set.\(action.id)",
                title: action.label,
                keywords: ["primary", "hotkey", "remap", "bind", "command assist"],
                perform: { llm.primaryActionID = action.id },
                menuSection: .actions,
                menuParent: "Set ⌘⏎ to",
                menuStateProvider: { llm.primaryActionID == action.id }
            )
        } + [
            RTICommand(
                id: "chat.clear",
                title: "Clear Current Chat",
                keywords: ["delete", "reset"],
                perform: { AppDelegate.clearChatNow() },
                menuSection: .actions
            ),
        ]
    }

    @MainActor
    private static func panelCommands(
        windows: WindowCoordinator,
        llm: LLMController
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "fieldwork.preset",
                title: "Fieldwork Preset (interview + listener + ⌘⏎ Assist)",
                keywords: ["fgd", "idi", "observe", "research", "preset"],
                perform: {
                    let modes = ModeStore.shared
                    if let interview = modes.modes.first(where: { $0.name.localizedCaseInsensitiveContains("interview") }) {
                        modes.activeModeId = interview.id
                    }
                    llm.listenerMode = true
                    llm.primaryActionID = "assist"
                }
            ),
            RTICommand(
                id: "listener.toggle",
                title: "Listener Mode (I'm not speaking)",
                keywords: ["passive", "observer", "listen", "moderator"],
                perform: { llm.listenerMode.toggle() },
                menuSection: .panels,
                menuStateProvider: { llm.listenerMode }
            ),
            RTICommand(
                id: "smart.toggle",
                title: "Smart Mode",
                keywords: ["reasoning", "deep", "enable", "disable"],
                perform: { llm.smartMode.toggle() },
                menuSection: .panels,
                menuStateProvider: { llm.smartMode }
            ),
            RTICommand(
                id: "invisibility.toggle",
                title: "Hidden from Screen Capture",
                keywords: ["sharing", "screencap", "hide", "show", "stealth"],
                perform: { [weak windows] in windows?.toggleInvisibility() },
                menuSection: .panels,
                menuStateProvider: {
                    UserDefaults.standard.object(forKey: OverlayAppearanceDefaults.invisibilityKey) as? Bool ?? true
                }
            ),
            // On/off the translation feature itself. SessionCoordinator observes
            // this default and reconfigures the live transcription clients, so it
            // applies mid-session. (The translation config/panel lives in
            // Settings + the palette's "Toggle Translation Panel".)
            RTICommand(
                id: "translation.toggle",
                title: "Translation",
                keywords: ["translation", "translate", "language", "bilingual"],
                perform: {
                    let d = UserDefaults.standard
                    d.set(!d.bool(forKey: TranslationDefaults.enabledKey), forKey: TranslationDefaults.enabledKey)
                },
                menuSection: .panels,
                menuStateProvider: { UserDefaults.standard.bool(forKey: TranslationDefaults.enabledKey) }
            ),
            RTICommand(
                id: "panel.translation.toggle",
                title: "Toggle Translation Panel",
                keywords: ["translation", "translate", "panel"],
                perform: { [weak windows] in windows?.toggle(.translation) }
            ),
        ]
    }

    @MainActor
    private static func appCommands(
        windows: WindowCoordinator
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "settings.open",
                title: "Settings…",
                subtitle: "⌘,",
                keywords: ["preferences", "config"],
                perform: { [weak windows] in windows?.openSettings() },
                menuSection: .app
            ),
            RTICommand(
                id: "app.about",
                title: "About RTI",
                keywords: ["info", "version"],
                perform: { [weak windows] in windows?.showAbout() },
                menuSection: .app
            ),
            RTICommand(
                id: "app.checkUpdates",
                title: "Check for Updates…",
                keywords: ["update", "upgrade", "version", "release"],
                perform: { UpdateChecker.checkAndReport() },
                menuSection: .app
            ),
            RTICommand(
                id: "app.quit",
                title: "Quit RTI",
                subtitle: "⌘Q",
                perform: { NSApp.terminate(nil) }
            ),
        ]
    }

    @MainActor
    private static func modeSwitchCommands(
        modes: ModeStore,
        llm: LLMController
    ) -> [RTICommand] {
        modes.modes.map { mode in
            RTICommand(
                id: "mode.switch.\(mode.id)",
                title: "Switch to: \(mode.name)",
                keywords: ["mode", "preset"],
                isAvailable: { modes.activeMode?.id != mode.id },
                perform: {
                    modes.activeModeId = mode.id
                    // Per-mode ⌘⏎ binding: meeting mode defaults to
                    // Answer-latest, fieldwork/interview mode keeps the
                    // Assist template (see applyFieldworkPreset above).
                    switch mode.kind {
                    case .meeting: llm.primaryActionID = "answerLatest"
                    case .interview: llm.primaryActionID = "assist"
                    case .coding, .other: break
                    }
                }
            )
        }
    }
}
