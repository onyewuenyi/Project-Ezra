# Ezra — Help

> **To the owner, before publishing.** App Store Connect requires a support URL and
> reviewers do open it; a page that does not load is a finding. Fill in `<CONTACT EMAIL>`,
> publish, then set `SupportLinks.support` and the App Store Connect field to the same
> URL. Every answer below describes behaviour that is actually in the build — if one stops
> being true, this page changes with it.

**Ezra turns what you say into a household's tasks.** Say or paste what is on your mind
and it comes back as a short list you can act on.

## Getting in touch

`<CONTACT EMAIL>` — it reaches a person. Ezra is a research preview built by one
developer, so a reply may take a day or two. If you are reporting something that went
wrong, the most useful things to include are what you were doing, what you expected, and
what happened instead.

## Common questions

**Voice capture is not working.**
Ezra listens the moment the capture sheet opens, and it needs two things: permission to
use the microphone, and Apple's on-device speech model for your language. If you said no
to the microphone, the capture screen shows a link straight to the relevant Settings page.
If the language model is still downloading the first time you use it, you will see
"Getting the mic ready…" — that one download can be slow on a cellular connection, and you
can type instead at any time without losing what you have already said. If your language
is genuinely not supported yet, Ezra says so and typing still works.

**Ezra split one task into two, or ran two into one.**
Every reading is shown to you before anything is created, and it is yours to edit: change
the text and the tasks change with it, or remove a card you do not want. Nothing reaches
your list until you tap Create. Corrections you make are how it learns, and they stay on
your device.

**It did not understand a long brain dump.**
Long, unpunctuated dumps are the hardest case. Splitting a very long one into two captures
usually reads better than one enormous paragraph. If you have switched capture to **On
device** in the capture screen, everything is read locally, which is more private and
handles long dumps less well — that trade is yours to make and you can change it any time.

**Sharing with my partner is not working.**
Household sharing goes through your own iCloud account, so both phones need to be signed
in to iCloud with iCloud Drive on. Send the invitation from Tasks ▸ … ▸ Manage household,
and open the link on the other phone. If something is wrong, Ezra says which thing in
plain words rather than showing an error code.

**I cleared something by accident.**
Before any clear, Ezra saves a copy of your data on your device, and Settings offers to
share that copy right after. There is no in-app restore — it needs the app closed — so if
you need one, get in touch and keep the copy safe in the meantime.

**How do I get my data out, or delete it?**
Settings has both. *Export* gives you a readable file of everything Ezra holds. *Clear all
tasks* empties your work and keeps your profile. *Reset everything* returns the app to a
fresh install. Deleting the app removes everything on the device.

**What leaves my device?**
Settings ▸ *What leaves this device* answers this for your install specifically, in plain
words, and changes to match what is actually happening. The full version is the
[privacy policy](privacy-policy.md).

## Known limits of this preview

- It is built for the newest iOS, so it needs iOS 27 or later.
- Some readings are better on devices that can run Apple Intelligence; on the rest, Ezra
  falls back to a deterministic reading and still works.
- Household sharing is one household at a time.
- There is no web or Android version.
