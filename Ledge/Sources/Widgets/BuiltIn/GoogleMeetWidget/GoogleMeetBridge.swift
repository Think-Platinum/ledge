import Foundation
import os.log

/// Bridge to Google Chrome for Google Meet control via AppleScript + JavaScript injection.
///
/// Uses AppleScript to find Meet tabs in Chrome, then injects JavaScript to
/// read mic/camera state and toggle controls. Requires Automation permission
/// for Chrome (macOS prompts on first use).
///
/// Must be `nonisolated` — NSAppleScript blocks the calling thread, and the
/// project default actor isolation is MainActor. Callers should dispatch
/// from a background context (`Task.detached` or an actor).
nonisolated class GoogleMeetBridge: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.ledge.app", category: "GoogleMeetBridge")
    private let debugLog = DebugLogger(category: "GoogleMeetBridge")

    /// Serial queue for all AppleScript execution. NSAppleScript is not thread-safe
    /// and requires consistent thread affinity for AppleEvent dispatch. Shared with
    /// SpotifyBridge via `AppleScriptQueue.shared` to prevent concurrent AppleScript
    /// execution across different bridges from crashing the runtime.
    private let scriptQueue = AppleScriptQueue.shared

    struct MeetState: Sendable {
        var chromeRunning: Bool = false
        var inMeeting: Bool = false
        var meetingTitle: String = ""
        var isMicMuted: Bool = false
        var isCameraMuted: Bool = false
        var automationDenied: Bool = false
        var jsDisabled: Bool = false
    }

    // MARK: - State Query

    /// Fetch the current Google Meet state from Chrome.
    func getState() -> MeetState {
        // JavaScript to extract Meet state from the DOM.
        // Google Meet uses `data-is-muted` on mic/camera toggle buttons.
        // First match is mic, second is camera.
        let stateJS = #"(function(){var r={m:false,t:'',mic:false,cam:false};var b=document.querySelectorAll('[data-is-muted]');if(b.length>=2){r.m=true;r.mic=b[0].getAttribute('data-is-muted')==='true';r.cam=b[1].getAttribute('data-is-muted')==='true';}else if(b.length>=1){r.m=true;r.mic=b[0].getAttribute('data-is-muted')==='true';}r.t=document.title.replace(/ - Google Meet$/,'').replace(/^Meet - /,'');return JSON.stringify(r);})()"#

        let script = """
        tell application "System Events"
            set chromeRunning to (name of processes) contains "Google Chrome"
        end tell

        if not chromeRunning then
            return "not_running"
        end if

        tell application "Google Chrome"
            repeat with w in windows
                set tc to count of tabs of w
                repeat with i from 1 to tc
                    set t to tab i of w
                    if URL of t contains "meet.google.com/" then
                        try
                            set jsResult to execute t javascript "\(stateJS)"
                            return jsResult
                        on error
                            return "js_error"
                        end try
                    end if
                end repeat
            end repeat
        end tell

        return "no_meet"
        """

        let (result, errorNumber) = runAppleScriptWithError(script)

        guard let result else {
            if errorNumber == -1743 {
                var state = MeetState()
                state.automationDenied = true
                return state
            }
            return MeetState()
        }

        switch result {
        case "not_running":
            return MeetState()

        case "no_meet":
            var state = MeetState()
            state.chromeRunning = true
            return state

        case "js_error":
            var state = MeetState()
            state.chromeRunning = true
            state.jsDisabled = true
            return state

        default:
            return parseStateJSON(result)
        }
    }

    // MARK: - Controls

    /// Toggle the microphone in the active Google Meet session.
    func toggleMic() {
        let js = #"(function(){var b=document.querySelectorAll('[data-is-muted]');if(b.length>=1)b[0].click();return 'ok';})()"#
        executeOnMeetTab(js)
    }

    /// Toggle the camera in the active Google Meet session.
    func toggleCamera() {
        let js = #"(function(){var b=document.querySelectorAll('[data-is-muted]');if(b.length>=2)b[1].click();return 'ok';})()"#
        executeOnMeetTab(js)
    }

    // MARK: - Private

    private func parseStateJSON(_ json: String) -> MeetState {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            var state = MeetState()
            state.chromeRunning = true
            return state
        }

        var state = MeetState()
        state.chromeRunning = true
        state.inMeeting = obj["m"] as? Bool ?? false
        state.meetingTitle = obj["t"] as? String ?? ""
        state.isMicMuted = obj["mic"] as? Bool ?? false
        state.isCameraMuted = obj["cam"] as? Bool ?? false
        return state
    }

    private func executeOnMeetTab(_ javascript: String) {
        let script = """
        tell application "Google Chrome"
            repeat with w in windows
                set tc to count of tabs of w
                repeat with i from 1 to tc
                    set t to tab i of w
                    if URL of t contains "meet.google.com/" then
                        try
                            execute t javascript "\(javascript)"
                        end try
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        _ = runAppleScriptWithError(script)
    }

    /// Execute AppleScript synchronously on the shared serial script queue.
    /// All NSAppleScript usage goes through the same queue for thread safety.
    private func runAppleScriptWithError(_ source: String) -> (String?, Int) {
        // No `[logger]` capture — closure body uses the per-widget `debugLog`
        // filter, not the raw os.log Logger. Capturing `logger` was leftover
        // from before the debug-log refactor.
        scriptQueue.sync {
            let appleScript = NSAppleScript(source: source)
            var errorDict: NSDictionary?
            let result = appleScript?.executeAndReturnError(&errorDict)

            if let error = errorDict {
                let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? 0
                debugLog.debug("AppleScript error \(errorNumber): \(error)")
                return (nil, errorNumber)
            }

            return (result?.stringValue, 0)
        }
    }
}
