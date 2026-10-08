<p align="right"><a href="README.md">한국어</a></p>

<p align="center">
  <img src="design/other/main_banner_en.webp" alt="Number Memo" width="100%">
</p>

<h1 align="center">Number Memo</h1>
<p align="center">Explore images from websites you choose and organize your favorites into folders.</p>
<p align="center"><a href="https://github.com/nextline-ai/Number-Memo/releases">Updates</a> · <a href="https://discord.gg/vUTGZNMaMB">Help and feedback</a></p>

## Get started

1. Tap **Enter Website Address** and enter the home address of a website you use. No sites are included by default. Supported comics websites can also be connected here.
2. Import a **Violet** or **Anime Boxes** backup if you have one. You can skip this step and import later in Settings.
3. Tap or slide the **book / image switch** at the top of the screen to move between comics mode and image mode. Onboarding always finishes in image mode.
4. With only image websites connected, **Explore** in comics mode shows their pools. Connect a comics website to switch to comics browsing. **Import from Violet** is also available from comics mode.

The current Swift native app requires **iOS 17 or later** and supports English, Korean, and Japanese. This guide describes the latest features on `main`. See the [release notes](https://github.com/nextline-ai/Number-Memo/releases) for installation and availability.

No address yet? Choose **Set Up Later**. Add a site from **Saved**, **Explore**, or **More → Servers** whenever you are ready. If the type is not recognized, check the website’s help page and select it yourself. Review the site’s terms and only access content you have permission to use.

## Image library backups

Open **More → Library Management** to export or restore a JSON backup, or import from Anime Boxes. Backups include servers, favorites, folder colors and order, saved tags and artists, saved searches, recent search history, and blacklists. Restoring merges into the current library; matching favorites and folder colors/order use the backup values. Image files, sign-in credentials and cookies are not included. Restored library changes also sync when iCloud is enabled. Both modes automatically choose unused colors from the same folder palette.

## Two modes

| | Comics mode | Image mode (Booru) |
| --- | --- | --- |
| Browse | Gallery search, popular galleries, artists | Multiple servers together, latest or popular, rating filters |
| Save | Gallery bookmarks and folders | Image favorites and folders |
| Search | Tag autocomplete, default tags and exclusions | Tag autocomplete, search history, per-server blacklists |
| View | Full-screen reader, reading direction, continuous scrolling | Large images, GIFs, videos, pools and notes |
| Import | Violet `user.db` / `data.db` | Anime Boxes `.abbj` backups |

Saved items, tags, artists, appearance, and viewer settings are separate for each mode. Comics starts with 2 grid columns and Booru with 3; change these in each mode's settings.

### Comics mode

- Organize galleries into folders and save artists. You can also add galleries through Safari's share menu.
- Set default search tags and excluded tags to avoid entering them each time.
- Export or restore a JSON backup in **Settings → Library Management**. Keep the file in Files or iCloud Drive.

### Image mode (Booru)

- Add servers in **More → Servers**. Supported types include Danbooru, Gelbooru, Old Gelbooru (v0.1.11, used by booru.org), and Moebooru.
- Select multiple servers from the top server menu to include them in both Explore and Saved.
- **Hold an image in Explore or the viewer to save it. Hold again to remove it.** Use **Save to Folder** in the viewer menu to choose a folder.
- Popular sorts by highest score. Use the adjacent **Rating** menu to filter results; **All Ratings** applies no automatic rating filter.
- Open **More → Pools** for ordered image collections. Images with notes can display the site's annotations or translations.

Appearance, language, browsing, and media settings are directly accessible in **More**.

Booru favorites are stored in the app and do not automatically sync with your website account. Previews are prefetched when saving and cached locally up to 256 MB for reuse after relaunch or offline. Viewer images use a separate 512 MB cache and preload two images in each direction. Viewers show a loading indicator until the full image is ready and continue into the next Explore or recommendation page. Use Clear Image Cache in More to remove both caches. Video, pool, and note support varies by server and device.

## Library, searches and sync

- Switching modes keeps the corresponding tab, search text, and loaded Explore results. Clear the search and pull down to refresh the default feed.
- Hold an item inside a folder for its menu, or use **Select** to move or delete multiple items. Hold a folder to change its name, color or order.
- Tap the **star** next to a search history entry to keep the complete query, including multiple tags, in **Saved Searches**. History is kept until you delete it by default. Swipe to remove one entry or use the trash button beside the heading to clear history. Saved searches remain.
- **iCloud sync is on by default.** Enable iCloud Drive with the same Apple account to merge saved items, folder colors and order, artists, searches, and general settings. Turn it off in either mode's settings; existing data stays intact.
- Grid layout, playback preferences, cached media, server account keys, and browser cookies stay separate on each device.

## Viewer and translation

Tap the center to open the menu. Tap the edges or swipe sideways to move between pages or images. Double-tap or pinch to zoom. In the Booru viewer, swipe down at the original zoom level to close. For videos, tap with two fingers to open the quick menu. Videos autoplay muted; use the playback controls to turn on sound. Details includes the post ID and a copy button.

The **Translate** menu uses Apple's text recognition and translation. Translation follows your system language by default; choose a different language in each mode's settings. Custom translation languages require iOS 18 or later. You can also change the app's display language in Settings.

## Trouble connecting?

Temporary connection failures are retried up to three times. If they continue, follow these steps.

1. Open **Validate Client** from the Booru error screen or server settings. Complete the website's verification and tap **Done** to retry. Some searches require additional verification on that search page.
2. If the problem continues, enable **More → Use Embedded Browser**, or switch from the error screen. Tap the browser's grid button to return to native browsing.
3. For booru.org sites, try **All Ratings**. You can also enter server credentials or reset cookies in the server settings when needed.

**Danbooru usually limits regular accounts to two search tags.** To search with more tags, upgrade your account on the website and enter your username and API key in the app's server settings. **Gelbooru does not have this two-tag limit.**

Comics also offers **Open in Built-in Browser** in Settings. You can replay the setup guide from either mode's settings.

## Developer and community

<img src="design/branding/nextline-logo.svg" alt="NextLine" width="160" align="right">

- **Developer:** NextLine
- **Email:** [contact@nextline.work](mailto:contact@nextline.work)
- **Website:** [nextline.work](https://nextline.work)
- **Community / bug reports:** [Discord](https://discord.gg/vUTGZNMaMB)

Developer details and links are also available at the bottom of **More** in Booru and **Settings** in Comics.

Report problems through the [Discord community](https://discord.gg/vUTGZNMaMB). Include your app version, device, and steps to reproduce the issue.

Number Memo is an independent client and is not affiliated with Apple or the supported websites.
[Privacy Policy](docs/privacy-policy.md) · [App Store review checklist](docs/app-store-review.md)

## AI recommendations and taste statistics

Browse new works in the **AI tab** with infinite scrolling. Existing recommendations stay in place when switching tabs or modes or opening a work; only an explicit refresh replaces the list. Refresh deals unseen candidates first and rotates statistical highlights. Hold a work to save it, and hold again to remove it. These deliberate choices contribute preference evidence while retaining their recommendation origin. **Recommendation evidence** links to the supporting tags and works. Weekly statistics and monthly card-based **Recaps** are at the top of Taste Analysis Settings. New recaps appear in a dismissible banner across tabs. Explicit search-and-save evidence is separated from recurring co-occurring tags. File formats, resolution, and management metadata do not contribute to preferences. Analysis exclusion tags are editable per mode. Defaults are `1girl`, `1boy`, and `solo` for images; `female:sole_female`, `male:sole_male`, `tag:digital`, and `tag:group` for comics. Exclusions saved with the old `solo` spelling also match the actual `sole` tags. Work details from Explore and AI recommendations open in a swipe-down sheet, with reserved thumbnail space to keep titles and actions steady during loading.

Analysis is on by default, with separate image and comic profiles. Records are kept until deletion, independently of search-history retention, and merge through iCloud when both sync settings are enabled. You can pause analysis, disable AI explanations or analysis sync, or delete analysis without deleting your library. Offline devices apply changes on their next sync.

AI explanations require iOS 26 or later and an available on-device Apple Intelligence model. Only temporary opaque identifiers and computed statistics reach the model; tags, titles, images, and source URLs do not. AI results are reused, with up to three generations per rolling five-minute window and one active session at a time. Temperature does not gate generation. Low Power Mode and backgrounding pause generation; statistical recommendations remain available without AI. Recommendation search tags reach your connected websites. iCloud Drive uses your existing protection settings.
