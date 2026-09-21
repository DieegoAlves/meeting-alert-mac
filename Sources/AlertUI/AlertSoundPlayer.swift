// OWNER: AlertUI module (Sources/AlertUI). Depends on Core ONLY.
//
// AlertSoundPlayer plays the overlay alert sound. Per research/03, NO audio engine is kept alive at
// idle — the player is created ON FIRE and fully released on `stop()` (overlay teardown), so there
// is zero idle audio cost.
//
// F-064 (GROUP 4): volume is controlled independently of the system volume via `AVAudioPlayer.volume`
// (0…1), and the sound can repeat every N seconds until the user interacts (0 == play once). System
// sounds are loaded from /System/Library/Sounds/<name>.aiff so the same volume control applies;
// anything AVAudioPlayer cannot open falls back to NSSound (best-effort, no independent volume).
import AppKit
import AVFoundation
import Core

@MainActor
final class AlertSoundPlayer {
    /// Strong references so ARC does not deallocate playback mid-sound.
    private var avPlayer: AVAudioPlayer?
    private var nsSound: NSSound?
    /// Repeat-every-N-seconds timer. Lives ONLY while a sound is playing (created in `play`,
    /// cancelled in `stop`) — never at idle.
    private var repeatTimer: DispatchSourceTimer?

    /// Play the configured alert sound at `volume` (0…1). When `repeatSeconds > 0`, replay it every
    /// `repeatSeconds` until `stop()`. Any in-flight sound is stopped first.
    func play(_ alertSound: AlertSound, volume: Double, repeatSeconds: Int) {
        stop()

        let clamped = Float(min(1.0, max(0.0, volume)))
        let url = Self.fileURL(for: alertSound)

        if let url, let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = clamped
            player.prepareToPlay()
            avPlayer = player
            player.play()
        } else {
            // Fallback: NSSound (independent volume not guaranteed for named system sounds).
            let sound: NSSound?
            switch alertSound {
            case .system(let name):
                sound = NSSound(named: NSSound.Name(name)) ?? NSSound(named: NSSound.Name("Ping"))
            case .file(let fileURL):
                sound = NSSound(contentsOf: fileURL, byReference: true) ?? NSSound(named: NSSound.Name("Ping"))
            }
            sound?.volume = clamped
            nsSound = sound
            sound?.play()
        }

        if repeatSeconds > 0 {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + Double(repeatSeconds), repeating: Double(repeatSeconds), leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let p = self.avPlayer { p.currentTime = 0; p.play() }
                    else { self.nsSound?.stop(); self.nsSound?.play() }
                }
            }
            t.resume()
            repeatTimer = t
        }
    }

    /// Stop playback, drop the repeat timer and release the player (called on overlay teardown).
    func stop() {
        repeatTimer?.cancel()
        repeatTimer = nil
        avPlayer?.stop()
        avPlayer = nil
        nsSound?.stop()
        nsSound = nil
    }

    /// Resolve a file URL AVAudioPlayer can open: the user's own file, or a named system sound from
    /// /System/Library/Sounds/<name>.aiff. Returns nil when only NSSound can handle it.
    private static func fileURL(for alertSound: AlertSound) -> URL? {
        switch alertSound {
        case .file(let url):
            return url
        case .system(let name):
            let candidate = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }
}
