import AppKit
import AthinaCore
import SwiftUI

/// The first-run and permissions window.
///
/// It explains each permission before anything is asked: no system prompt
/// appears until the person chooses a permission's button, which then asks or
/// opens its System Settings pane.
struct PermissionsView: View {
  @Environment(AppState.self)
  private var state

  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: "eye.circle.fill")
          .font(.largeTitle)
          .imageScale(.large)
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Athina needs two permissions")
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Text(
            """
            Athina watches what you are doing so it can understand your work. What it senses \
            stays on this Mac, in a journal you control. It connects only to \
            api.anthropic.com, and only after you save an API key.
            """
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      GroupBox(
        content: {
          PermissionRows(permissions: Permission.required)
        },
        label: {
          Text("Required to watch")
            .accessibilityAddTraits(.isHeader)
        }
      )

      GroupBox(
        content: {
          PermissionRows(permissions: Permission.optional)
        },
        label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("Optional, for talking back")
              .accessibilityAddTraits(.isHeader)
            Text(
              """
              Hold the talk-back shortcut, set in General settings, to answer or ask about a \
              suggestion by voice. Everything else works without these.
              """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      )

      Text(
        """
        Idle detection needs no permission. If a permission you turned on in System Settings \
        still shows as not granted after a few seconds, quit and reopen Athina.
        """
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button(state.permissions.allGranted ? "Done" : "Not Now") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 580)
    .task {
      guard !Snapshots.isActive else { return }
      AppState.log.notice(
        """
        permissions window opened, granted: screen \(state.permissions.screenRecording) \
        accessibility \(state.permissions.accessibility) microphone \
        \(state.permissions.microphone) speech \(state.permissions.speechRecognition)
        """
      )
      // Grants made in System Settings do not notify apps; poll while visible.
      while !Task.isCancelled {
        state.refreshPermissions()
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      state.refreshPermissions()
    }
  }
}

/// Permissions listed one per row, with a separator between rows.
private struct PermissionRows: View {
  @Environment(AppState.self)
  private var state

  let permissions: [Permission]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(permissions) { permission in
        PermissionRow(permission: permission, granted: state.permissions.isGranted(permission))
        if permission != permissions.last {
          Divider()
        }
      }
    }
  }
}

private struct PermissionRow: View {
  @Environment(AppState.self)
  private var state

  let permission: Permission
  let granted: Bool

  private var action: PermissionAction {
    state.permissionAction(for: permission)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        .frame(width: 32)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(permission.title)
            .font(.headline)
          PermissionBadge(granted: granted)
        }
        Text(permission.purpose)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      switch action {
      case .none:
        EmptyView()
      case .request:
        Button("Request Access…") { state.perform(action, for: permission) }
          .accessibilityHint("Shows the system's request for \(permission.title).")
      case .openSystemSettings:
        Button("Open System Settings…") { state.perform(action, for: permission) }
          .accessibilityHint("Opens the \(permission.title) list in Privacy & Security settings.")
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 4)
    .accessibilityElement(children: .contain)
  }

  private var symbol: String {
    switch permission {
    case .screenRecording: "rectangle.dashed.badge.record"
    case .accessibility: "accessibility"
    case .microphone: "mic"
    case .speechRecognition: "waveform"
    }
  }
}

/// Granted or not, as a badge.
struct PermissionBadge: View {
  let granted: Bool

  var body: some View {
    StatusBadge(text: granted ? "Granted" : "Not granted", tint: granted ? .green : .orange)
  }
}
