# Design conventions

Every surface follows Apple's Human Interface Guidelines for macOS, audited
against the live guidelines on 2026-09-15, so later changes keep to them
rather than re-auditing. The sections Athina leans on are Designing for macOS,
The menu bar (menu bar extras), Menus, Windows, Panels, Settings, Layout,
Typography, Color, Dark Mode, Materials (Liquid Glass), Icons, SF Symbols,
Buttons, Toggles, Pickers, Text fields, Lists and tables, Alerts, Feedback,
Writing, Onboarding, Privacy, Accessibility, Keyboards, and Motion. The choices
particular to this app:

- **The menu bar extra is the app.** Athina has no Dock icon or app menu, so
  its menu leads with dimmed status rows (a status that needs something, such
  as a missing key, is the command that fixes it), then commands, windows, and
  the app menu's About and Quit. Menu items use title case and an ellipsis only
  where more input follows, and no standard keyboard shortcut is repurposed.
  The icon is the Gaze as a template image, one variant per mode, with a word
  beside it only in replay or recording.
- **The mark is the Gaze, and every asset comes from a vector.** Athina is
  named for Athena, whom Homer calls owl-eyed, so the mark is two eyes drawn as
  one line: on a 64-unit grid, two circles of radius 13 centred at (20, 32) and
  (44, 32), their union outlined with one 4.5 stroke. Two masters hold every
  shape: `Resources/Mark/AthinaMark.svg`, the app icon, and
  `Resources/Mark/AthinaGaze.svg`, the menu bar mark. `make icons`
  (`scripts/mark-assets.swift`) draws both with macOS's own SVG renderer into
  the app icon, the menu bar PDFs and the icon at the top of the
  [README](../README.md) (as macOS itself draws it, masked and shadowed); the
  script only picks each master's parts, sizes them and writes the files. The
  outputs are committed, so a plain `make build` needs nothing else, and
  `MarkAssetTests` fails when either master or the script changes without
  `make icons` being run, since `make icons` records all three in
  `Resources/Mark/built-from.txt`.
- **The app icon is the Gaze on its field, full bleed.** The field is glaukos,
  Athina's grey-green, lit from above; the Gaze is a pale facial disc with gold
  irises and near-black pupils looking down at the work, two parts in the
  master so the script can lift the Gaze off the field with one soft shadow.
  macOS 26 masks a legacy `.icns` to the standard app icon shape itself and
  adds the shadow, in Finder, in the Dock and in About, scaling the artwork
  into the 824 of 1024 body, so the icon draws no rounded rectangle and no
  shadow around itself and keeps the Gaze clear of the corners the mask rounds
  away. Each size is drawn from the vector, the Gaze a little larger at 16 and
  32 px, which is what the `.icns` format exists to allow.
- **The menu bar mark is the Gaze, at one width in every mode.** Its outline
  is bold enough to sit among the bar's other extras at 16 points, and it
  ships as a template PDF per mode, so macOS tints it like every other extra
  and one file serves every display scale. The states are the eyes alone, one
  group each in the master, named for `MenuBarMark`'s cases; the outline never
  changes, which keeps the item one width throughout, so the other extras
  never shift sideways when Athina's state changes. Watching looks down at the
  work; idle, the person stepped away, closes the eyes in a curve, asleep;
  paused, the deliberate stop, shuts them to a line, as does waiting for
  consent, since nothing is captured either way; an excluded app in front
  makes them look away; a missing permission or key leaves them open and
  empty, unable to see; held half-lids them. Which variant a mode gets is
  `MenuBarMark.resolve`, a pure function with the whole table under test.
- **Athina has one colour of its own, and it is the accent.** Glaukos, the
  grey-green of Homer's word for Athena's eyes, is the `AccentColor` in
  `Resources/Assets.xcassets` (`#11746B`, `#4BA297` in Dark Mode, darker and
  lighter again under Increase Contrast), which `Resources/Info.plist` names
  and `scripts/bundle.sh` compiles into the bundle. The HIG (Color) lets an app
  set an accent that controls use while the person keeps System Settings >
  Appearance at Multicolor, and any accent they pick instead still wins, so
  Athina never overrides that choice. Text, backgrounds and status stay the
  system's own colours.
- **The toast is a non-activating panel, not a notification.** It floats under
  the menu bar on Liquid Glass and never takes keyboard focus, with corners
  concentric with its small capsule buttons. Because it cannot be focused, the
  menu's Answer Suggestion submenu carries its answers, VoiceOver announces
  it, and it does not expire while VoiceOver or Switch Control is on. Its
  prominent button draws its own accent capsule, since a panel that is never
  key would draw a system prominent button in the inactive grey. A person may
  drag it aside, and it keeps that place, growing downward, until the next
  suggestion; it grows and shrinks in a short animation, at once with Reduce
  Motion. Its header leads with the note's kind, one of PRODUCT.md's three
  (`NoteKind`: a faster way, a risk, a dead end), as a System Settings style
  tile in the kind's own colour beside the kind's name in words, then the
  app; the model's own category is a hover away. While a callout is up, a
  line under the body says what it outlines, since the callout draws no words.
- **The callout is a click-through overlay** that draws its own frame, since
  nothing in the system frames a spot in another app's window: a halo, then a
  pointer stroke over a faint fill, in a colour of its own rather than the
  accent (`AthinaColor.pointer`), so it can never read as the other app's
  keyboard focus ring whatever accent the person picked. The note's kind tile
  sits on its top-left corner and the words stay in the note, so it covers
  nothing around the spot. It only fades in, and Increase Contrast thickens
  the stroke and makes the halo solid. VoiceOver never visits it, so it is
  announced as it appears.
- **Settings is the SwiftUI `Settings` scene**: a toolbar of panes, the window
  titled by its pane, the last pane remembered, each pane a fixed-size grouped
  form that scrolls. Rows use the form's own label and subtitle styling, and a
  place elsewhere in Settings is a link, not a description. A duration row given
  its setting's range offers only what that setting accepts: its unit pop-up
  lists the units the range holds a whole amount of. In every number row an
  amount typed outside the range settles at the nearest allowed one as the
  edit ends, rather than being clamped out of sight afterwards, and the row
  says what it was set to and what the range is; the money and time rows name
  their range in their help from the start. A row's Remove button takes a
  click across the HIG's 20 by 20 point minimum, whatever the size of its
  glyph.
- **The model provider is a pop-up button at the top of Settings > Models**,
  with the chosen provider's key rows below it in the same section: the HIG
  (Pop-up buttons) gives a pop-up button to a flat list of mutually exclusive
  options, the usual control for a choice in a settings form, and it matches the
  model pickers just below. Each item shows the provider's mark before its name
  (`ProviderMark`), a single-colour template image, so it takes the control's
  own text colour in both appearances and while highlighted, as the HIG
  (Images) asks of template images. The section's footer says whose account a
  call is billed to and that choosing a provider that sends to another company
  asks for consent again, which the consent window then does (HIG Privacy: ask
  in context, and say why).
- **Tools for looking inside Athina are opted into in the Advanced pane.** The
  debug panel is offered only once Settings > Advanced > Enable debug panel
  is on, the pane last in the toolbar as Safari's is, whose Advanced pane holds
  "Show features for web developers" for the same reason: the HIG (Settings)
  asks for defaults that give the best experience to the most people and for
  panes that each group related settings, and a window of model calls and
  captured text is neither for most people nor related to any other pane.
  Its button sits in the switch's own group and is dimmed while it is off.
  While it is on, the menu bar menu adds a Debug Panel command, as Safari's
  switch adds its Develop menu between its everyday menus and Window: in a
  group of its own after the everyday windows and Settings…, before About and
  Quit, since the HIG (Menus) asks for related items grouped between
  separators. It has no keyboard shortcut: the HIG (Keyboards) keeps custom
  shortcuts for commands people use often, and in this menu only Settings…
  and Quit, whose shortcuts are standard, and Pause Watching, a hot key the
  person chooses, have one.
- **Status is never color alone.** Inline messages are `StatusLabel` and badges
  are `StatusBadge` (`Sources/Athina/Components.swift`): the symbol or capsule
  carries the color, the words stay in the primary label color. A status color
  is a `StatusTint`, each meaning with one hue: good (green), attention
  (orange), neutral (grey: the person's own choices, such as an answer to a
  suggestion, and quiet states) and active (red: listening, recording). The
  call tiers' and replay's colors in the debug panel name a kind, not a status.
  Text uses system text styles and label colors, never fixed point sizes or
  tertiary text for anything that must be read, and secondary text only for
  hints: what a person must read to decide, such as the consent window's
  words or a permission's purpose, is primary.
- **Changes VoiceOver cannot see are announced.** A result that arrives after
  the control that asked for it (Test Connection, a failed key save), a
  warning that appears beside a field, a permission turning Granted, a
  removal and its Undo, and a number corrected into range all go through
  `Announce`; news nobody asked for queues behind what VoiceOver is saying,
  and only the answer to something the person just asked interrupts.
- **Errors are said in Athina's words.** A failed call or a held question
  says what it means and what to do (`UserFacing`), with the code's own text
  kept as the tooltip, in the call log and in the journal.
- **What cannot be undone asks first.** Clear Journal…, Reset
  Understanding… and the saved key's Remove… open a confirmation that names
  what is lost; the confirming button is plain, since it is what the person
  chose, and Cancel is always there. A common removal that can be put back,
  a context or an excluded app, acts at once instead, as the HIG asks, and a
  row under its list offers Undo for a while, as Edit > Undo does while
  Settings is in front.
- **Consent comes first and asks plainly.** The consent window is the first
  thing a launch shows until there is an Allow, as the HIG (Privacy) asks
  for data collection to be explained before it starts; it says who receives
  what in short rows, leads with its answer as the default button (Allow)
  beside Not Now as the cancel button, and shows the menu bar's Gaze itself as
  the sign that Athina is watching. Withdrawing is a button beside the
  answer in Settings > Privacy with no confirmation, since Allow undoes it.
- **Permissions explain before they ask.** The window never prompts on its own,
  each permission has one button, and the purpose strings in
  `Resources/Info.plist` say the same as the window in one sentence.
- **Words.** Buttons, menu items, window titles, and column headings use title
  case; labels, section headers, and status words use sentence case. The
  interface says keyboard shortcut rather than hotkey, names panes and places
  plainly, and speaks of Athina in the third person, never "we".
