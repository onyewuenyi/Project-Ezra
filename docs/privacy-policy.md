# Privacy Policy — Ezra

*Last updated: 20 September 2026*

> **To the owner, before publishing.** This is written from the code, not from a template:
> every claim below is one `PrivacyInfo.xcprivacy`, `Models/DataBoundary.swift`,
> `Models/Telemetry.swift` or `Models/PersistenceStack.swift` already makes, and the
> wording is deliberately the app's own. Two things are still yours to do. **Fill in the
> contact address** marked `<CONTACT EMAIL>` below — a policy with no way to reach anyone
> is not a policy. **Have it read by someone qualified** if the app ships outside a
> research preview; this is an accurate description of the software, which is not the same
> thing as legal advice. Publish it, then set `SupportLinks.privacyPolicy` to its URL and
> put the same URL in App Store Connect. If any of these facts stop being true, this file
> and the privacy manifest change in the same commit.

## The short version

Ezra keeps your household's tasks on your device and in your own iCloud. Your words are
read on your device first. Nothing you capture is sold, shared with advertisers, or used to build a profile of
you, and there is no advertising identifier anywhere in the app.

## Where your data lives

**On your device, and in your own iCloud.** Ezra stores everything on your device, and —
when you are signed in to iCloud — keeps a copy in *your own private iCloud account*, the
same way Notes or Reminders do, so your tasks are on all your devices. That copy is yours.
It sits under your Apple ID, it is governed by
[Apple's privacy policy](https://www.apple.com/legal/privacy/), and the developer of Ezra
has no access to it and operates no server that holds your data.

So when this page says something "never reaches us", it means exactly that: not that it
never left your phone, but that it never reached the developer, and never reached anyone
you shared with.

## What never reaches us, and never reaches anyone you invite

- **Your corrections.** Every time you edit something Ezra got wrong, it learns from it.
  That record stays in your own storage, is never sent to the developer, and is
  deliberately excluded from household sharing — nobody you invite can see it.
- **Audio.** Voice capture is transcribed on your device by Apple's on-device speech
  system. The recording is never uploaded, never stored, and never sent anywhere.
- **Photos.** When you add a screenshot, Ezra reads the text out of that one image on your
  device. It never gains access to your photo library, only to the single image you pick.
- **Your notes.** The free-text notes on a task are never sent to prepare advice.

## What can leave your device, and when

**Your household's tasks, to someone you invite.** Sharing is off until you send an
invitation. When you do, that household's tasks and its activity trail become visible to
the people you invited, through Apple's iCloud sharing. Your profile, your captures, your
corrections and Ezra's learned preferences are deliberately excluded and never travel to
them, however long you share.

**The words of a capture, sometimes.** Ezra reads everything you capture on your device
first. When that quick reading shows evidence it fell short — usually a long brain dump
that needs a deeper read — the text you wrote is sent to a cloud model to be read into
tasks, and the result comes back. This is the only place your raw words leave the device,
it is never the default, and you can switch it off for good: the capture screen has an
**On device** setting that keeps every capture local, whatever the length.

**Structured task information, to prepare advice.** When Ezra suggests what would make a
task easier, it sends the shape of the task — its title, dates and flags — and never your
raw notes or your capture.

**Nothing at all, on a build with no cloud configured.** The app states which of these is
true for your install, in plain words, in Settings under *What leaves this device*. That
screen changes to match what is actually happening.

## Anonymous product signals

Ezra is a research preview, and it records which features were used and whether they
worked, so it can be improved.

What is sent is deliberately narrow: each signal is one of a fixed list of events, and
every value attached to one is a category or a range — never a task title, never a
person's name, never a date, never a raw count or duration. That restriction is enforced
in the code and tested, not just intended.

Signals are keyed to a random identifier created the first time you use the app. It is not
your name, your email, your Apple ID, or your device's advertising identifier, and it is
destroyed and replaced if you reset the app.

Signals also carry a household code, so the phones in one household count as one group
rather than as strangers. The code is a one-way scramble of a random identifier inside your
household's data: it is not your household's name, it cannot be turned back into anything in
your household, and every phone in a shared household sends the same one. It is sent only
while these signals are on.

**You can turn this off** in Settings, under *What leaves this device*. The switch is
checked before anything is sent.

## What Ezra never does

- No tracking. No advertising identifier is read or stored, and nothing about you is
  combined with data from other companies for advertising or measurement.
- No selling or sharing of personal information.
- No accounts, no passwords, no email address required. Ezra never asks who you are.
- No profile of you is built or sold, and nothing here is used to make decisions about you.

## Your data, and getting rid of it

Because there is no account, everything is in your hands:

- **Take it with you.** Settings offers a readable export of everything Ezra holds.
- **Clear your work.** Settings ▸ *Clear all tasks* empties the tasks, captures and
  activity, and keeps who you are.
- **Erase everything.** Settings ▸ *Reset everything* returns the app to a fresh install —
  your tasks, your profile, your preferences and the anonymous identifier described above.
- **Safety copies.** Before either of those, Ezra saves a copy on your device so a clear
  you did not mean is recoverable. The last few are kept, on your device only, and they go
  when you delete the app.

Deleting the app removes everything stored on the device. The copy in your own iCloud is
managed by you, through iOS Settings ▸ your name ▸ iCloud, like any other app's iCloud
data.

## Children

Ezra is not directed at children and does not knowingly collect information from them. It
is a tool for running a household; a child's name may appear in a household roster because
an adult typed it, and that stays with the rest of the household's data.

## Changes

If what leaves your device changes, this page and the app's own *What leaves this device*
screen change together — they are written from the same source, on purpose. The date at
the top says when.

## Contact

Questions, or a request about your information: `<CONTACT EMAIL>`
