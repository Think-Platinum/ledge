import SwiftUI

/// Step-by-step guide for setting up Spotify Web API integration.
///
/// Walks the user through creating a Spotify Developer app, configuring the
/// redirect URI, and pasting their Client ID into Ledge.
struct SpotifySetupGuide: View {

    @Environment(\.dismiss) private var dismiss

    /// The exact redirect URI the user must register in the Spotify Developer Dashboard.
    private let redirectURI = SpotifyAuthManager.redirectURI

    /// Tracks which step the user is on (0-indexed, nil = overview).
    @State private var currentStep: Int? = nil

    /// For the copy-to-clipboard feedback.
    @State private var copiedRedirectURI = false
    @State private var copiedScopes = false

    private let steps: [(title: String, icon: String)] = [
        ("Create a Spotify App", "plus.circle"),
        ("Configure Redirect URI", "link"),
        ("Copy Your Client ID", "doc.on.doc"),
        ("Paste into Ledge", "checkmark.circle"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if currentStep == nil {
                        overviewContent
                    } else {
                        stepContent(for: currentStep!)
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer navigation
            footer
        }
        .frame(width: 520, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 24))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Spotify Web API Setup")
                    .font(.headline)
                if let step = currentStep {
                    Text("Step \(step + 1) of \(steps.count): \(steps[step].title)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Control Spotify across all your devices")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Step indicators
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(stepColor(for: i))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func stepColor(for index: Int) -> Color {
        guard let current = currentStep else { return .secondary.opacity(0.3) }
        if index < current { return .green }
        if index == current { return .green }
        return .secondary.opacity(0.3)
    }

    // MARK: - Overview

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Why Web API?")
                .font(.title3.bold())

            Text("By default, the Spotify widget talks directly to the Spotify desktop app on your Mac using AppleScript. This works great for local playback — no setup needed.")
                .foregroundStyle(.secondary)

            Text("The Web API adds cross-device control. You can see what's playing on your phone, smart speaker, or any other device — and control playback from Ledge.")
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 4)

            Text("What you'll need")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 10) {
                requirement(icon: "person.circle",
                           title: "A Spotify account",
                           detail: "Free or Premium — both work for reading playback state. Premium is required for playback control.")

                requirement(icon: "globe",
                           title: "A Spotify Developer app",
                           detail: "Free to create at developer.spotify.com. Takes about 2 minutes.")

                requirement(icon: "key",
                           title: "Your app's Client ID",
                           detail: "A public identifier (not a secret). Each Ledge user creates their own.")
            }

            Divider()
                .padding(.vertical, 4)

            Text("This guide will walk you through each step.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func requirement(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.green)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private func stepContent(for step: Int) -> some View {
        switch step {
        case 0: step1_CreateApp
        case 1: step2_RedirectURI
        case 2: step3_CopyClientID
        case 3: step4_PasteIntoLedge
        default: EmptyView()
        }
    }

    private var step1_CreateApp: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a Spotify Developer App")
                .font(.title3.bold())

            numberedInstruction(1, "Go to the Spotify Developer Dashboard:")

            Link("developer.spotify.com/dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                .font(.callout)
                .padding(.leading, 28)

            numberedInstruction(2, "Sign in with your Spotify account.")

            numberedInstruction(3, "Click \"Create app\".")

            numberedInstruction(4, "Fill in the form:")

            VStack(alignment: .leading, spacing: 8) {
                fieldExample(label: "App name", value: "Ledge")
                fieldExample(label: "App description", value: "Ledge widget dashboard")
                fieldExample(label: "Website", value: "Leave blank or enter any URL")
            }
            .padding(.leading, 28)

            numberedInstruction(5, "Under \"Which API/SDKs are you planning to use?\", select Web API.")

            numberedInstruction(6, "Check the terms of service box and click Save.")

            infoBox("You're creating a personal developer app — it's limited to your Spotify account only (Spotify's Development Mode). No approval process is needed.")
        }
    }

    private var step2_RedirectURI: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure the Redirect URI")
                .font(.title3.bold())

            numberedInstruction(1, "From your app's dashboard, click Settings.")

            numberedInstruction(2, "Under \"Redirect URIs\", click Add new Redirect URI.")

            numberedInstruction(3, "Paste this exact URI:")

            copiableField(text: redirectURI, copied: $copiedRedirectURI)
                .padding(.leading, 28)

            numberedInstruction(4, "Click Add, then Save at the bottom of the page.")

            warningBox("The redirect URI must match exactly — including the port number (\(SpotifyAuthManager.redirectPort)). Spotify will reject the auth flow if it doesn't match.")
        }
    }

    private var step3_CopyClientID: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy Your Client ID")
                .font(.title3.bold())

            numberedInstruction(1, "From your app's dashboard, click Settings.")

            numberedInstruction(2, "You'll see your Client ID near the top — it looks like a long hex string.")

            fieldExample(label: "Client ID", value: "a1b2c3d4e5f6...")

            numberedInstruction(3, "Click the copy icon next to the Client ID to copy it to your clipboard.")

            infoBox("You only need the Client ID, not the Client Secret. Ledge uses PKCE (Proof Key for Code Exchange), which is a secure OAuth flow that doesn't require a secret.")
        }
    }

    private var step4_PasteIntoLedge: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste into Ledge")
                .font(.title3.bold())

            numberedInstruction(1, "Close this guide — you'll be back on the Spotify widget settings.")

            numberedInstruction(2, "Enable \"Use Spotify Web API\" if it isn't already.")

            numberedInstruction(3, "Paste your Client ID into the Client ID field.")

            numberedInstruction(4, "Click \"Sign in with Spotify\".")

            numberedInstruction(5, "Your browser will open Spotify's authorization page. Click Agree to grant Ledge access.")

            numberedInstruction(6, "You'll see a confirmation page — switch back to Ledge. You're all set!")

            Divider()
                .padding(.vertical, 4)

            Text("What happens next")
                .font(.callout.bold())

            Text("Once signed in, the Spotify widget will show what's playing on any of your devices. You can use the Devices section in settings to transfer playback between them.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Your tokens are stored securely in the macOS Keychain. You'll stay signed in across app launches — Ledge automatically refreshes the token when it expires.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Reusable Components

    private func numberedInstruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.callout.bold())
                .foregroundStyle(.green)
                .frame(width: 20, alignment: .trailing)

            Text(text)
                .font(.callout)
        }
    }

    private func fieldExample(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func copiableField(text: String, copied: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied.wrappedValue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied.wrappedValue = false
                }
            } label: {
                Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied.wrappedValue ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
    }

    private func infoBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func warningBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer Navigation

    private var footer: some View {
        HStack {
            if currentStep != nil {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let step = currentStep {
                            currentStep = step > 0 ? step - 1 : nil
                        }
                    }
                }
            }

            Spacer()

            if let step = currentStep, step == steps.count - 1 {
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(currentStep == nil ? "Get Started" : "Next") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let step = currentStep {
                            currentStep = step + 1
                        } else {
                            currentStep = 0
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}
