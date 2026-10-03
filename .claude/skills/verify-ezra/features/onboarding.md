# Onboarding

## What it is (user's point of view)

First launch opens on "What should I call you?" (name field, Continue, Skip for now), then an intro that asks for everything on your mind (paste text or a screenshot), a privacy line about where those words are read, "Start empty" as the way past, then an editable result grouped by area.

## How a user reaches it

First launch after install.

## Driving it

```bash
xcrun simctl uninstall $U $B
xcrun simctl spawn $U defaults delete $B hasOnboarded 2>/dev/null   # the shared-prefs trap, see SKILL.md
$S install $U "$APP"
$S launch $U $B                          # the intro
$S launch $U $B -OnboardingIntro         # the paste screen
$S launch $U $B -OnboardingResult        # the result scene
```

## Proof it works

- The paste screen shows the `DataBoundary.captureShort` line under the editor; at accessibility sizes the column scrolls, the hero is below the status bar and "Start empty" is reachable.
- No capability string ("Apple Intelligence · on-device", "Rules engine…") on the settling screen in a customer-visible position.
- The result lists task titles under uppercase area kickers.

## Gotchas

- Any seed sets `hasOnboarded`; onboarding seams act only while onboarding is on screen, so never combine them with a seed.
- The photo picker is out of process; it cannot be driven here.
