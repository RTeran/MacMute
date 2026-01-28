import SwiftUI

struct ShortcutConfigView: View {
    @ObservedObject var muteStateManager: MuteStateManager
    @State private var isRecording = false
    @State private var recordedShortcut: String = ""

    var body: some View {
        VStack(spacing: 16) {
            // Status indicator
            HStack {
                Image(systemName: muteStateManager.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundColor(muteStateManager.isMuted ? .red : .green)
                Text(muteStateManager.isMuted ? "Microphone Muted" : "Microphone Active")
                    .font(.headline)
            }
            .padding(.top, 8)

            Divider()

            // Shortcut configuration
            VStack(alignment: .leading, spacing: 8) {
                Text("Global Shortcut")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Text(currentShortcutDisplay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                        )

                    Button(isRecording ? "Cancel" : "Record") {
                        if isRecording {
                            isRecording = false
                        } else {
                            isRecording = true
                            startRecording()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Toggle button
            Button(action: {
                muteStateManager.toggleMute()
            }) {
                Text("Toggle Mute")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()

            // Quit button
            Button("Quit MacMute") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .padding(.bottom, 8)
        }
        .padding()
        .frame(width: 280, height: 230)
    }

    private var currentShortcutDisplay: String {
        if isRecording {
            return "Press shortcut..."
        }
        let saved = UserDefaults.standard.string(forKey: "globalShortcut") ?? ""
        return saved.isEmpty ? "Not configured" : saved
    }

    private func startRecording() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isRecording else { return event }

            var parts: [String] = []
            if event.modifierFlags.contains(.command) { parts.append("⌘") }
            if event.modifierFlags.contains(.control) { parts.append("⌃") }
            if event.modifierFlags.contains(.option) { parts.append("⌥") }
            if event.modifierFlags.contains(.shift) { parts.append("⇧") }

            if let chars = event.charactersIgnoringModifiers?.uppercased(), !chars.isEmpty {
                parts.append(chars)
            }

            if parts.count >= 2 { // Need at least one modifier + key
                let shortcut = parts.joined()
                UserDefaults.standard.set(shortcut, forKey: "globalShortcut")

                // Store raw key code and modifiers
                UserDefaults.standard.set(Int(event.keyCode), forKey: "shortcutKeyCode")
                UserDefaults.standard.set(event.modifierFlags.rawValue, forKey: "shortcutModifiers")

                self.isRecording = false
                GlobalShortcutManager.shared.updateShortcut()
            }

            return nil // Consume the event
        }
    }
}
