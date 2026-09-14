# Skyr Music

## What Skyr is

Skyr is a music app for people who own their music. It plays a personal library straight from a Synology NAS on iPhone, iPad, Mac and Apple TV, with the design quality people expect from an Apple app. There is no cloud in between. The music stays on the drive the customer already owns, and Skyr brings it to every screen in the house and anywhere else the customer goes.

Millions of households run a Synology NAS at home, and many of them keep years of ripped CDs, purchased downloads and high-resolution files on it. Until now those collections have been served by dated first-party apps, by media servers that must be installed and maintained on the NAS, or by cloud lockers that upload everything to a third party. Skyr removes that choice. It connects to the NAS as it is, indexes the music folder, and turns it into a library that feels native on every device.

## How it works and why it is different

Skyr talks to the NAS through Synology's own DiskStation Manager interface, so nothing has to be installed or kept running on the server. The customer signs in once with the account they already have, points Skyr at the folder that holds their music, and the library builds itself. Native tag readers scan a large collection quickly, and the scan carries on in the background so a first setup does not tie up the phone.

The library is organised the way listeners think: recently added, artists, genres and decades, with album pages that show the year, the genre and whether an album is standard, high-bitrate or lossless. Smart playlists such as Favourites, a Favourites mix, recently played and a daily library shuffle sit beside the customer's own playlists. Albums and playlists can be downloaded for offline listening, and the app supports AirPlay, widgets and Live Activities on iPhone.

Skyr works away from home as well. The app includes a guided setup for direct remote access to the NAS, so a customer on a train or in another country streams from the same library over their own connection. A family shares one library through a single family account on the NAS. Each family member joins through an invitation sent over iCloud, gets their own profile with a PIN or Face ID, and keeps their own playlists, favourites and listening history. Profiles work on the shared Apple TV as well as on personal devices.

Skyr does not operate a music-storage service or require a separate Skyr account. Music streams directly from the customer's NAS or plays from local downloads. Personal NAS passwords are saved in the device Keychain. Profiles, playlists, favourites, history and family connection details synchronize through Apple's CloudKit service; the credentials selected for Family Access are shared, with the password in an encrypted CloudKit field. The app includes no advertising or third-party analytics SDK. Album covers come from NAS folders or embedded music tags. Skyr does not perform online artwork searches; missing covers use generated designs. Older caches with no recorded source are left unused, and available source covers return on the next connected scan. See [the privacy-policy draft](PRIVACY-POLICY.md) for the complete data flows and remaining publication requirements.

## The business

Skyr is sold through the App Store. One purchase, or a subscription, unlocks the app on every Apple device tied to a customer's account: iPhone, iPad, Mac and Apple TV. Because Skyr operates no infrastructure, each sale carries almost no ongoing cost, and the product scales without a server bill growing alongside it.

The customer is easy to describe and to reach. They already own a Synology NAS, already own their music, and already live inside Apple's devices. They value ownership and privacy, and they are used to paying for well-made software. Synology's own community forums, NAS and hi-fi publications, and the App Store itself are where these people look for exactly this kind of app.

The competition serves this customer poorly. Synology's own audio apps have not kept pace with modern platforms. Plexamp and Roon require a media server or a core running alongside the NAS, plus their own subscriptions. Self-hosted alternatives demand technical setup that most households will not attempt. Cloud music lockers upload the collection to a third party and match tracks imperfectly. Skyr connects directly to the NAS without installing a separate media server, keeps the original music under the customer's control, and uses native Apple interfaces across its supported platforms.

The product exists today across iPhone, iPad, Mac and Apple TV, with a shared core that lets a feature land on every platform at once. The roadmap concentrates on the things owners of large libraries ask for: richer browsing of very large collections, wider format support, and deeper family features, while holding to the same rule throughout. The music, the data and the trust stay with the customer.
