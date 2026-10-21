# DocHelper privacy policy (draft)

> **Draft for the owner to review.** Nothing here is published. Fill in
> the bracketed details, check each statement against the release build,
> and publish it at a public URL. Then enter that URL in the Play Console
> and on the store listing. Last checked against the code on the date
> below.

**Effective date:** [date of publication]
**App:** DocHelper (package `com.yourmateapps.pdfhelper`)
**Developer:** Your Mate Apps, [contact email], [postal address if
required]

## Summary

DocHelper opens, edits and creates documents **on your phone**. Your
documents never leave the device unless you choose to share them.
The app uses two Google services: Firebase Crashlytics for crash reports
and Google AdMob for ads. Both receive limited technical data, described
below.

## Your documents

- PDFs, Word, Excel, PowerPoint, OpenDocument, text files, pictures and
  archives are read and written by engines built into the app. They are
  not uploaded to any server.
- Text recognition (OCR) runs on the device.
- When you edit a file, the app keeps two kinds of private copy so that
  your work is never lost:
  - **recovery drafts** of unsaved changes, deleted when you save or
    discard them;
  - **backups** made just before a file is replaced.

  Both stay in the app's own storage and are removed when the app is
  uninstalled.
- When you share or export a file, it goes only where you send it, and
  only after you choose to send it (another app, email, a public folder
  such as `Download/DocHelper`).

## Permissions

| Permission | Why |
| --- | --- |
| All files access (`MANAGE_EXTERNAL_STORAGE`) | To list your documents in the Files tab and save edits back to the file you opened. The app does not read files you do not open or list. |
| Storage (Android 9 and older) | The same, on older Android versions. |
| Camera | To scan pages into a PDF, and only when you use the scanner. |
| Notifications | To tell you when a long task, such as a large export, has finished. |

## Crash reports (Firebase Crashlytics)

When the app crashes, or meets an error it recovers from, a report is sent
to Firebase Crashlytics, a Google service. A report holds:

- the error and where in the app's code it happened, including crashes in
  the app's native engines;
- device model, Android version, app version, free memory and storage;
- a random installation identifier.

On Android 11 and later, the app also reports how often Android stopped
it to reclaim memory, with the memory it was using at the time.

Reports **do not** contain your documents, their names or their
contents. Debug builds send nothing. See Google's policy:
https://firebase.google.com/support/privacy

## Ads (Google AdMob)

The app shows ads served by Google AdMob. AdMob may collect your device's
advertising ID, IP address and information about how you interact with
ads. It may use these to show personalised ads where the law allows it.
Where the law requires consent, the app asks with Google's consent form,
and you can change your choice later in the app's Settings. You can reset
or delete
your advertising ID in Android's settings (Settings > Google > Ads, or
Settings > Privacy > Ads). See how Google uses data from apps that use
its services: https://policies.google.com/technologies/partner-sites

## Data we do not collect

The app does not ask for or collect:

- your name, email, phone number or contacts;
- your location;
- your documents or their contents.

The app has no account and no sign-in.

## Children

DocHelper is not directed at children under 13 [or the age that applies
in your country], and does not knowingly collect their data.

## Data retention and deletion

- Data on your phone (drafts, backups, recent files, settings) is removed
  when you uninstall the app, or clear its storage in Android's settings.
- Crash reports are kept by Firebase for 90 days.
- To ask about or delete data linked to your installation, write to
  [contact email].

## Changes

If this policy changes, the new version will be posted at this address,
with a new effective date.

## Contact

[contact email]

---

### Notes for the owner (delete before publishing)

- **Play Console Data safety form**, to match the above:
  - *Crash logs* and *Diagnostics*: collected, not shared, not optional,
    for app functionality and analytics.
  - *Device or other IDs*: collected by AdMob for advertising.
  - Nothing else is collected.
  - Data is encrypted in transit.
  - Users can ask for deletion.
- **All files access declaration**: the use case is "document management".
  The app edits documents in place and lists every document on the device
  (see `docs/PHASE10_PLAN.md`, owner decisions).
- **AI features** (`Features.ai`) are off. If they are turned on and send
  text to a server, this policy must say so first.
- **AdMob consent**: the app already asks through Google's consent form
  (UMP) where required, and offers privacy options again later
  (`lib/services/ads_service.dart`). The consent message itself is set up
  in the AdMob console, under Privacy & messaging.
