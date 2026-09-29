import AppKit
import AthinaCore
import SwiftUI

/// The General pane: whether Athina offers suggestions at all, and talking
/// back.
///
/// How suggestions are shown, what they are about and the kinds turned off
/// with Never for This are in the Mentoring pane.
struct GeneralSettings: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    @Bindable var state = state
    Form {
      Section {
        Toggle(isOn: $state.settings.mentor.enabled) {
          Text("Offer suggestions")
          Text(
            "Athina points out a more helpful way to do what you are doing when it notices one."
          )
        }
      }

      VoiceSection()
    }
  }
}

// MARK: - Talk back

/// Talking back: the hotkey and what it needs on this Mac.
struct VoiceSection: View {
  @Environment(AppState.self)
  private var state

  @Environment(\.openWindow)
  private var openWindow

  var body: some View {
    @Bindable var state = state
    Section(
      content: {
        LabeledContent(
          content: {
            ShortcutRecorder(
              title: "Talk-back shortcut",
              identifier: "voice.talkBackShortcut",
              hotKey: $state.settings.mentor.pushToTalkHotKey,
              conflicts: [state.settings.pauseShortcut].compactMap { $0 },
              conflictNote: "This keyboard shortcut is already the pause shortcut."
            )
          },
          label: {
            Text("Talk-back shortcut")
            if state.isRunning,
              let key = state.settings.mentor.pushToTalkHotKey,
              !state.pushToTalkRegistered
            {
              StatusLabel(ShortcutProblem.sentence(for: key), kind: .warning)
            } else {
              Text("Hold it and speak, then let go to send.")
            }
          }
        )
        LabeledContent("On-device recognition") {
          switch state.speechAvailability {
          case .available(let locale):
            StatusLabel("Available for \(locale)", kind: .success)
          case .unavailable(let reason):
            StatusLabel(reason, kind: .warning)
              .multilineTextAlignment(.trailing)
          }
        }
        ForEach(Permission.optional) { permission in
          LabeledContent(permission.title) {
            PermissionBadge(granted: state.permissions.isGranted(permission))
          }
        }
        if !state.permissions.voiceGranted {
          HStack {
            Spacer()
            Button("Show Permissions…") { state.perform(.openPermissions) }
          }
        }
      },
      header: {
        Text("Talk back")
      },
      footer: {
        Text(
          """
          Hold the shortcut and say \"tell me more,\" \"not now,\" or \"never for this\" to \
          answer a suggestion, or ask a question about it and the answer appears in the \
          suggestion. Audio and transcripts stay on this Mac. Only your question, the \
          suggestion, and the text of the screen it was made from go to the mentor model.
          """
        )
      }
    )
  }
}
