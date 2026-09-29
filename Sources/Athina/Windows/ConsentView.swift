import AppKit
import AthinaCore
import SwiftUI

/// The consent window: the first thing a launch shows until the person allows
/// Athina to watch and send (`Consent`), ahead of the Permissions window.
///
/// It says who receives what, what stays on this Mac and for how long, and how
/// the menu bar shows that Athina is watching, then asks. Nothing is sensed
/// or sent before Allow; Not Now leaves Athina doing nothing, with Allow
/// Watching in its menu and Settings > Privacy as the way back.
///
/// It asks about the provider chosen in Settings > Models, naming the company
/// that receives what is sent and the terms it is handled under, so choosing
/// another provider opens it again (`SensingSettings.hasConsent`).
struct ConsentView: View {
  @Environment(AppState.self) private var state
  @Environment(\.dismiss) private var dismiss

  private var disclosure: ConsentDisclosure {
    ConsentDisclosure(for: state.settings.mentor.provider)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 14) {
        // As Finder draws it, masked to the app icon shape; the raw
        // application icon image is the unmasked full-bleed artwork.
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
          .resizable()
          .frame(width: 64, height: 64)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(disclosure.title)
            .font(.title2.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
          Text(disclosure.summary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          ConsentRow(
            symbol: "text.viewfinder",
            text:
              "The text on your screen, read on this Mac, and the names of the app and window in front. With Accessibility access, also the text of the field you are working in."
          )
          ConsentRow(
            symbol: "photo",
            text: "The latest screenshot, unless you turn that off in Models settings."
          )
          ConsentRow(
            symbol: "list.bullet.rectangle",
            text:
              "A summary of your recent activity, your answers to its suggestions, Athina's own notes on what you are working toward, and the contexts you declare."
          )
          ConsentRow(
            symbol: "bubble.left",
            text:
              "Questions you ask about a suggestion. Spoken ones are turned into text on this Mac; the audio is never sent or kept."
          )
          Text(disclosure.destination)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Text(disclosure.sentHeading)
          .accessibilityAddTraits(.isHeader)
      }

      GroupBox {
        ConsentRow(symbol: "book.closed", text: retentionText)
          .padding(6)
          .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Text("What stays on this Mac")
          .accessibilityAddTraits(.isHeader)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          ConsentMarkRow(
            mark: .watching,
            text: "While Athina watches, the eyes in the menu bar are open."
          )
          ConsentMarkRow(
            mark: .paused,
            text: pausedText
          )
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Text("How to tell Athina is watching")
          .accessibilityAddTraits(.isHeader)
      }

      Text(
        "You can withdraw this at any time in Privacy settings, and Athina stops capturing and sending at once."
      )
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Link("Privacy Policy", destination: Consent.privacyPolicyURL)
        Spacer()
        Button("Not Now") {
          state.declineConsent()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("consent.notNow")
        Button("Allow") {
          state.allowConsent()
          dismiss()
          // Permissions are asked about only once consent is given.
          if !state.permissions.allGranted { state.perform(.openPermissions) }
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("consent.allow")
      }
    }
    .padding(20)
    .frame(width: 600)
    .task {
      guard !Snapshots.isActive else { return }
      AppState.log.notice(
        "consent window opened, consent \(state.settings.hasConsent ? "given" : "not given", privacy: .public)"
      )
      // An accessory app's window opened at launch does not come forward
      // on its own, and this one must be the first thing seen.
      AppActivation.request()
    }
  }

  /// What the shut eyes mean, and how to pause, with the pause shortcut
  /// when the person has one.
  private var pausedText: String {
    let pause =
      state.settings.pauseShortcut.map { "from its menu or with \($0.displayString)" }
      ?? "from its menu"
    return
      "While it is paused or not allowed to watch, its eyes are shut. Pause it at any time \(pause)."
  }

  /// What the journal keeps, from the settings in force, so the window
  /// never promises a retention the person has changed.
  private var retentionText: String {
    let settings = state.settings
    return
      "A journal of what Athina sees: screenshots for \(Formatting.spelledDuration(settings.thumbnailRetention)), text and events for \(Formatting.spelledDuration(settings.textRetention)), up to \(Formatting.bytes(settings.journalSizeCapBytes)) in all. Change this or clear the journal at any time in Journal settings."
  }
}

/// One line of the disclosure: a symbol and what it stands for.
private struct ConsentRow: View {
  let symbol: String
  let text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 20)
        .accessibilityHidden(true)
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A variant of the menu bar mark as it looks in the menu bar, and what it means.
private struct ConsentMarkRow: View {
  let mark: MenuBarMark
  let text: String

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      MenuBarLabelImage(mark: mark)
        .frame(width: 20)
        .accessibilityHidden(true)
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
