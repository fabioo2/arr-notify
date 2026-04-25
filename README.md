# arr-notify

Two bash scripts that send rich Discord notifications about Sonarr/Radarr
activity:

- **`notify-arr.sh`** — fired by Sonarr/Radarr Custom Script connections.
  Posts on automated imports, upgrades, and `OnManualInteractionRequired`
  events. Manually triggered grabs are suppressed.
- **`notify-pending.sh`** — fired by qBittorrent on torrent completion.
  Waits a short window for the matching arr to auto-import, then posts a
  warning if it didn't. Closes the gap where Sonarr's
  `OnManualInteractionRequired` doesn't fire (e.g. single-file torrents
  landing at the watch root).

## What a notification looks like

Each message is a Discord embed with the arr's logo as the webhook avatar,
a series/movie title (linked to TVDB/IMDB on imports), poster thumbnail,
one-sentence synopsis, and quality/source/release fields.

| Trigger                          | Color  | Footer                              |
|----------------------------------|--------|-------------------------------------|
| Imported (RSS/Search/Push)       | cyan   | `Sonarr · Imported`                 |
| Upgraded                         | cyan   | `Sonarr · Upgraded`                 |
| Imported (Sonarr Anime instance) | purple | `Sonarr Anime · Imported`           |
| Imported (movie)                 | yellow | `Radarr · Imported`                 |
| Manual import needed (arr-fired) | red    | `Sonarr · Manual interaction required` |
| Downloaded but not imported (qB-fired) | red | `Sonarr · Downloaded but not imported` |

## Requirements

- Sonarr v4+ or Radarr v5+
- qBittorrent v4.4+ (for `notify-pending.sh`)
- `bash`, `curl`, `jq` available wherever the scripts run (already present
  in the LinuxServer.io arr and qB container images)
- A Discord webhook URL for the target channel

## Install

1. Clone the repo somewhere reachable from **inside** each arr container
   *and* the qB container. A shared media mount like `/mnt/storage/arr-notify`
   works since LinuxServer.io images all mount it.

2. Copy the env file and fill in your secrets:

   ```
   cp arr-notify.env.example arr-notify.env
   chmod 600 arr-notify.env
   ```

   Set:
   - `WEBHOOK` — Discord webhook URL (used by both scripts)
   - `SONARR_KEY`, `SONARR_ANIME_KEY`, `RADARR_KEY` — only needed by
     `notify-pending.sh`. `notify-arr.sh` reads each instance's key from
     `/config/config.xml` at runtime since it executes inside the arr
     container.

3. **In each arr: Settings → Connect → + → Custom Script**
   - Name: anything (e.g. `Discord (filtered)`)
   - Triggers: enable **On Import**, **On Upgrade**,
     **On Import Complete**, and **On Manual Interaction Required**.
     Leave **On Grab** off (the script doesn't handle it; qB's hook
     covers the post-grab gap).
   - Path: `/mnt/storage/arr-notify/notify-arr.sh`
   - Save and click **Test** — you should get a confirmation embed.

4. **In qBittorrent: Settings → Downloads → Run external program on
   torrent completion**:

   ```
   /mnt/storage/arr-notify/notify-pending.sh "%I" "%L" "%N" "%F"
   ```

   The four args are the v1 infohash, qB category, torrent name, and
   content path.

## How `notify-arr.sh` filters

Sonarr/Radarr hand the script a `download_id` for every event. The script
queries `/api/v3/history?downloadId=…`, finds the matching `grabbed`
record, and reads `data.releaseSource`.

| Source              | Forwarded? |
|---------------------|------------|
| `Rss`               | yes        |
| `Search`            | yes        |
| `ReleasePush`       | yes        |
| `Unknown`           | yes (fallback to avoid losing real notifications) |
| `InteractiveSearch` | no         |
| `UserInvokedSearch` | no         |

If you prefer `Unknown` to be silent, change the `case` block near the top
of the script.

## How `notify-pending.sh` works

qB invokes the script the moment a torrent finishes downloading. The script:

1. Maps the qB category (`tv` / `anime` / `movies`) to the right arr
   instance via env-stored API keys.
2. Sleeps 3 minutes — enough for the arr's queue tracker (default ~60s
   scan) to make 2-3 import attempts.
3. Hits `/api/v3/history?downloadId=<UPPERCASE_INFOHASH>`. If a
   `downloadFolderImported` record exists, the import succeeded and the
   arr already posted via `OnImportComplete` — exit silently.
4. Otherwise, look up the queue entry to extract the failure reason,
   fetch the series/movie metadata for poster + title, and post a red
   warning embed to Discord.

The 3-minute sleep runs as a child of the qB container. If qB restarts
during the wait that one notification is lost — acceptable for the use
case.

## How `notify-arr.sh` self-configures

The script figures out which arr called it from the `sonarr_*` /
`radarr_*` environment variables the arr sets when invoking a Custom
Script. It reads that instance's API key out of `/config/config.xml` at
runtime and talks to the arr over `http://localhost:<port>`. One script
file works for any number of Sonarr/Radarr instances without per-instance
edits.

## Files

| File                       | Purpose                                  |
|----------------------------|------------------------------------------|
| `notify-arr.sh`            | Fired by arr Custom Script connections   |
| `notify-pending.sh`        | Fired by qB on torrent completion        |
| `arr-notify.env`           | Webhook + API keys (gitignored)          |
| `arr-notify.env.example`   | Template for new clones                  |
