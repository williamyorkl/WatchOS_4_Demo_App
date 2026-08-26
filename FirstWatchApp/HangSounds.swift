import AVFoundation

/// Tiny sound-effect helper for the Garden energy-collection "pop".
///
/// Uses `AudioServicesCreateSystemSoundID` (no AVAudioSession setup needed) so
/// it plays even without configuring an audio session — ideal for one-shot UI
/// blips. The system "pop/tap" sound is used as a pleasant "蹦".
enum HangSounds {

    /// System sound ID 1107 = "Tock" (a clean tap). Falls back to the classic
    /// 1306 "pop" if unavailable. Both are short, satisfying UI sounds.
    private static let popSystemSoundID: SystemSoundID = 1107

    /// Play the collect pop. Safe to call from the main thread.
    static func playCollect() {
        AudioServicesPlaySystemSound(popSystemSoundID)
    }

    /// A slightly brighter sound for levelling up the plant stage.
    static func playLevelUp() {
        AudioServicesPlaySystemSound(1057) // "ping"
    }
}
