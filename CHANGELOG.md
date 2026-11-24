# Changelog

All notable changes to this project are documented here. Versions follow Semantic Versioning; the `+N` suffix in `pubspec.yaml` is the monotonically increasing Android build number.

## 2.0.1 - 2026-11-25

- Add a `本地文件夹` server type: pick a folder through the system picker and browse every video inside it, subdirectories included. The folder is scanned directly rather than through MediaStore, so whatever was picked is what gets listed.
- Thumbnails are cached in memory and on disk, keyed by file uri with the modification time stored alongside, so a video is decoded once no matter which screen asked for it.
- Add a continue watching row and a playback history page (50 most recent entries), with per-tile progress bars.
- Play a folder as a playlist: the player now shows previous/next buttons, and each episode resumes at its own position.
- Add player gestures: drag horizontally to seek with a time preview, hold to play at 2x, double tap to pause or resume, single tap for the controls.
- Fix playback progress being lost when moving to the next episode: the outgoing episode is now written before switching, so the history keeps every episode watched in a session. Completed episodes stay in the history and are labelled instead of disappearing.
- Fix download tasks that outlived their worker hanging forever in `下载中` and refusing to cancel. Tasks whose worker is gone are reported as failed, and cancelling disconnects the transfer instead of waiting out the read timeout.
- Replace the hand-rolled glass tab bar with the one bundled with `liquid_glass_easy` 5.2.0, fixing the duplicate sliding pill, the lagging pill, unresponsive taps and the overflow stripe under the labels.
- Speed up thumbnail loading: decode through Flutter's image cache instead of shipping JPEG bytes over the platform channel, prefetch the first screen after a scan, and run two decoder threads instead of four so decoding stops competing with rendering.

## 2.0.0 - 2026-11-25

- Rename the app from `M3U8 视频下载器` to `AxPlayer`. This is a breaking release: the Android application ID changes from `io.github.alone4869.m3u8downloader` to `io.github.alone4869.axplayer`, so the new build installs alongside the old one and does not migrate its settings, saved servers, SMB credentials, or task history.
- Move the download folder from `下载/M3U8 Downloader` to `下载/AxPlayer`. Files already saved in the old folder stay on disk but are no longer listed in the app.
- Upload local videos to an SMB server from settings, picking multiple files through the system document picker.
- Share videos from other apps into AxPlayer and send them straight to an SMB folder, with a confirmation page and per-file thumbnails.
- Replace the glass navigation bar with a ported `LiquidBottomTabs` bar.
- Rename the Dart package to `axplayer`, the Kotlin package to `io.github.alone4869.axplayer`, and the platform channels to `axplayer/methods`, `axplayer/events`, and `axplayer/upload_events`.
- Rename the GitHub repository to `Alone4869/AxPlayer`; release APKs are now published as `axplayer-vX.Y.Z-<abi>.apk`.

## 1.3.6 - 2026-08-02

- Group the server card actions behind a long-press menu.
- Defer Jellyfin content until the route transition settles, stagger image loads, and smooth first-entry transitions.

## 1.3.5 - 2026-08-02

- Add a theme mode switcher.
- Browse the works of a person or a genre from Jellyfin detail pages.

## 1.3.4 - 2026-08-02

- Fix server page transitions, add an immersive carousel, and show brand logos for media libraries.

## 1.3.3 - 2026-08-02

- Add a servers tab with Jellyfin support: browse libraries, a home carousel, and media details.
- Add an embedded ExoPlayer with a player picker for playback from server pages.

## 1.3.2 - 2026-07-26

- Redesign the SMB upload folder picker with a compact responsive layout, clearer navigation, and polished loading, empty, and error states.

## 1.3.1 - 2026-07-26

- Support navigating into nested SMB folders when choosing an upload destination.
- Stream SMB directory enumeration and keep file entries out of the folder picker to reduce memory usage in large directories.

## 1.3.0 - 2026-07-22

- Add a pending uploads tab that tracks completed videos not yet uploaded to SMB.
- Replace the default Flutter launcher icon with adaptive, round, and themed app icons.

## 1.2.9 - 2026-07-19

- Reorganize Settings into focused secondary pages for download performance and app information.
- Clarify download, update, content usage, and SMB descriptions.

## 1.2.8 - 2026-07-16

- Simplify and center the top headers across the home, downloads, and settings pages.

## 1.2.7 - 2026-07-16

- Retry failed downloads in place so the original task changes back to queued and no duplicate task remains.

## 1.2.6 - 2026-07-16

- Add a retry action to the long-press menu for failed downloads.
- Preserve and display the original source page URL alongside the resolved download URL.
- Make task details more compact by removing the duplicated large file-name title.

## 1.2.5 - 2026-07-16

- Simplify X video quality rows so bitrate remains visible without repeating the quality level.
- Use smaller secondary text for resolution and container details.

## 1.2.4 - 2026-07-16

- Remove bitrate-based file-size estimates from X video quality choices.
- Probe the selected final download URL and show its actual file size in the confirmation dialog.

## 1.2.3 - 2026-07-16

- Align the download edit actions directly above navigation and use matching icon buttons for delete and upload.

## 1.2.2 - 2026-07-16

- Keep floating notifications above the liquid-glass bottom navigation.
- Keep download edit actions and the end of task lists clear of the bottom navigation.

## 1.2.1 - 2026-07-16

- Publish separate signed APKs for `arm64-v8a`, `armeabi-v7a`, and `x86_64`.
- Select the matching APK automatically during in-app update checks.
- Fall back to the GitHub Release page instead of downloading an incompatible APK when the device ABI cannot be matched.

## 1.2.0 - 2026-07-16

- Add GitHub Releases update checks and dynamic version information in Settings.
- Add in-app open-source license information.
- Establish the stable Android application ID `io.github.alone4869.m3u8downloader`.
- Add release signing support, CI, and signed APK publishing workflow.
- Document licensing, third-party projects, security, contributions, and releases.
