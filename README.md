# Vernissage Migrator

A shell script for migrating user data between [Vernissage](https://joinvernissage.org) instances — no Python, no Node.js, no dependencies beyond `curl` and `jq`.

## Features

- Exports profile, photos, statuses, following and follower lists
- Generates a self-contained HTML photo album from the export (gallery)
- Imports photos and statuses to a new instance, including rate limit handling
- Automatically configures S3 bucket CORS for the target instance
- Resume support: interrupted imports pick up where they left off
- Hashtag remapping across descriptions and post content
- Works with password login or Bearer token (required for OAuth-only instances)
- Handles open and closed instance registration, including CAPTCHA detection

## Requirements

- `curl` (available on virtually all Unix systems)
- `jq` (JSON processor)
- `awscli` — only needed for the `cors` subcommand

```bash
# Debian / Ubuntu
sudo apt install curl jq

# macOS
brew install jq
```

## Quick Start

```bash
chmod +x vernissage_migrate.sh

# 1. Export from source instance
./vernissage_migrate.sh export \
  --source https://source-instance.example \
  --user myuser \
  --token "eyJ..."

# 2. Configure CORS on the S3 bucket (once, before importing)
./vernissage_migrate.sh cors \
  --s3-endpoint https://hel1.your-objectstorage.com \
  --s3-bucket vernissage-assets \
  --s3-key YOUR_ACCESS_KEY \
  --s3-secret YOUR_SECRET_KEY \
  --origin https://new-instance.example

# 3. Import to target instance
./vernissage_migrate.sh import \
  --target https://new-instance.example \
  --user myuser \
  --token "eyJ..."
```

## Authentication

Vernissage instances typically do not support direct username/password login via API if the instance uses OAuth (Mastodon, Apple, Google sign-in). In that case, use `--token` instead.

**How to get a Bearer token from your browser:**

1. Log in to the instance in your browser
2. Open DevTools (F12) → Network tab
3. Reload the page
4. Click any request to `/api/v1/...`
5. Under Request Headers, copy the value of `Authorization: Bearer eyJ...`
6. Pass only the part after `Bearer ` to `--token`

**Verify the token works:**

```bash
curl -s -H "Authorization: Bearer eyJ..." \
  "https://your-instance.example/api/v1/users/myuser" | jq '.account'
```

## Subcommands

### `export`

Exports profile, all photos and statuses, following and follower lists from the source instance. Photos are downloaded locally into `vernissage_export/photos/`.

```bash
./vernissage_migrate.sh export \
  --source https://source-instance.example \
  --user USERNAME \
  --token "eyJ..."
```

| Option | Description |
|---|---|
| `--source URL` | Source instance URL |
| `--user NAME` | Username on the source instance |
| `--token TOKEN` | Bearer token (recommended) |
| `--password PASS` | Password (only for email+password accounts) |
| `--debug` | Verbose curl output |

The export is saved to `./vernissage_export/` with the following structure:

```
vernissage_export/
  profile.json       # Account profile data
  statuses.json      # All statuses with attachment metadata
  following.json     # List of followed accounts
  followers.json     # List of followers
  gallery.html       # Self-contained photo album (auto-generated)
  photos/            # Downloaded photo files
    <status_id>_0.jpeg
    <status_id>_1.jpg
    ...
  .imported_ids      # Resume file (created during import)
```

### `import`

Imports photos and statuses to the target instance. Supports resuming after interruption.

```bash
./vernissage_migrate.sh import \
  --target https://new-instance.example \
  --user USERNAME \
  --token "eyJ..."
```

| Option | Description |
|---|---|
| `--target URL` | Target instance URL |
| `--user NAME` | Username on the target instance |
| `--token TOKEN` | Bearer token from the target instance |
| `--password PASS` | Password (triggers auto-registration if account doesn't exist) |
| `--email EMAIL` | Email for registration (used with `--password` on open instances) |
| `--debug` | Verbose curl output |

The script handles rate limiting automatically: if the server responds with HTTP 429, it reads the `waitSeconds` value from the response and retries after the specified delay (up to 10 attempts per status).

### `gallery`

Generates a self-contained HTML photo album from an existing export. The gallery is automatically created at the end of every `export` and `full` run, but can also be regenerated standalone at any time.

```bash
./vernissage_migrate.sh gallery
# or with a custom path:
./vernissage_migrate.sh gallery --export-dir /path/to/vernissage_export
```

The output file `vernissage_export/gallery.html` opens directly in any browser — no server required. Features include:

- **Grid and list views** with smooth transitions
- **Full-text search** across notes, descriptions, tags, and locations
- **Lightbox** with keyboard navigation (← → Esc)
- **EXIF data** — camera, shutter speed, aperture, ISO, focal length
- **Location** — name and country per photo
- **Tags** — clickable to filter the gallery
- **Copy to clipboard** — one-click image copy from both the grid and the lightbox
- **Sensitive content** blur with click-to-reveal
- Fully self-contained — works offline from the local export directory

### `cors`

Configures CORS on the S3 bucket so browsers can load images directly from object storage. Requires `awscli`.

```bash
./vernissage_migrate.sh cors \
  --s3-endpoint https://hel1.your-objectstorage.com \
  --s3-bucket vernissage-assets \
  --s3-key YOUR_ACCESS_KEY \
  --s3-secret YOUR_SECRET_KEY \
  --origin https://new-instance.example
```

| Option | Description |
|---|---|
| `--s3-endpoint URL` | S3-compatible storage endpoint |
| `--s3-bucket NAME` | Bucket name |
| `--s3-key KEY` | S3 access key ID |
| `--s3-secret SECRET` | S3 secret access key |
| `--origin URL` | The instance URL that needs to load the images |

**Why is CORS needed?** Browsers block cross-origin image requests unless the S3 bucket explicitly allows them via `Access-Control-Allow-Origin`. Without this, photos appear as black boxes in the UI even though the files are correctly stored.

### `full`

Runs export and import in a single step (password-based login only).

```bash
./vernissage_migrate.sh full \
  --source https://source-instance.example \
  --source-user USERNAME \
  --source-password PASSWORD \
  --target https://new-instance.example \
  --target-user USERNAME \
  --target-password PASSWORD
```

## Resume After Interruption

Every successfully published status is tracked in `vernissage_export/.imported_ids`. If the import is interrupted (network error, expired token, etc.), simply re-run the same import command. Already imported statuses are automatically skipped.

```bash
# Re-run after interruption – already imported statuses are skipped
./vernissage_migrate.sh import \
  --target https://new-instance.example \
  --user myuser \
  --token "eyJ..."

# Start completely fresh
rm vernissage_export/.imported_ids
```

Progress output during import:

```
[1/295] ↑ 7532860260470497410_0.jpeg → Attachment 7648284014742083731
[1/295] ✓ Status published: 7648284031921948819
[2/295] ⏳ Rate limit – waiting 52s ...
[2/295] ✓ Status published: 7648284117821298835
[3/295] ↩ Skipped (already imported): 7533180896959012994
```

## Customisation

Edit the configuration block at the top of the script:

```bash
# Seconds between API calls (increase if hitting rate limits)
REQUEST_DELAY=0.5

# Remap hashtags in descriptions and post content
# Format: "#old=#new"
HASHTAG_MAP=("#sourceinstance=#targetinstance" "#oldtag=#newtag")

# Override profile fields (empty = use value from export)
OVERRIDE_DISPLAYNAME=""
OVERRIDE_BIO=""
```

You can also point to a custom export directory:

```bash
EXPORT_DIR=/path/to/vernissage_export ./vernissage_migrate.sh import \
  --target https://new-instance.example \
  --user myuser \
  --token "eyJ..."
```

## Known Limitations

**Followings and followers** — followings and followers are intentionally not migrated by this script. Vernissage has a built-in **Account Move** feature that handles this correctly as part of the official instance migration flow. Use it after the import is complete:

> **Settings → Account → Move account**

The Account Move notifies your followers via ActivityPub and redirects them to your new account automatically. This is the recommended and reliable way to transfer your social graph.

**Post timestamps** — Vernissage does not accept a custom `createdAt` for imported statuses. All posts will appear with the import date, not the original post date. The original date is preserved in the post content or description if it was included there.

**Attachments per status** — the script handles multiple attachments per status, but only photos are migrated. Video files follow the same flow but may fail depending on the target instance's configuration.

**CAPTCHA-protected instances** — automatic registration is not possible on instances that require CAPTCHA verification. Register manually in the browser, then use `--token` for the import.

## Typical Migration Workflow

```
Source instance                        Target instance
──────────────                         ───────────────
1. Export data          ──────────►    vernissage_export/
                                       gallery.html (auto-generated)
2.                                     Set CORS on S3 bucket
3.                      ──────────►    Import photos & statuses
4.                                     Verify images load correctly
5.                                     Use Account Move in Settings
                                       to transfer followers/followings
```

**Estimated time:** roughly 3–5 seconds per photo due to the API rate limit of ~1 post per minute on most instances. For 300 photos, expect 5–8 hours. The rate limit handling is automatic; the script will pause and retry as needed.

## Troubleshooting

**Black/missing images after import**
The S3 bucket is missing CORS headers. Run the `cors` subcommand, then hard-reload the browser (Ctrl+Shift+R).

**HTTP 401 on upload**
The Bearer token was issued by a different instance. Make sure you use a token from the target instance for the import, and a token from the source instance for the export.

**HTTP 400 `emailNotVerified`**
The account on the target instance exists but the email address has not been confirmed. Check your inbox, confirm the email, log in, then grab a fresh token.

**HTTP 429 `statusCreationTooFrequent`**
The instance enforces a rate limit between posts. The script handles this automatically by reading `waitSeconds` from the response and retrying. No action needed.

**`Too many open files`**
Occurs on large exports (300+ photos) with older versions of the script. The current version writes statuses to temporary files instead of holding them in memory, which avoids this issue.

**Token expired mid-import**
Grab a fresh token from the browser and re-run the import. The resume file ensures already imported statuses are not duplicated.

## License

MIT
