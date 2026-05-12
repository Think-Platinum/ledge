import Foundation

/// Compile-time identity of this build — written into the binary so the
/// running app can report exactly what's executing, separate from whatever
/// `.app` bundle path it happens to be loaded from.
///
/// The default values below are placeholders for development builds (e.g.
/// Cmd+R from Xcode). `bin/ship` overwrites this file in-place with real
/// `git rev-parse` / build-date values before invoking `xcodebuild`, then
/// restores the placeholder via `git checkout` after the build so the
/// working tree stays clean.
///
/// Surfaced in the Developer Settings → Build section so you can confirm
/// "am I actually running what I just shipped?" without `lsof`.
enum BuildInfo {
    /// Short git SHA at build time (e.g. `7c33680e`) or `"dev"` for an
    /// Xcode-direct build that didn't go through `bin/ship`.
    static let commit: String = "dev"

    /// ISO-8601 UTC timestamp of the build, or `"dev"` for direct builds.
    static let builtAt: String = "dev"

    /// `clean` if the working tree had no uncommitted changes at build
    /// time, `DIRTY` if it did, `dev` for direct builds.
    static let workingTree: String = "dev"

    /// Code-signing identity used by `bin/ship` (e.g. `Ledge Dev`). Empty
    /// for direct builds.
    static let signingIdentity: String = ""

    /// Human-friendly one-line summary suitable for the Settings UI and
    /// log lines. Format: `<commit> (<workingTree>) <builtAt>`.
    static var summary: String {
        var parts = [commit]
        if !workingTree.isEmpty && workingTree != "dev" {
            parts[0] = "\(commit) (\(workingTree))"
        }
        if builtAt != "dev" {
            parts.append(builtAt)
        }
        return parts.joined(separator: " · ")
    }
}
