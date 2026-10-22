import AVFoundation

/// The app's feedback sounds, loaded once at launch so they play instantly.
enum SoundFX {
    /// Finder's own "move to trash" sound. (The named system sound "Pop" stutters on macOS 26.)
    nonisolated(unsafe) private static let trashPlayer = player(
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif")

    /// The sound for moving items to the Trash.
    static func trash() {
        guard let p = trashPlayer else { return }
        p.currentTime = 0
        p.play()
    }

    /// Call at launch so the first play has no decoding delay.
    static func prepare() { trashPlayer?.prepareToPlay() }

    private static func player(_ path: String) -> AVAudioPlayer? {
        try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
    }
}
