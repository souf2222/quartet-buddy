import Foundation

/// UserDefaults key constants — one place for every persisted-key string,
/// so a typo can't silently fork the settings storage.
///
/// Note: InsertServer keeps its own private key helpers (the
/// `insertPair.<i>.*` family) inside the type that owns them.
enum UserDefaultsKeys {
    // AutoGain settings
    static let autoGainTargetDBFS = "autoGainTargetDBFS"
    static let autoGainListenSeconds = "autoGainListenSeconds"

    // AdatGain (Optical Gain Assistant) settings
    static let adatAssistTargetDBFS = "adatAssistTargetDBFS"
    static let adatAssistDurationSeconds = "adatAssistDurationSeconds"
    static let adatAssistToleranceDB = "adatAssistToleranceDB"

    // ADAT per-channel names (Settings ▸ Channel Names)
    static func adatName(_ index: Int) -> String { "adatName.\(index)" }

    // Hardware output trims
    static func hwoutTrim(_ pair: Int) -> String { "hwout.trim.\(pair)" }

    // Plug-in migration (v1 single-plugin → pair 0)
    static let insertPluginDesc = "insertPluginDesc"

    // Plug-in slot picker (Quartet Control window)
    static func insertPairPlugin(_ pair: Int) -> String { "insertPair.\(pair).plugin" }

    // Shortcuts
    static let volumeStep = "volumeStep"
    static let fineStep = "fineStep"
}
