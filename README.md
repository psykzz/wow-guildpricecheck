# GuildPriceCheck

A World of Warcraft addon that replies to guild queries with Auctionator prices.

## Features

- Listens for messages in guild chat starting with `?` followed by an item link
- Returns the current auction house price from Auctionator data
- Uses leader election to ensure only one guild member responds
- Requires the Auctionator addon to function
- Listed under **Auctions** in the AddOns list with a coin icon

## Installation

1. Download the latest release from CurseForge, WowInterface, or GitHub Releases
2. Extract to your `World of Warcraft/_retail_/Interface/AddOns/` directory
3. Make sure you have Auctionator installed
4. Restart World of Warcraft or reload UI with `/reload`

## Usage

In guild chat, type `?` followed by an item link (Shift+Click an item):
```
?[Item Name]
```

The addon will automatically respond with the current auction house price if available.

## Releasing

This addon uses the BigWigs packager for automated releases:

1. Ensure all changes are committed
2. Create a git tag with version number:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. GitHub Actions will automatically:
   - Package the addon
   - Create a GitHub release
   - Upload to CurseForge (requires `CF_API_KEY` secret)
   - Upload to WowInterface (requires `WOWI_API_TOKEN` secret)

### Required Secrets

For automated uploads, configure these GitHub repository secrets:
- `CF_API_KEY` - CurseForge API token
- `WOWI_API_TOKEN` - WowInterface API token

Without these secrets, the packager will still create a GitHub release with the packaged addon.

## Development

### Files

- `GuildPriceCheck.toc` - Addon metadata and file list
- `core.lua` - Main addon logic
- `.pkgmeta` - BigWigs packager configuration
- `.github/workflows/release.yml` - Automated release workflow

## License

See repository for license information.
