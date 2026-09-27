# Coming from Mentor

The app was called Mentor, with the bundle identifier
`com.ahcarpenter.mentor`. It is Athina now, `com.ahcarpenter.athina`, and
macOS keys both Screen Recording and Accessibility to that identifier, so the
grants made to Mentor do not carry over. The first launch of Athina therefore
senses nothing until they are granted again, once, by hand:

1. Open System Settings > Privacy & Security > Screen Recording, turn Athina
   on, and do the same under Accessibility. Athina's own first-run window has
   a button for each, and shows live status as they are granted.
2. Quit and reopen Athina, so it picks up both grants. Mentor can be removed
   from both lists at the same time; it is no longer built.

Nothing of yours is left behind or overwritten. On its first launch Athina
moves what Mentor kept, `~/Library/Application Support/mentor` (the journal
with its understanding, `settings.json`, and any recorded calls), to
`~/Library/Application Support/athina`. Quit Mentor first: Athina takes
SQLite's exclusive lock on the old journal for the whole move, and has SQLite
itself copy it rather than copying a live write-ahead-log database file by
file. The copy is assembled beside the new folder and checked there, the
journal by SQLite's integrity check and a row count of every table against the
original, every other file by SHA-256 digest, and only then put in place, with
the marker `migrated-from-mentor.json` written last. The move runs before the
app comes up, so on a large journal that first launch can sit quietly for a
while with nothing in the menu bar yet. The old folder is left exactly as it
was, yours to keep or remove. Per-launch replay directories are
not moved, since every replay makes its own, and a replay that ran under the
new name first does not stand in the way: its `replay` folder is the app's own,
not your data.

A move that cannot be finished stops that launch rather than starting an empty
journal in place of yours. Athina says what failed, in an alert, on stderr and
in the log, and quits:

- The old journal is still open in Mentor or another copy of the app, so the
  lock cannot be had. Quit it and open Athina again.
- A copy or a check failed (a full disk, a file that cannot be read).

Either way what Mentor kept is untouched, the attempt takes back whatever it
put in the new folder and nothing else, and the next launch simply tries
again. A move cut short by a crash is started again the same way. If the
same alert comes back launch after launch, the cause is not going away on its
own: move `~/Library/Application Support/mentor` somewhere else, and Athina
starts with an empty journal, leaving that copy intact where you put it.

If both folders already hold real data, the move is refused rather than
merged: Athina uses `athina`, leaves `mentor` untouched, and says so, naming
what it found, in Settings > Journal, in the debug panel, and in the log. Keep
the one you want and move the other away.

The Settings pane you had open and the window positions move with the
preferences domain on that same first live launch, laid over anything a replay
wrote there beforehand; after it, what Athina has written is never
overwritten.

The Anthropic API key moves the same careful way. On the first launch Athina
copies the keychain item saved under `com.ahcarpenter.mentor` to
`com.ahcarpenter.athina`, reads it back from there, and leaves the old item
exactly where it is; an item already under the new name is never overwritten,
and a key you delete in Settings is never copied back. So expect a third thing
on that first launch, after the two grants: the system's keychain prompt,
"Athina wants to use your confidential information stored in
com.ahcarpenter.mentor", since the login keychain trusts an item's readers by
the exact binary (see [Code signing](releasing.md#code-signing)). Always Allow copies the key across; Deny
leaves it where it is, and you can paste the key into Settings > Models
instead. The copy runs off the main thread, so the app keeps sensing while the
prompt waits.
