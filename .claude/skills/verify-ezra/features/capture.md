# Capture (Ramble)

## What it is (user's point of view)

Tap the orb, say (or type) everything on your mind; a breathing orb shows Ezra listening, then understanding; the reveal lists the tasks it heard as editable cards; Create commits them and the sheet closes onto the home, where the new tasks fold into the answer (or appear under "Just added").

## How a user reaches it

The orb in the home's ask bar (or bottom-trailing over the Tasks sheet).

## Driving it

```bash
$S launch $U $B -SeedFlowFixtures -OpenCapture                    # bare: the listening orb, or the typed canvas (no transcriber on the sim)
$S launch $U $B -SeedFlowFixtures -OpenCapture -HoldListening      # listening beat held, no mic
$S record $U $EV/orb.mov 10 & $S launch $U $B -SeedFlowFixtures -OpenCapture -HoldListening -DriveListeningLevel
$S launch $U $B -SeedFlowFixtures -OpenCapture "renew my passport, book flights after it comes through, call mom back"   # submits -> reveal
$S launch $U $B -SeedFlowFixtures -OpenCapture "call the dentist thursday" -NoSubmit      # canvas holding the text
$S launch $U $B -SeedFlowFixtures -OpenCapture "call the dentist thursday" -AutoCreate    # reveal -> Create -> lands on home
$S launch $U $B -SeedFlowFixtures -OpenCapture "buy paint, sand the fence, paint the fence" -GroupAs "Fix the fence"
```

## Proof it works

- Reveal (wait up to 30 s — the real model may be reading): one card per outcome; "Book flights for the trip…" shows a wait on "Renew my passport" (a real edge, not a chip reading "it comes through"); a day lifted into a chip leaves the title's edge ("Call the dentist" under a Thu chip). Never an intermediate interpretation shown and then replaced.
- `-AutoCreate`: the sheet dismisses; the home shows the new task in its rows or under "Just added". Side effect: Activity has the capture row; the byline reads "Read on your device" / "Read in the cloud", never a model id.
- Accessibility sizes: the reveal's echo stays ~2–3 lines with a fade, the drafts are on the first screen, the add-more row is glyph-only.

## Gotchas

- The simulator has no `SpeechTranscriber`, so a bare `-OpenCapture` shows the typed canvas: that proves the degrade path, not the mic. The listening orb is only reachable with `-HoldListening`.
- Grant the mic on a fresh install (`$S privacy $U grant microphone $B`) or the permission alert covers the sheet.
- Which engine read the text depends on the host's Apple Intelligence and on `GoogleService-Info.plist`; read the DEBUG footer before calling a reveal right or wrong. Segmentation claims belong to `-RambleEval`, not a screenshot.
