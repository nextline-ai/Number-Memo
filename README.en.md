<p align="right"><a href="README.md">한국어</a></p>

<p align="center">
  <img src="design/other/main_banner_en.webp" alt="Number Memo" width="100%">
</p>

<h1 align="center">Number Memo</h1>
<p align="center">Explore images from websites you choose and organize your favorites into folders.</p>
<p align="center"><a href="https://github.com/nextline-ai/Number-Memo/releases">Updates</a> · <a href="https://discord.gg/vUTGZNMaMB">Help and feedback</a></p>

## Get started

1. Tap **Enter Website Address** and enter the home address of an image website you use. No sites are included by default. Known server types are recognized automatically; a custom name and account credentials are optional.
2. Import a **Violet** or **Anime Boxes** backup if you have one. You can skip this step and import later in Settings.
3. Tap or slide the **book / image switch** at the top of the screen to move between comics mode and image mode. Onboarding always finishes in image mode.
4. Comics mode has no website connected by default for licensing reasons. Tap the book icon, then **Enter Website Address**, to connect a supported site. Only use content you have permission to access.

The current Swift native app requires **iOS 17 or later** and supports English, Korean, and Japanese. This guide describes the latest features on `main`. See the [release notes](https://github.com/nextline-ai/Number-Memo/releases) for installation and availability.

No address yet? Choose **Set Up Later**. Add a site from **Saved**, **Explore**, or **More → Servers** whenever you are ready. If the type is not recognized, check the website’s help page and select it yourself. Review the site’s terms and only access content you have permission to use.

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

Booru favorites are stored in the app and do not automatically sync with your website account. Video, pool, and note support varies by server and device.

## Library, searches and sync

- Switching modes keeps the corresponding tab, search text, and loaded Explore results. Clear the search and pull down to refresh the default feed.
- Hold an item inside a folder for its menu, or use **Select** to move or delete multiple items. Hold a folder to change its name, color or order.
- Tap the **star** next to a search history entry to keep the complete query, including multiple tags, in **Saved Searches**. History keeps the last 3 days by default. Swipe to remove one entry or use the trash button beside the heading to clear history. Saved searches remain.
- **iCloud sync is on by default.** Enable iCloud Drive with the same Apple account to merge saved items, folder colors and order, artists, searches, and general settings. Turn it off in either mode's settings; existing data stays intact.
- Grid layout, playback preferences, cached media, server account keys, and browser cookies stay separate on each device.

## Viewer and translation

Tap the center to open the menu. Tap the edges or swipe sideways to move between pages or images. Double-tap or pinch to zoom. In the Booru viewer, swipe down at the original zoom level to close. Videos autoplay muted; use the playback controls to turn on sound. Details includes the post ID and a copy button.

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
