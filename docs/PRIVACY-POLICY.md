# Skyr Music privacy policy — publication draft

This draft is not yet published. A public support contact and hosting URL must be supplied before public App Store submission. The in-app Privacy Details page already explains the data flows without linking to a placeholder website.

## Your music and NAS

Skyr Music connects to the NAS you select to read your music files, tags and cover images. Music streams directly from that NAS or plays from downloads on your device. Skyr does not operate a music-storage service and does not upload your music files to a Skyr server.

Your NAS receives the credentials, folder requests and media requests needed for these features. Its administrator controls its permissions, logging and retention. Your personal NAS password is saved in the device Keychain. NAS addresses, account names, selected folders and library metadata are saved locally so Skyr can reconnect and display the library.

## Album artwork

Skyr uses cover images from your NAS folders and pictures embedded in your music files. It does not send artist or album names to an online artwork search service. If your files have no cover, Skyr shows a generated design.

## iCloud and family sharing

When iCloud is available, Skyr uses Apple's CloudKit service to synchronize profile names, selected profile photos, favourites, playlists, recent plays, recent searches, settings and change-reconciliation information. Profile records also include the profile's Apple account association, role, dates, and PIN verification values when a PIN is set. This is data in the app's private or family-shared CloudKit zone, not a Skyr-operated database.

Anyone with a family invitation link can join that family and receive its shared profiles and server details. Shared server details include the server address and name, account name and music folder. Skyr shares the NAS credentials selected in Family Access, with the password in an encrypted CloudKit field so members can connect. Skyr does not automatically share the owner's personal NAS password, but an account explicitly selected for Family Access is shared. Use a separate read-only NAS account for this purpose. Profile PINs and biometric unlock control the app interface; they do not change the sharing permissions of the CloudKit zone or the NAS.

## Local copies and connected devices

Skyr keeps its catalogue, covers, preferences and downloaded music on your devices. Removing a download removes the device's copy, not the original NAS file. Apple TV can purge cache storage. Device backups and NAS backups may retain copies according to your settings and the provider's behavior.

The paired Watch can receive playlist metadata, colours for playlist mosaics, and the current NAS address, account and password from the iPhone, then download music from the NAS. The password is saved in the Watch Keychain. Skyr does not send cover image files to the Watch. Widgets and Apple playback surfaces, including Now Playing, AirPlay and CarPlay, receive the metadata or audio needed for the features you use. Face ID and Touch ID are handled by the operating system; Skyr receives the authentication result, not biometric templates.

## Diagnostics, distribution and support

Skyr contains no advertising SDK, third-party analytics SDK or automatic upload of its local diagnostic log. The log can contain profile names, server details and errors; Skyr does not automatically send it to the developer, but it may be included in device backups or shared if you copy it. You can clear it from Diagnostics.

Apple provides App Store and TestFlight distribution under its own terms and your Apple settings. Feedback and crash reports you share through TestFlight may be available to the developer. If you contact support, the information you choose to send will be used to respond to that request. The public support contact and support-retention details will be added before this policy is published.

## Your choices

You can remove downloads, edit or delete eligible profiles, and clear diagnostics in Skyr. iCloud changes and deletions need connectivity to reach other devices. Family access can be managed in Skyr and on the NAS; removing a participant does not recall copies already downloaded on that person's devices. You can also manage Apple service and backup settings through Apple. Skyr cannot delete the original library, independent NAS logs or backups maintained outside the app through these controls.

## Publication checklist

- Add the public support contact and confirm how voluntarily submitted support material is retained.
- Publish the final policy at a stable public HTTPS URL, then set that URL and Apple TV policy text in App Store Connect.
- Complete the app-level privacy answers consistently with the release's behavior and Apple's definitions; document the reasoning in `PRIVACY-RELEASE-CHECK.md`.
