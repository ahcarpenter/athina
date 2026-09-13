import AppKit
import MentorCore
import SwiftUI

struct PermissionsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mentor needs two permissions")
                        .font(.title2.weight(.semibold))
                    Text("Mentor watches what you are doing so it can understand your work. Everything it senses stays on this Mac in a local journal you control. This version makes no network requests at all.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 12) {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, granted: state.permissions.isGranted(permission))
                }
            }

            Text("Idle detection uses a system counter and needs no permission. If a grant does not show up after a few seconds, quit and relaunch Mentor.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(state.permissions.allGranted ? "Done" : "Continue Anyway") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            // Grants made in System Settings do not notify apps; poll while visible.
            while !Task.isCancelled {
                state.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshPermissions()
        }
    }
}

private struct PermissionRow: View {
    @Environment(AppState.self) private var state
    let permission: Permission
    let granted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .frame(width: 32, height: 32)
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(permission.title)
                        .font(.headline)
                    StatusPill(granted: granted)
                }
                Text(permission.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Grant…") {
                        state.requestPermission(permission)
                    }
                    .disabled(granted)
                    Button("Open System Settings") {
                        PermissionProbe.openSystemSettings(for: permission)
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        switch permission {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        }
    }
}

struct StatusPill: View {
    let granted: Bool

    var body: some View {
        Text(granted ? "Granted" : "Not granted")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(granted ? Color.green.opacity(0.18) : Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(granted ? Color.green : Color.orange)
    }
}
