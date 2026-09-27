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
  The icon is the owl as a template image, one variant per mode, with a word
  beside it only in replay or recording.
- **The mark is the artist's drawing, and every asset comes from a vector.**
  `Resources/Mark/AthinaMark.svg` is the master for the app icon: a profile in a crested
  Corinthian helmet over a flat cream circle, square and hexagon, in the
  reference bitmap's own coordinates, with the line art and the cream shapes in
  separate groups so either stands alone. Ink is `#332C2B` and cream `#F1DEB7`,
  both sampled from the drawing rather than chosen. `make icons`
  (`scripts/mark-assets.swift`) builds the app icon from it, the icon at the
  top of the [README](../README.md) from that icon (as macOS itself draws it, masked and
  shadowed), and the menu bar mark from the second master, the owl below;
  their outputs are committed, so a plain `make build` needs nothing else, and
  `MarkAssetTests` fails when either master or the script changes without
  `make icons` being run, since `make icons` records all three in
  `Resources/Mark/built-from.txt`. The script is in that record because most of the drawing lives there rather than in the
  masters: the menu bar inset, the eye treatments, the z's and the per-size
  thickening are all constants in it.
- **The app icon is the full artwork, full bleed.** macOS 26 masks a legacy
  `.icns` to the standard app icon shape itself and adds the shadow, in Finder,
  in the Dock and in About, scaling the artwork into the 824 of 1024 body, so
  the icon draws no rounded rectangle and no shadow of its own and keeps the
  drawing clear of the corners the mask rounds away. Each size is drawn from
  the vector and weighted for itself, which is what the `.icns` format exists
  to allow: the drawing's stroke is under a pixel by 32 px and would otherwise
  grey out.
- **The menu bar mark is the owl, at one width in every mode.**
  `Resources/Mark/AthinaOwl.svg` is a second master, for the menu bar only: a
  solid owl silhouette, so it sits among the bar's other extras instead of
  reading lighter than all of them the way a line drawing does at 16 points.
  It ships as a template PDF per mode, so macOS tints it like every other extra
  and one file serves every display scale. The states are made out of the
  drawing rather than hung off it: the owl's eyes are the boldest thing in it
  at this size and they are what watching means, so they carry the modes and
  the silhouette never changes. Idle, the state that says the user has stepped
  away, also gets two z's drifting off it, drawn in the clear upper left of the
  owl's own bounding box: with the pupils gone the eyes are the whitest thing
  in the set and read wide awake rather than shut, so the z's are what actually
  say asleep. Paused, the deliberate stop, takes the half-lidded eyes. Every
  state, the z's included, is made inside the owl's own box, which is what
  keeps the item one width throughout, so the other extras never shift
  sideways when Athina's state changes. Which variant a mode gets is
  `MenuBarMark.resolve`, a pure function with the whole table under test.
- **The toast is a non-activating panel, not a notification.** It floats under
  the menu bar on Liquid Glass and never takes keyboard focus, with corners
  concentric with its small capsule buttons. Because it cannot be focused, the
  menu's Answer Suggestion submenu carries its answers, VoiceOver announces
  it, and it does not expire while VoiceOver or Switch Control is on.
- **The callout is a click-through overlay** that draws its own accent stroke,
  since nothing in the system frames a spot in another app's window; its note
  sits on the toast's glass. It only fades in, and Increase Contrast thickens
  the stroke and drops the glow.
- **Settings is the SwiftUI `Settings` scene**: a toolbar of panes, the window
  titled by its pane, the last pane remembered, each pane a fixed-size grouped
  form that scrolls. Rows use the form's own label and subtitle styling, and a
  place elsewhere in Settings is a link, not a description. A duration row given
  its setting's range offers only what that setting accepts: its unit pop-up
  lists the units the range holds a whole amount of, and an amount typed outside
  the range settles at the nearest allowed one as the edit ends, rather than
  being clamped out of sight afterwards.
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
  carries the color, the words stay in a label color. Text uses system text
  styles and label colors, never fixed point sizes or tertiary text for
  anything that must be read.
- **What cannot be undone asks first.** Clear Journal… and Reset
  Understanding… open a confirmation that names what is lost; the confirming
  button is plain, since it is what the person chose, and Cancel is always
  there.
- **Permissions explain before they ask.** The window never prompts on its own,
  each permission has one button, and the purpose strings in
  `Resources/Info.plist` say the same as the window in one sentence.
- **Words.** Buttons, menu items, window titles, and column headings use title
  case; labels, section headers, and status words use sentence case. The
  interface says keyboard shortcut rather than hotkey, names panes and places
  plainly, and speaks of Athina in the third person, never "we".
