# arr-notify

A single bash script that sends rich Discord notifications about Sonarr/Radarr
grabs.

`notify-arr.sh` is fired by Sonarr/Radarr's **On Grab** Custom Script
connection. It filters out manual grabs, sleeps a configurable window
(default 10 min), and then inspects history + queue to decide what to post:

- Imported successfully (and not an upgrade) → `Imported`
- Imported as an upgrade replacing an existing file → silent
- Download finished but stuck (queue warning/error) → `Action required`
- Still downloading or otherwise unresolved → silent

## What a notification looks like

Each message is a Discord embed with the arr's logo as the webhook avatar,
a series/movie title (linked to TVDB/IMDB on imports), poster thumbnail,
one-sentence synopsis, and quality/source/release fields.

| Outcome                                  | Color  | Footer                       |
|------------------------------------------|--------|------------------------------|
| Imported (Sonarr)                        | cyan   | `Sonarr · Imported`          |
| Imported (Sonarr Anime instance)         | purple | `Sonarr Anime · Imported`    |
| Imported (Radarr)                        | yellow | `Radarr · Imported`          |
| Download finished but stuck              | red    | `<arr> · Action required`    |

Upgrades that replace an existing file are intentionally silent — the
original grab already produced a notification.

## Requirements

- Sonarr v4+ or Radarr v5+
- `bash`, `curl`, `jq` available inside each arr container (already present
  in the LinuxServer.io arr images)
- A Discord webhook URL for the target channel

## Install

1. Clone the repo somewhere reachable from inside each arr container.
   A shared media mount like `/mnt/storage/arr-notify` works since the
   LinuxServer.io images all mount it.

2. Copy the env file and fill in the webhook:

   ```
   cp arr-notify.env.example arr-notify.env
   chmod 600 arr-notify.env
   ```

   `WEBHOOK` is the only required value. `WAIT_SECONDS` is optional (default
   600). `notify-arr.sh` reads each instance's API key from
   `/config/config.xml` at runtime since it executes inside the arr container.

3. **In each arr: Settings → Connect → + → Custom Script**
   - Name: anything (e.g. `Discord (filtered)`)
   - Triggers: enable **On Grab** only. Leave everything else off — the script
     intentionally ignores other events.
   - Path: `/mnt/storage/arr-notify/notify-arr.sh`
   - Save and click **Test** — you should get a confirmation embed.

## How it filters manual grabs

After OnGrab fires, the script queries `/api/v3/history?downloadId=…`,
finds the matching `grabbed` record, and reads `data.releaseSource`.

| Source              | Forwarded? |
|---------------------|------------|
| `Rss`               | yes        |
| `Search`            | yes        |
| `ReleasePush`       | yes        |
| `Unknown`           | yes (fallback to avoid losing real notifications) |
| `InteractiveSearch` | no         |
| `UserInvokedSearch` | no         |

If you prefer `Unknown` to be silent, change the `case` block partway through
the script.

## How the wait + check works

After the manual-grab filter, the script `sleep`s for `WAIT_SECONDS` (default
600). The sleeping process is essentially free — bash sits in the kernel wait
queue with no CPU and ~1 MB resident.

When it wakes:

1. Re-queries `/api/v3/history?downloadId=<UPPERCASE_INFOHASH>`.
   - If there's a `downloadFolderImported` record AND a
     `*FileDeletedForUpgrade` record → upgrade, exit silently.
   - If there's a `downloadFolderImported` record → post the green
     "Imported" embed.
2. Otherwise, look at the queue entry:
   - If `trackedDownloadStatus` is `warning` or `error` → post the red
     "Action required" embed with the queue's status message as the reason.
   - Anything else (still downloading, or weirdly missing) → exit silently.

The sleep runs as a child of the arr container. If the arr restarts during
the wait, that one notification is lost — acceptable for a pet media server.

## Self-configuration

The script figures out which arr called it from the `sonarr_*` / `radarr_*`
environment variables the arr sets when invoking a Custom Script. It reads
that instance's API key out of `/config/config.xml` at runtime and talks to
the arr over `http://localhost:<port>`. One script file works for any number
of Sonarr/Radarr instances without per-instance edits — the Sonarr Anime
instance is distinguished by embed color, picked up from the
`sonarr_instancename` env var.

## Files

| File                       | Purpose                                  |
|----------------------------|------------------------------------------|
| `notify-arr.sh`            | Fired by arr OnGrab Custom Script        |
| `arr-notify.env`           | Webhook + optional `WAIT_SECONDS` (gitignored) |
| `arr-notify.env.example`   | Template for new clones                  |
