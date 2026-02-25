import SwiftUI

struct ShortcutConfigView: View {
    @ObservedObject var muteStateManager: MuteStateManager
    @State private var isRecordingMic = false
    @State private var isRecordingCamera = false

    var body: some View {
        VStack(spacing: 12) {
            // Mic status
            StatusRow(
                icon: muteStateManager.isMuted ? "mic.slash.fill" : "mic.fill",
                color: muteStateManager.isMuted ? .red : .green,
                label: muteStateManager.isMuted ? "Microphone Muted" : "Microphone Active"
            )

            // Camera status
            StatusRow(
                icon: muteStateManager.isCameraOff ? "video.slash.fill" : "video.fill",
                color: muteStateManager.isCameraOff ? .blue : .green,
                label: muteStateManager.isCameraOff ? "Camera Off" : "Camera Active"
            )

            Divider()

            // Mic shortcut
            ShortcutRow(
                label: "Mic Shortcut",
                isRecording: $isRecordingMic,
                defaultsKey: "globalShortcut",
                onRecord: { startRecordingMic() }
            )

            // Mic toggle button
            Button(action: { muteStateManager.toggleMute() }) {
                Text("Toggle Mic")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.regular)

            Divider()

            // Camera shortcut
            ShortcutRow(
                label: "Camera Shortcut",
                isRecording: $isRecordingCamera,
                defaultsKey: "cameraShortcut",
                onRecord: { startRecordingCamera() }
            )

            // Camera toggle button
            Button(action: { muteStateManager.toggleCamera() }) {
                Text("Toggle Camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.regular)

            Spacer()

            // Quit button
            Button("Quit MacMute") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .padding(.bottom, 4)
        }
        .padding()
        .frame(width: 280, height: 370)
    }

    private func startRecordingMic() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isRecordingMic else { return event }

            var parts: [String] = []
            if event.modifierFlags.contains(.command) { parts.append("⌘") }
            if event.modifierFlags.contains(.control) { parts.append("⌃") }
            if event.modifierFlags.contains(.option) { parts.append("⌥") }
            if event.modifierFlags.contains(.shift) { parts.append("⇧") }

            if let chars = event.charactersIgnoringModifiers?.uppercased(), !chars.isEmpty {
                parts.append(chars)
            }

            if parts.count >= 2 {
                let shortcut = parts.joined()
                UserDefaults.standard.set(shortcut, forKey: "globalShortcut")
                UserDefaults.standard.set(Int(event.keyCode), forKey: "shortcutKeyCode")
                UserDefaults.standard.set(event.modifierFlags.rawValue, forKey: "shortcutModifiers")
                self.isRecordingMic = false
                GlobalShortcutManager.shared.updateShortcut()
            }

            return nil
        }
    }

    private func startRecordingCamera() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isRecordingCamera else { return event }

            var parts: [String] = []
            if event.modifierFlags.contains(.command) { parts.append("⌘") }
            if event.modifierFlags.contains(.control) { parts.append("⌃") }
            if event.modifierFlags.contains(.option) { parts.append("⌥") }
            if event.modifierFlags.contains(.shift) { parts.append("⇧") }

            if let chars = event.charactersIgnoringModifiers?.uppercased(), !chars.isEmpty {
                parts.append(chars)
            }

            if parts.count >= 2 {
                let shortcut = parts.joined()
                UserDefaults.standard.set(shortcut, forKey: "cameraShortcut")
                UserDefaults.standard.set(Int(event.keyCode), forKey: "cameraShortcutKeyCode")
                UserDefaults.standard.set(event.modifierFlags.rawValue, forKey: "cameraShortcutModifiers")
                self.isRecordingCamera = false
                GlobalShortcutManager.shared.updateCameraShortcut()
            }

            return nil
        }
    }
}

// MARK: - Subviews

private struct StatusRow: View {
    let icon: String
    let color: Color
    let label: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
            Text(label)
                .font(.headline)
        }
        .padding(.top, 4)
    }
}

private struct ShortcutRow: View {
    let label: String
    @Binding var isRecording: Bool
    let defaultsKey: String
    let onRecord: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                Text(currentDisplay)
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
                        onRecord()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var currentDisplay: String {
        if isRecording { return "Press shortcut..." }
        let saved = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return saved.isEmpty ? "Not configured" : saved
    }
}
