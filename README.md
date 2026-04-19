# arr-notify

A single bash script that sends rich Discord notifications when Sonarr/Radarr
finish importing a download — but only for **automated** grabs (RSS sync,
scheduled search, release push). Grabs you triggered manually are suppressed.

Why: Sonarr/Radarr's built-in Discord notification has no way to tell "I just
clicked Search on this movie, I don't need a ping when it finishes" apart from
"this release showed up overnight from RSS sync." This script does.

## What a notification looks like

Each message is a Discord embed with:

- Arr logo as the webhook avatar
- Series/movie title (linked to TVDB/IMDB)
- Poster as a right-corner thumbnail
- One-sentence synopsis (per-episode for TV, movie overview for film)
- `Quality` and `Source` inline fields
- Timestamp and `Sonarr · Imported` / `Radarr · Upgraded` footer

## Requirements

- Sonarr v4+ or Radarr v5+
- `bash`, `curl`, `jq` available wherever the script runs (already present in
  the LinuxServer.io arr container images)
- A Discord webhook URL for the target channel

## Install

1. Place the repo somewhere reachable from **inside** each arr container. If
   you run the LinuxServer.io images, a shared media mount like
   `/mnt/storage/arr-notify` works well since every container already has it
   mounted.

2. Copy the env file and fill in your webhook:

   ```
   cp notify-discord.env.example notify-discord.env
   chmod 600 notify-discord.env
   ```

   Paste your Discord webhook URL into `notify-discord.env`.

3. In each arr: **Settings → Connect → + → Custom Script**
   - Name: anything (e.g. `Discord (filtered)`)
   - Triggers: enable **On Import**, **On Upgrade**, and (Sonarr only)
     **On Import Complete**. Leave everything else off.
   - Path: absolute path to `notify-discord.sh` as seen from inside the
     container (e.g. `/mnt/storage/arr-notify/notify-discord.sh`).
   - Save. Click **Test** — you should get a confirmation embed in Discord.

## How it filters

On every import/upgrade event the arr hands the script a `download_id`. The
script queries `/api/v3/history?downloadId=…`, finds the matching `grabbed`
record, and reads `data.releaseSource`.

| Source              | Forwarded? |
|---------------------|------------|
| `Rss`               | yes        |
| `Search`            | yes        |
| `ReleasePush`       | yes        |
| `Unknown`           | yes (fallback — rare, sent to avoid losing real notifications) |
| `InteractiveSearch` | no         |
| `UserInvokedSearch` | no         |

If you prefer `Unknown` to be silent, change the `case` block near the top of
the script.

## How it self-configures

The script figures out which arr called it from the `sonarr_*` / `radarr_*`
environment variables the arr sets when invoking a Custom Script. It reads
that instance's API key out of `/config/config.xml` at runtime and talks to
the arr over `http://localhost:<port>`. One script file works for any number
of Sonarr/Radarr instances without per-instance edits.

## Files

| File                          | Purpose                             |
|-------------------------------|-------------------------------------|
| `notify-discord.sh`           | The script itself                   |
| `notify-discord.env`          | Holds `WEBHOOK=…` (gitignored)      |
| `notify-discord.env.example`  | Placeholder for new clones          |
