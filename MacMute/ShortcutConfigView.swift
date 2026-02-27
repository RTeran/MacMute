import SwiftUI

struct ShortcutConfigView: View {
    @ObservedObject var muteStateManager: MuteStateManager
    @State private var isRecordingMic = false
    @State private var isRecordingCamera = false
    @State private var showColorSettings = false

    var body: some View {
        VStack(spacing: 12) {
            // Mic status
            StatusRow(
                icon: muteStateManager.isMuted ? "mic.slash.fill" : "mic.fill",
                color: muteStateManager.isMuted ? muteStateManager.micMutedColor : .green,
                label: muteStateManager.isMuted ? "Microphone Muted" : "Microphone Active"
            )

            // Camera status
            StatusRow(
                icon: muteStateManager.isCameraOff ? "video.slash.fill" : "video.fill",
                color: muteStateManager.isCameraOff ? muteStateManager.cameraOffColor : .green,
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
            .tint(muteStateManager.micMutedColor)
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
            .tint(muteStateManager.cameraOffColor)
            .controlSize(.regular)

            Divider()

            DisclosureGroup("Color Settings", isExpanded: $showColorSettings) {
                ColorPickerRow(
                    label: "Mic muted color",
                    selectedColor: $muteStateManager.micMutedColor
                )
                ColorPickerRow(
                    label: "Camera off color",
                    selectedColor: $muteStateManager.cameraOffColor
                )
                .padding(.top, 4)
            }

            Divider()

            // Quit button
            Button("Quit MacMute") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
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

private struct ColorPickerRow: View {
    let label: String
    @Binding var selectedColor: Color

    private let presets: [Color] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { preset in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(preset)
                        .frame(width: 20, height: 18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.8), lineWidth: 2)
                                .opacity(selectedColor == preset ? 1 : 0)
                        )
                        .onTapGesture { selectedColor = preset }
                }
                ColorPicker("", selection: $selectedColor)
                    .labelsHidden()
                    .frame(width: 24, height: 24)
                    .padding(.leading, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
