import Foundation
import AppKit
import Carbon.HIToolbox

/// Every action that can carry a keyboard shortcut, grouped exactly like
/// the Shortcuts settings pane:
///
///   Window & Navigation · Speakers · Headphones · Volume-Control Target ·
///   Talkback · Plug-ins · Outputs & Routing · Inputs · Safety
///
/// A binding is either GLOBAL (a system-wide hotkey via RegisterEventHotKey,
/// works from any app) or APP-ONLY (matched by a local event monitor while
/// the Quartet Control window is key). `defaultGlobal` is the proposed
/// default scope from the settings-window design — the user flips it per
/// action. The GLOBAL column in the settings table binds to it.
///
/// Key codes here use Carbon virtual-key codes; defaults follow the
/// practical layout (⌘1–⌘4 outputs, ⌥1–⌥4 inputs, ⌘, settings, ⇧⌘T talkback).
enum ShortcutAction: String, CaseIterable {

    // Window & Navigation
    case showHideWindow
    case showQuickPanel
    case pinPanel
    case openSettings
    case selectNextOutput
    case selectPreviousOutput

    // Speakers (monitor 0)
    case speakerMute
    case speakerDim
    case speakerSum
    case speakerVolumeUp
    case speakerVolumeDown
    case speakerFineUp
    case speakerFineDown

    // Headphones (monitor 1)
    case headphoneMute
    case headphoneDim
    case headphoneSum
    case headphoneVolumeUp
    case headphoneVolumeDown
    case headphoneFineUp
    case headphoneFineDown

    // Volume-Control Target
    case selectSpeakersTarget
    case selectHeadphonesTarget
    case switchTarget
    case targetVolumeUp
    case targetVolumeDown

    // Talkback
    case talkbackHold
    case talkbackToggle

    // Plug-ins
    case bypassAllPlugins
    case toggleInsert
    case bypassSelectedOutput
    case openSelectedPlugin

    // Outputs & Routing (app-only by default)
    case selectOutput1
    case selectOutput2
    case selectOutput3
    case selectOutput4
    case outputTrimUp
    case outputTrimDown
    case editOutputTrim
    case openSourceSelector
    case cycleStage

    // Inputs (app-only by default)
    case selectInput1
    case selectInput2
    case selectInput3
    case selectInput4
    case inputGainUp
    case inputGainDown
    case editInputGain
    case autoGainSelectedInput
    case autoGainAllInputs
    case cancelAutoGain
    case toggleSoftLimit
    case togglePolarity

    // Safety
    /// Emergency mute — ALWAYS engages, never unmutes (a panic command
    /// must never make sound by surprise).
    case muteAllOutputs

    // MARK: presentation

    /// Section heading in the settings table.
    var section: String {
        switch self {
        case .showHideWindow, .showQuickPanel, .pinPanel, .openSettings, .selectNextOutput, .selectPreviousOutput:
            return "Window & Navigation"
        case .speakerMute, .speakerDim, .speakerSum, .speakerVolumeUp, .speakerVolumeDown,
             .speakerFineUp, .speakerFineDown:
            return "Speakers"
        case .headphoneMute, .headphoneDim, .headphoneSum, .headphoneVolumeUp, .headphoneVolumeDown,
             .headphoneFineUp, .headphoneFineDown:
            return "Headphones"
        case .selectSpeakersTarget, .selectHeadphonesTarget, .switchTarget,
             .targetVolumeUp, .targetVolumeDown:
            return "Volume-Control Target"
        case .talkbackHold, .talkbackToggle:
            return "Talkback"
        case .bypassAllPlugins, .toggleInsert, .bypassSelectedOutput, .openSelectedPlugin:
            return "Plug-ins"
        case .selectOutput1, .selectOutput2, .selectOutput3, .selectOutput4,
             .outputTrimUp, .outputTrimDown, .editOutputTrim, .openSourceSelector, .cycleStage:
            return "Outputs & Routing"
        case .selectInput1, .selectInput2, .selectInput3, .selectInput4,
             .inputGainUp, .inputGainDown, .editInputGain, .autoGainSelectedInput,
             .autoGainAllInputs, .cancelAutoGain, .toggleSoftLimit, .togglePolarity:
            return "Inputs"
        case .muteAllOutputs:
            return "Safety"
        }
    }

    /// Row label in the settings table (mockup wording).
    var title: String {
        switch self {
        case .showHideWindow: return "Show / hide Quartet Control"
        case .showQuickPanel: return "Show / hide quick-control panel"
        case .pinPanel: return "Pin / unpin the control panel"
        case .openSettings: return "Open Settings"
        case .selectNextOutput: return "Select next output"
        case .selectPreviousOutput: return "Select previous output"
        case .speakerMute: return "Toggle mute"
        case .speakerDim: return "Toggle dim"
        case .speakerSum: return "Toggle mono / SUM"
        case .speakerVolumeUp: return "Volume up"
        case .speakerVolumeDown: return "Volume down"
        case .speakerFineUp: return "Fine volume up"
        case .speakerFineDown: return "Fine volume down"
        case .headphoneMute: return "Toggle mute"
        case .headphoneDim: return "Toggle dim"
        case .headphoneSum: return "Toggle mono / SUM"
        case .headphoneVolumeUp: return "Volume up"
        case .headphoneVolumeDown: return "Volume down"
        case .headphoneFineUp: return "Fine volume up"
        case .headphoneFineDown: return "Fine volume down"
        case .selectSpeakersTarget: return "Select speakers"
        case .selectHeadphonesTarget: return "Select headphones"
        case .switchTarget: return "Switch speakers / headphones"
        case .targetVolumeUp: return "Active-target volume up"
        case .targetVolumeDown: return "Active-target volume down"
        case .talkbackHold: return "Hold to talk"
        case .talkbackToggle: return "Toggle talkback"
        case .bypassAllPlugins: return "Bypass all plug-ins"
        case .toggleInsert: return "Start / stop plug-in insert"
        case .bypassSelectedOutput: return "Bypass selected output's processing"
        case .openSelectedPlugin: return "Open selected output's plug-in"
        case .selectOutput1: return "Select Main Speakers"
        case .selectOutput2: return "Select Out 3–4"
        case .selectOutput3: return "Select Headphone Amp"
        case .selectOutput4: return "Select Headphones 2"
        case .outputTrimUp: return "Output trim up"
        case .outputTrimDown: return "Output trim down"
        case .editOutputTrim: return "Edit output trim"
        case .openSourceSelector: return "Open source selector"
        case .cycleStage: return "Cycle source signal stage"
        case .selectInput1: return "Select Analog In 1"
        case .selectInput2: return "Select Analog In 2"
        case .selectInput3: return "Select Analog In 3"
        case .selectInput4: return "Select Analog In 4"
        case .inputGainUp: return "Selected input gain up"
        case .inputGainDown: return "Selected input gain down"
        case .editInputGain: return "Edit selected input gain"
        case .autoGainSelectedInput: return "Auto Gain selected input"
        case .autoGainAllInputs: return "Auto Gain all inputs"
        case .cancelAutoGain: return "Cancel Auto Gain"
        case .toggleSoftLimit: return "Toggle Soft Limit"
        case .togglePolarity: return "Toggle polarity inversion"
        case .muteAllOutputs: return "Mute all monitoring outputs"
        }
    }

    /// True when the action may be bound globally. Everything can — the
    /// app-only defaults above are proposals, and the user decides per row.
    var allowGlobal: Bool { true }

    /// Proposed default scope (the ☑ column in the design).
    var defaultGlobal: Bool {
        switch self {
        case .showHideWindow: return true
        case .showQuickPanel: return true
        // ⌘P is the app's pin toggle — APP-ONLY by default (matched by the
        // local monitor while the control panel is focused), so the
        // global ⌘P of other applications is never intercepted.
        case .pinPanel: return false
        case .openSettings: return false
        case .selectNextOutput, .selectPreviousOutput: return false
        case .speakerMute, .speakerDim, .speakerVolumeUp, .speakerVolumeDown: return true
        case .speakerSum, .speakerFineUp, .speakerFineDown: return false
        case .headphoneMute, .headphoneDim, .headphoneVolumeUp, .headphoneVolumeDown: return true
        case .headphoneSum, .headphoneFineUp, .headphoneFineDown: return false
        case .selectSpeakersTarget, .selectHeadphonesTarget, .switchTarget,
             .targetVolumeUp, .targetVolumeDown: return true
        case .talkbackHold, .talkbackToggle: return true
        case .bypassAllPlugins: return true
        case .toggleInsert, .bypassSelectedOutput, .openSelectedPlugin: return false
        case .selectOutput1, .selectOutput2, .selectOutput3, .selectOutput4: return false
        case .outputTrimUp, .outputTrimDown, .editOutputTrim,
             .openSourceSelector, .cycleStage: return false
        case .selectInput1, .selectInput2, .selectInput3, .selectInput4: return false
        case .inputGainUp, .inputGainDown, .editInputGain, .autoGainSelectedInput,
             .autoGainAllInputs, .cancelAutoGain, .toggleSoftLimit, .togglePolarity: return false
        case .muteAllOutputs: return true
        }
    }

    /// Default key combination for "Restore Defaults…" (nil = unbound).
    var defaultCombo: HotKeyManager.Combo? {
        func combo(_ code: UInt32, _ mods: UInt32) -> HotKeyManager.Combo {
            .init(keyCode: code, modifiers: mods)
        }
        switch self {
        case .showQuickPanel: return combo(UInt32(kVK_ANSI_C), UInt32(optionKey))
        case .pinPanel: return combo(UInt32(kVK_ANSI_P), UInt32(cmdKey))
        case .openSettings: return combo(UInt32(kVK_ANSI_Comma), UInt32(cmdKey))
        case .talkbackToggle: return combo(UInt32(kVK_ANSI_T), UInt32(cmdKey | shiftKey))
        case .selectOutput1: return combo(UInt32(kVK_ANSI_1), UInt32(cmdKey))
        case .selectOutput2: return combo(UInt32(kVK_ANSI_2), UInt32(cmdKey))
        case .selectOutput3: return combo(UInt32(kVK_ANSI_3), UInt32(cmdKey))
        case .selectOutput4: return combo(UInt32(kVK_ANSI_4), UInt32(cmdKey))
        case .selectInput1: return combo(UInt32(kVK_ANSI_1), UInt32(optionKey))
        case .selectInput2: return combo(UInt32(kVK_ANSI_2), UInt32(optionKey))
        case .selectInput3: return combo(UInt32(kVK_ANSI_3), UInt32(optionKey))
        case .selectInput4: return combo(UInt32(kVK_ANSI_4), UInt32(optionKey))
        default: return nil
        }
    }
}

/// Owns every keyboard shortcut: persistence, global registration,
/// app-only matching, conflict detection, defaults.
///
///   • GLOBAL bindings register system-wide hotkeys (one HotKeyManager per
///     action, unique signature+id — handed out by action index).
///   • APP-ONLY bindings are matched by AppDelegate's local event monitor
///     while the Quartet Control window is key (see matchLocal).
///
/// Bindings persist as one JSON dictionary in UserDefaults. The legacy
/// per-feature keys ("hotkeyCombo" talkback, "hotkeySwitchCombo" output
/// switch) migrate in on first launch.
final class ShortcutManager {

    /// One persisted binding: the combination + whether it is global.
    struct Binding: Codable, Equatable {
        var combo: HotKeyManager.Combo
        var isGlobal: Bool
    }

    /// Fired with the action on key-down (and key-up for hold actions).
    var perform: ((ShortcutAction, _ keyDown: Bool) -> Void)?

    /// Current bindings. Empty entry = unbound.
    private(set) var bindings: [ShortcutAction: Binding] = [:]

    private var managers: [ShortcutAction: HotKeyManager] = [:]
    private static let signature: OSType = 0x51425348   // 'QBSH'
    private static let defaultsKey = "shortcutBindings"

    // MARK: - Steps (adjusted in Shortcuts settings)

    /// Coarse per-press volume step (dB).
    var volumeStep: Double {
        get { Self.positiveStep("volumeStep", 2) }
        set { UserDefaults.standard.set(newValue, forKey: "volumeStep") }
    }
    /// Fine per-press volume step (dB).
    var fineStep: Double {
        get { Self.positiveStep("fineStep", 0.5) }
        set { UserDefaults.standard.set(newValue, forKey: "fineStep") }
    }
    private static func positiveStep(_ key: String, _ def: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : def
    }

    // MARK: - Global master switch

    /// "Enable global shortcuts" — unchecking it unregisters every global
    /// hotkey (app-only bindings keep working while Quartet Control is key).
    var globalEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "globalShortcutsEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "globalShortcutsEnabled")
            registerAll()
        }
    }

    // MARK: - Lifecycle

    init() { load() }

    /// (Re)register every global binding with the system.
    func registerAll() {
        for action in ShortcutAction.allCases {
            guard let binding = bindings[action], binding.isGlobal else {
                managers[action]?.unregister()
                continue
            }
            if globalEnabled {
                manager(for: action).register(binding.combo)
            } else {
                managers[action]?.unregister()
            }
        }
    }

    // MARK: - Bindings

    /// Assign (or clear, with a nil combo) an action's shortcut. Displaces
    /// any other binding holding the same combination and returns it —
    /// the settings window warns before calling when a conflict exists.
    @discardableResult
    func assign(_ action: ShortcutAction, combo: HotKeyManager.Combo?, isGlobal: Bool) -> ShortcutAction? {
        let displaced = combo.flatMap { conflict(for: $0, excluding: action) }
        managers[action]?.unregister()
        if let combo {
            bindings[action] = Binding(combo: combo, isGlobal: isGlobal && action.allowGlobal)
            if bindings[action]!.isGlobal && globalEnabled {
                manager(for: action).register(combo)
            }
        } else {
            bindings[action] = nil
        }
        persist()
        return displaced
    }

    /// Another action already holding this combination, if any.
    func conflict(for combo: HotKeyManager.Combo, excluding action: ShortcutAction) -> ShortcutAction? {
        bindings.first { $0.key != action && $0.value.combo == combo }?.key
    }

    /// App-only match for a key-down event while Quartet Control is key.
    func matchLocal(_ event: NSEvent) -> ShortcutAction? {
        let mods = HotKeyRecorder.carbonModifiers(from: event.modifierFlags)
        return bindings.first { binding in
            guard !binding.value.isGlobal else { return false }
            return binding.value.combo.keyCode == UInt32(event.keyCode)
                && binding.value.combo.modifiers == mods
        }?.key
    }

    /// Restore the designed default bindings + scopes ("Restore Defaults…").
    func restoreDefaults() {
        bindings = [:]
        for action in ShortcutAction.allCases {
            if let combo = action.defaultCombo {
                bindings[action] = Binding(combo: combo, isGlobal: action.defaultGlobal && action.allowGlobal)
            }
        }
        registerAll()
        persist()
    }

    // MARK: - Internals

    private func manager(for action: ShortcutAction) -> HotKeyManager {
        if let mgr = managers[action] { return mgr }
        let id = 100 + UInt32(ShortcutAction.allCases.firstIndex(of: action) ?? 0)
        let mgr = HotKeyManager(signature: Self.signature, id: id)
        mgr.onHotKey = { [weak self] in self?.fire(action, keyDown: true) }
        if action == .talkbackHold {
            mgr.onHotKeyUp = { [weak self] in self?.fire(action, keyDown: false) }
        }
        managers[action] = mgr
        return mgr
    }

    private func fire(_ action: ShortcutAction, keyDown: Bool) {
        QBLog.log("shortcut: \(action.rawValue) \(keyDown ? "↓" : "↑")")
        perform?(action, keyDown)
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: Binding].self, from: data) {
            for (key, binding) in saved {
                if let action = ShortcutAction(rawValue: key) { bindings[action] = binding }
            }
            // Actions added after the user's bindings were persisted carry
            // no entry — seed those with their designed defaults (e.g. the
            // quick panel's ⌥C), so a new action is bound out of the box.
            for action in ShortcutAction.allCases where bindings[action] == nil {
                if let combo = action.defaultCombo {
                    bindings[action] = Binding(combo: combo,
                                                isGlobal: action.defaultGlobal && action.allowGlobal)
                }
            }
            persist()
            return
        }
        // One-time migration from the old per-feature hotkeys:
        //   talkback hotkey → Talkback (toggle), switch-output → Switch Target.
        if let data = UserDefaults.standard.data(forKey: "hotkeyCombo"),
           let combo = try? JSONDecoder().decode(HotKeyManager.Combo.self, from: data) {
            bindings[.talkbackToggle] = Binding(combo: combo, isGlobal: true)
        }
        if let data = UserDefaults.standard.data(forKey: "hotkeySwitchCombo"),
           let combo = try? JSONDecoder().decode(HotKeyManager.Combo.self, from: data) {
            bindings[.switchTarget] = Binding(combo: combo, isGlobal: true)
        }
        UserDefaults.standard.removeObject(forKey: "hotkeyCombo")
        UserDefaults.standard.removeObject(forKey: "hotkeySwitchCombo")
        // Seed the designed defaults only when nothing was migrated —
        // first-launch out-of-box experience.
        if bindings.isEmpty { restoreDefaults() }
        persist()
    }

    private func persist() {
        let saved = Dictionary(uniqueKeysWithValues:
            bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}