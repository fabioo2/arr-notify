#!/bin/bash
# Triggered by qBittorrent on torrent completion. Waits a short window for the
# matching arr instance to auto-import, then posts a Discord warning if it
# didn't. Closes the gap where Sonarr's OnManualInteractionRequired event
# fails to fire (e.g. single-file torrents landing at the watch root).
#
# Configure in qB:
#   Settings → Downloads → Run external program on torrent completion:
#     /mnt/storage/arr-notify/notify-pending.sh "%I" "%L" "%N" "%F"
#
# Args (qB substitution macros):
#   %I  v1 infohash      → Sonarr/Radarr downloadId after uppercase
#   %L  category         → routes to the right arr (tv / anime / movies)
#   %N  torrent name     → fallback display title if queue lookup fails
#   %F  content path     → unused for now, useful for future debugging

set -u

INFOHASH="${1:-}"
CATEGORY="${2:-}"
TORRENT_NAME="${3:-}"

[[ -z "$INFOHASH" ]] && exit 0

ENV_FILE="$(dirname "$0")/arr-notify.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
: "${WEBHOOK:?WEBHOOK must be set via $ENV_FILE}"

SONARR_LOGO="https://raw.githubusercontent.com/Sonarr/Sonarr/main/Logo/256.png"
RADARR_LOGO="https://raw.githubusercontent.com/Radarr/Radarr/develop/Logo/256.png"
SONARR_COLOR=3589616
SONARR_ANIME_COLOR=10181046
RADARR_COLOR=16761904
WARN_COLOR=15548997

# Map qB category to arr instance. Category values come from Sonarr/Radarr's
# download-client config (tvCategory / movieCategory).
case "$CATEGORY" in
    tv)
        ARR_URL="http://sonarr:8989"
        ARR_KEY="${SONARR_KEY:-}"
        ARR_KIND=sonarr
        LABEL=Sonarr
        AVATAR="$SONARR_LOGO"
        ;;
    anime)
        ARR_URL="http://sonarr-anime:8989"
        ARR_KEY="${SONARR_ANIME_KEY:-}"
        ARR_KIND=sonarr
        LABEL="Sonarr Anime"
        AVATAR="$SONARR_LOGO"
        ;;
    movies)
        ARR_URL="http://radarr:7878"
        ARR_KEY="${RADARR_KEY:-}"
        ARR_KIND=radarr
        LABEL=Radarr
        AVATAR="$RADARR_LOGO"
        ;;
    *)
        exit 0
        ;;
esac

[[ -z "$ARR_KEY" ]] && { echo "no API key configured for category '$CATEGORY'" >&2; exit 0; }

# Sonarr/Radarr store downloadId as the uppercase v1 infohash.
DL_ID=$(printf '%s' "$INFOHASH" | tr 'a-z' 'A-Z')

# Wait for the arr's queue tracker to attempt import. Default scan interval is
# ~60s; 3 minutes covers 2-3 attempts.
sleep 180

CURL_OPTS=(-s --max-time 10)
arr_get() { curl "${CURL_OPTS[@]}" -H "X-Api-Key: $ARR_KEY" "$1"; }

# Truncate to N chars (byte-counted; conservative vs. Discord codepoint limits).
cap() {
    local max="$1" s="$2"
    if (( ${#s} <= max )); then printf '%s' "$s"
    else printf '%s…' "${s:0:max-1}"
    fi
}

# Imported in the meantime? Then the arr already posted via OnImportComplete.
HISTORY=$(arr_get "$ARR_URL/api/v3/history?downloadId=$DL_ID&pageSize=50")
IMPORTED=$(jq '[.records[] | select(.eventType=="downloadFolderImported")] | length' <<<"$HISTORY")
(( IMPORTED > 0 )) && exit 0

# Look up the queue entry to enrich the embed with reason / poster / title.
QUEUE=$(arr_get "$ARR_URL/api/v3/queue?includeUnknownSeriesItems=true&pageSize=500")
ENTRY=$(jq --arg id "$DL_ID" '[.records[] | select(.downloadId == $id)][0] // empty' <<<"$QUEUE")

REASON="" TITLE_TEXT="" POSTER=""
if [[ -n "$ENTRY" ]]; then
    REASON=$(jq -r '
        ([(.statusMessages // [])[] | (.messages // [])[]] | unique | join("; ")) as $m |
        if ($m | length) > 0 then $m
        elif (.errorMessage // "") != "" then .errorMessage
        else "Downloaded but not imported (queue gives no detail)" end
    ' <<<"$ENTRY")
    if [[ "$ARR_KIND" == "sonarr" ]]; then
        SID=$(jq -r '.seriesId // empty' <<<"$ENTRY")
        if [[ -n "$SID" ]]; then
            S=$(arr_get "$ARR_URL/api/v3/series/$SID")
            TITLE_TEXT=$(jq -r '.title // empty' <<<"$S")
            POSTER=$(jq -r '[.images[]? | select(.coverType=="poster") | .remoteUrl][0] // empty' <<<"$S")
        fi
    else
        MID=$(jq -r '.movieId // empty' <<<"$ENTRY")
        if [[ -n "$MID" ]]; then
            M=$(arr_get "$ARR_URL/api/v3/movie/$MID")
            year=$(jq -r '.year // empty' <<<"$M")
            t=$(jq -r '.title // empty' <<<"$M")
            [[ -n "$year" && -n "$t" ]] && TITLE_TEXT="$t ($year)" || TITLE_TEXT="$t"
            POSTER=$(jq -r '[.images[]? | select(.coverType=="poster") | .remoteUrl][0] // empty' <<<"$M")
        fi
    fi
else
    REASON="Not in queue and not imported — torrent may have been removed before $LABEL processed it."
fi

[[ -z "$TITLE_TEXT" ]] && TITLE_TEXT="${TORRENT_NAME:-Unknown release}"

case "$LABEL" in
    "Sonarr Anime") COLOR=$SONARR_ANIME_COLOR ;;
    Sonarr)         COLOR=$SONARR_COLOR ;;
    Radarr)         COLOR=$RADARR_COLOR ;;
esac

EMBED_TITLE=$(cap 256 "Downloaded but not imported — $TITLE_TEXT")
REASON=$(cap 4096 "$REASON")
RELEASE=$(cap 1024 "${TORRENT_NAME:-unknown}")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

payload=$(jq -n \
    --arg u "$LABEL" --arg a "$AVATAR" \
    --arg t "$EMBED_TITLE" --arg d "$REASON" \
    --arg release "$RELEASE" --arg poster "$POSTER" \
    --argjson color "$WARN_COLOR" --arg ts "$TIMESTAMP" \
    '{username:$u, avatar_url:$a,
      allowed_mentions:{parse:[]},
      embeds:[{
        title:$t, description:$d, color:$color, timestamp:$ts,
        thumbnail: (if $poster == "" then null else {url:$poster} end),
        footer: {text: ($u + " · Downloaded but not imported")},
        fields: [{name:"Release", value:$release, inline:false}]
      } | with_entries(select(.value != null))]}')

curl "${CURL_OPTS[@]}" -o /dev/null -X POST \
    -H "Content-Type: application/json" \
    --data "$payload" "$WEBHOOK"
