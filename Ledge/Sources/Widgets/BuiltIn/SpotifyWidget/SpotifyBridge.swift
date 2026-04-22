import Foundation
import os.log

/// Bridge to Spotify via AppleScript for local playback control.
///
/// Uses AppleScript to query Spotify state and control playback without
/// requiring any authentication or API keys.
///
/// Must be `nonisolated` — NSAppleScript blocks the calling thread, and the
/// project default actor isolation is MainActor. Callers should dispatch
/// from a background context (`Task.detached` or an actor).
nonisolated class SpotifyBridge: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.ledge.app", category: "SpotifyBridge")
    private let debugLog = DebugLogger(category: "SpotifyBridge")

    /// Serial queue for all AppleScript execution. NSAppleScript is not thread-safe
    /// and requires consistent thread affinity for AppleEvent dispatch. Shared with
    /// GoogleMeetBridge via `AppleScriptQueue.shared` to prevent concurrent AppleScript
    /// execution across different bridges from crashing the runtime.
    private let scriptQueue = AppleScriptQueue.shared

    struct PlaybackState: Sendable {
        var isPlaying: Bool = false
        var trackName: String = ""
        var artistName: String = ""
        var albumName: String = ""
        var artworkURL: String = ""
        var trackDuration: Double = 0  // seconds
        var playerPosition: Double = 0  // seconds
        var volume: Int = 50  // 0-100
    }

    /// Whether Spotify is currently running.
    func isSpotifyRunning() -> Bool {
        let script = """
        tell application "System Events"
            return (name of processes) contains "Spotify"
        end tell
        """
        return runAppleScript(script) == "true"
    }

    /// Fetch current playback state.
    func fetchPlaybackState() -> PlaybackState {
        let script = """
        tell application "Spotify"
            if player state is playing then
                set isPlaying to "true"
            else
                set isPlaying to "false"
            end if
            set vol to sound volume
            try
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                set artURL to artwork url of current track
                set trackDur to (duration of current track) / 1000
                set playerPos to player position
                return isPlaying & "|||" & trackName & "|||" & artistName & "|||" & albumName & "|||" & artURL & "|||" & (trackDur as text) & "|||" & (playerPos as text) & "|||" & (vol as text)
            on error
                return isPlaying & "|||" & "" & "|||" & "" & "|||" & "" & "|||" & "" & "|||" & "0" & "|||" & "0" & "|||" & (vol as text)
            end try
        end tell
        """

        guard let result = runAppleScript(script) else { return PlaybackState() }

        let parts = result.components(separatedBy: "|||")
        guard parts.count >= 7 else { return PlaybackState() }

        return PlaybackState(
            isPlaying: parts[0] == "true",
            trackName: parts[1],
            artistName: parts[2],
            albumName: parts[3],
            artworkURL: parts[4],
            trackDuration: Double(parts[5]) ?? 0,
            playerPosition: Double(parts[6]) ?? 0,
            volume: parts.count >= 8 ? (Int(parts[7]) ?? 50) : 50
        )
    }

    /// Play/pause toggle.
    func playPause() {
        runAppleScriptFire("tell application \"Spotify\" to playpause")
    }

    /// Skip to next track.
    func nextTrack() {
        runAppleScriptFire("tell application \"Spotify\" to next track")
    }

    /// Skip to previous track.
    func previousTrack() {
        runAppleScriptFire("tell application \"Spotify\" to previous track")
    }

    /// Set Spotify's internal volume (0-100).
    func setVolume(_ volume: Int) {
        let clamped = max(0, min(100, volume))
        runAppleScriptFire("tell application \"Spotify\" to set sound volume to \(clamped)")
    }

    /// Set the player position (seek) to the given number of seconds.
    func setPosition(_ seconds: Double) {
        let clamped = max(0, seconds)
        runAppleScriptFire("tell application \"Spotify\" to set player position to \(clamped)")
    }

    /// Skip forward by the given number of seconds.
    func skipForward(_ seconds: Double = 10) {
        let script = """
        tell application "Spotify"
            set newPos to (player position + \(seconds))
            set dur to (duration of current track) / 1000
            if newPos > dur then set newPos to dur
            set player position to newPos
        end tell
        """
        runAppleScriptFire(script)
    }

    /// Skip backward by the given number of seconds.
    func skipBackward(_ seconds: Double = 10) {
        let script = """
        tell application "Spotify"
            set newPos to (player position - \(seconds))
            if newPos < 0 then set newPos to 0
            set player position to newPos
        end tell
        """
        runAppleScriptFire(script)
    }

    /// Bring Spotify to the foreground.
    func activateSpotify() {
        runAppleScriptFire("tell application \"Spotify\" to activate")
    }

    // MARK: - Private

    /// Execute AppleScript synchronously on the serial script queue.
    /// All NSAppleScript usage goes through the same queue for thread safety.
    @discardableResult
    private func runAppleScript(_ source: String) -> String? {
        scriptQueue.sync {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return nil }
            let result = script.executeAndReturnError(&error)
            if let error {
                debugLog.debug("AppleScript error: \(error)")
                return nil
            }
            return result.stringValue
        }
    }

    /// Fire-and-forget AppleScript on the serial script queue.
    private func runAppleScriptFire(_ source: String) {
        scriptQueue.async { [debugLog] in
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return }
            script.executeAndReturnError(&error)
            if let error {
                debugLog.debug("AppleScript fire error: \(error)")
            }
        }
    }
}
