import SwiftUI

struct ShortcutConfigView: View {
    @ObservedObject var muteStateManager: MuteStateManager
    @State private var isRecordingMic = false
    @State private var isRecordingCamera = false
    @State private var showColorSettings = false
    @State private var micConflictMessage: String?
    @State private var cameraConflictMessage: String?
    @State private var micRecordingMonitor: Any?
    @State private var cameraRecordingMonitor: Any?

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
                keyCodeKey: "shortcutKeyCode",
                modifiersKey: "shortcutModifiers",
                conflictMessage: micConflictMessage,
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
                keyCodeKey: "cameraShortcutKeyCode",
                modifiersKey: "cameraShortcutModifiers",
                conflictMessage: cameraConflictMessage,
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
        .onChange(of: isRecordingMic) { isRecording in
            if !isRecording { removeMonitor(&micRecordingMonitor) }
            updateGlobalShortcutSuspension()
        }
        .onChange(of: isRecordingCamera) { isRecording in
            if !isRecording { removeMonitor(&cameraRecordingMonitor) }
            updateGlobalShortcutSuspension()
        }
        .onDisappear {
            isRecordingMic = false
            isRecordingCamera = false
            removeMonitor(&micRecordingMonitor)
            removeMonitor(&cameraRecordingMonitor)
            GlobalShortcutManager.shared.setShortcutsSuspended(false)
        }
    }

    // The global event tap sees key events before this view's local monitor, so it must let
    // them through while a shortcut is being recorded.
    private func updateGlobalShortcutSuspension() {
        GlobalShortcutManager.shared.setShortcutsSuspended(isRecordingMic || isRecordingCamera)
    }

    private func removeMonitor(_ monitor: inout Any?) {
        if let existing = monitor {
            NSEvent.removeMonitor(existing)
        }
        monitor = nil
    }

    private func conflictMessage(for shortcut: String, event: NSEvent, recording target: ToggleTarget) -> String? {
        let candidate = Shortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
        guard let other = GlobalShortcutManager.shared.conflict(for: candidate, recording: target) else { return nil }
        let otherName = other == .mic ? "mic" : "camera"
        return "\(shortcut) is already used for the \(otherName) shortcut."
    }

    private func startRecordingMic() {
        micConflictMessage = nil
        removeMonitor(&micRecordingMonitor)
        micRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
                if let message = self.conflictMessage(for: shortcut, event: event, recording: .mic) {
                    self.micConflictMessage = message
                    self.isRecordingMic = false
                    return nil
                }
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
        cameraConflictMessage = nil
        removeMonitor(&cameraRecordingMonitor)
        cameraRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
                if let message = self.conflictMessage(for: shortcut, event: event, recording: .camera) {
                    self.cameraConflictMessage = message
                    self.isRecordingCamera = false
                    return nil
                }
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
    let keyCodeKey: String
    let modifiersKey: String
    let conflictMessage: String?
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

            if let conflictMessage, !isRecording {
                Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsShiftOnlyWarning {
                Label(
                    "With Shift as the only modifier, \(currentDisplay) can't be typed in any app while this shortcut is set.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var showsShiftOnlyWarning: Bool {
        guard !isRecording else { return false }
        return storedShortcut?.usesShiftAsOnlyModifier ?? false
    }

    private var storedShortcut: Shortcut? {
        ShortcutStore.read(keyCodeKey: keyCodeKey, modifiersKey: modifiersKey, from: .standard).shortcut
    }

    private var currentDisplay: String {
        if isRecording { return "Press shortcut..." }
        let saved = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return saved.isEmpty || storedShortcut == nil ? "Not configured" : saved
    }
}
