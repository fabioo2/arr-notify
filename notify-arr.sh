#!/bin/bash
# Forwards arr grabs to Discord with rich embeds.
#
# Triggered by Sonarr/Radarr's "On Grab" Custom Script connection. The script
# filters out manual grabs (Interactive/UserInvokedSearch) up front, then
# sleeps WAIT_SECONDS and inspects history + queue to decide what to post:
#   - Imported successfully (and not an upgrade) → cyan/yellow "Imported"
#   - Imported as an upgrade replacing an existing file → silent
#   - Download finished but stuck (queue warning/error)  → red "Action required"
#   - Still downloading or otherwise unresolved          → silent

set -u

WAIT_SECONDS="${WAIT_SECONDS:-900}"   # 15 min default — covers most TV grabs

SONARR_LOGO="https://raw.githubusercontent.com/Sonarr/Sonarr/main/Logo/256.png"
RADARR_LOGO="https://raw.githubusercontent.com/Radarr/Radarr/develop/Logo/256.png"
SONARR_COLOR=3589616        # cyan
SONARR_ANIME_COLOR=10181046 # purple
RADARR_COLOR=16761904       # yellow
WARN_COLOR=15548997         # Discord red

ENV_FILE="$(dirname "$0")/arr-notify.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
: "${WEBHOOK:?WEBHOOK must be set via $ENV_FILE}"

CURL_OPTS=(-s --max-time 10)

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

cap() {
    local max="$1" s="$2"
    if (( ${#s} <= max )); then printf '%s' "$s"
    else printf '%s…' "${s:0:max-1}"
    fi
}

first_sentence() {
    awk -v max=240 'BEGIN{RS="\0"} {
        t=$0; gsub(/[[:space:]]+/," ",t); sub(/^ /,"",t); sub(/ $/,"",t);
        if (match(t, /[.!?]/)) t=substr(t,1,RSTART);
        if (length(t) > max) t=substr(t,1,max-1) "…";
        print t
    }'
}

arr_get() { curl "${CURL_OPTS[@]}" -H "X-Api-Key: $ARR_KEY" "$1"; }

post_embed() {
    curl "${CURL_OPTS[@]}" -o /dev/null -X POST \
        -H "Content-Type: application/json" \
        --data "$1" "$WEBHOOK"
}

# Populate TITLE, POSTER, OVERVIEW, LINK from the series/movie API.
fetch_media() {
    local app="$1" id="$2" j
    if [[ -z "$id" ]]; then
        TITLE="" POSTER="" OVERVIEW="" LINK=""
        return
    fi
    if [[ "$app" == "sonarr" ]]; then
        j=$(arr_get "$ARR_URL/api/v3/series/$(urlencode "$id")")
        TITLE=$(jq -r '.title // "Unknown series"' <<< "$j")
        POSTER=$(jq -r '[.images[] | select(.coverType=="poster") | .remoteUrl][0] // empty' <<< "$j")
        OVERVIEW=$(jq -r '.overview // ""' <<< "$j")
        local tvdb
        tvdb=$(jq -r '.tvdbId // empty' <<< "$j")
        LINK=${tvdb:+https://www.thetvdb.com/?tab=series&id=$tvdb}
    else
        j=$(arr_get "$ARR_URL/api/v3/movie/$(urlencode "$id")")
        TITLE=$(jq -r '.title // "Unknown movie"' <<< "$j")
        local year imdb
        year=$(jq -r '.year // empty' <<< "$j")
        [[ -n "$year" ]] && TITLE="$TITLE ($year)"
        POSTER=$(jq -r '[.images[] | select(.coverType=="poster") | .remoteUrl][0] // empty' <<< "$j")
        OVERVIEW=$(jq -r '.overview // ""' <<< "$j")
        imdb=$(jq -r '.imdbId // empty' <<< "$j")
        LINK=${imdb:+https://www.imdb.com/title/$imdb/}
    fi
}

# --- dispatch ---

if [[ -n "${sonarr_eventtype:-}" ]]; then
    APP=sonarr
    EVENT="$sonarr_eventtype"
    DL_ID="${sonarr_download_id:-}"
    LABEL="${sonarr_instancename:-Sonarr}"
    ARR_PORT=8989
    MEDIA_ID="${sonarr_series_id:-}"
    QUALITY="${sonarr_release_quality:-}"
    EP_TITLES="${sonarr_release_episodetitles:-}"
    SEASON_NUM="${sonarr_release_seasonnumber:-}"
    EP_NUMS="${sonarr_release_episodenumbers:-}"
    EP_IDS="${sonarr_release_episodeids:-}"
    RELEASE_TITLE="${sonarr_release_title:-}"
    DL_CLIENT="${sonarr_download_client:-}"
    AVATAR="$SONARR_LOGO"
    if [[ "${LABEL,,}" == *anime* ]]; then
        COLOR=$SONARR_ANIME_COLOR
    else
        COLOR=$SONARR_COLOR
    fi
elif [[ -n "${radarr_eventtype:-}" ]]; then
    APP=radarr
    EVENT="$radarr_eventtype"
    DL_ID="${radarr_download_id:-}"
    LABEL="${radarr_instancename:-Radarr}"
    ARR_PORT=7878
    MEDIA_ID="${radarr_movie_id:-}"
    QUALITY="${radarr_release_quality:-}"
    RELEASE_TITLE="${radarr_release_title:-}"
    DL_CLIENT="${radarr_download_client:-}"
    AVATAR="$RADARR_LOGO"
    COLOR=$RADARR_COLOR
else
    exit 0
fi

ARR_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' /config/config.xml)
ARR_URL="http://localhost:${ARR_PORT}"

if [[ "$EVENT" == "Test" ]]; then
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    payload=$(jq -n \
        --arg u "$LABEL" --arg a "$AVATAR" \
        --arg t "$LABEL test notification" \
        --arg d "Hook is wired up. Real grab notifications post after a ${WAIT_SECONDS}s delay." \
        --argjson color "$COLOR" --arg ts "$TIMESTAMP" \
        '{username:$u, avatar_url:$a,
          allowed_mentions:{parse:[]},
          embeds:[{title:$t, description:$d, color:$color, timestamp:$ts}]}')
    post_embed "$payload"
    exit 0
fi

[[ "$EVENT" == "Grab" ]] || exit 0
[[ -z "$DL_ID" ]] && exit 0

# Look up the grabbed history record to read releaseSource. Sonarr/Radarr write
# this record synchronously before firing the connection so it should be there.
HISTORY=$(arr_get "$ARR_URL/api/v3/history?downloadId=$(urlencode "$DL_ID")&pageSize=50")
RELEASE_SOURCE=$(jq -r '[.records[] | select(.eventType=="grabbed")][0].data.releaseSource // "Unknown"' <<< "$HISTORY")

# Drop manual grabs — user already knows they searched.
case "$RELEASE_SOURCE" in
    Rss|Search|ReleasePush|Unknown) ;;
    *) exit 0 ;;
esac

sleep "$WAIT_SECONDS"

# Re-query history after the wait to see what happened.
HISTORY=$(arr_get "$ARR_URL/api/v3/history?downloadId=$(urlencode "$DL_ID")&pageSize=50")
IMPORTED=$(jq '[.records[] | select(.eventType=="downloadFolderImported")] | length' <<< "$HISTORY")

if (( IMPORTED > 0 )); then
    # Replaced an existing file → upgrade, stay silent.
    UPGRADE_COUNT=$(jq '[.records[] | select(.eventType=="episodeFileDeletedForUpgrade" or .eventType=="movieFileDeletedForUpgrade")] | length' <<< "$HISTORY")
    (( UPGRADE_COUNT > 0 )) && exit 0

    fetch_media "$APP" "$MEDIA_ID"

    if [[ "$APP" == "sonarr" ]]; then
        # Prefer the episode overview over the series overview.
        EP_ID="${EP_IDS%%,*}"
        if [[ -n "$EP_ID" ]]; then
            EP_OVERVIEW=$(arr_get "$ARR_URL/api/v3/episode/$(urlencode "$EP_ID")" | jq -r '.overview // ""')
            [[ -n "$EP_OVERVIEW" ]] && OVERVIEW="$EP_OVERVIEW"
        fi
        EP_LABEL=""
        if [[ -n "$SEASON_NUM" && -n "$EP_NUMS" ]]; then
            EP_LABEL=$(printf "S%02dE%s" "$SEASON_NUM" "$EP_NUMS")
        fi
        EMBED_TITLE="$TITLE"
        [[ -n "$EP_LABEL" ]] && EMBED_TITLE="$EMBED_TITLE · $EP_LABEL"
        EP_TITLES_DISPLAY="${EP_TITLES//|/, }"
        [[ -n "$EP_TITLES_DISPLAY" ]] && EMBED_TITLE="$EMBED_TITLE — $EP_TITLES_DISPLAY"
    else
        EMBED_TITLE="$TITLE"
    fi

    OVERVIEW=$(printf '%s' "$OVERVIEW" | first_sentence)
    EMBED_TITLE=$(cap 256 "$EMBED_TITLE")
    OVERVIEW=$(cap 4096 "$OVERVIEW")
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    payload=$(jq -n \
        --arg u "$LABEL" --arg a "$AVATAR" \
        --arg t "$EMBED_TITLE" --arg d "$OVERVIEW" --arg l "${LINK:-}" \
        --arg poster "${POSTER:-}" \
        --arg quality "${QUALITY:-unknown}" --arg source "$RELEASE_SOURCE" \
        --arg ts "$TIMESTAMP" \
        --argjson color "$COLOR" \
        '{
            username: $u,
            avatar_url: $a,
            allowed_mentions: {parse: []},
            embeds: [{
                title: $t,
                description: (if $d == "" then null else $d end),
                url: (if $l == "" then null else $l end),
                color: $color,
                timestamp: $ts,
                thumbnail: (if $poster == "" then null else {url:$poster} end),
                footer: {text: ($u + " · Imported")},
                fields: [
                    {name:"Quality", value:$quality, inline:true},
                    {name:"Source",  value:$source,  inline:true}
                ]
            } | with_entries(select(.value != null))]
        }')
    post_embed "$payload"
    exit 0
fi

# Not imported. Look at the queue to decide whether it's stuck or still working.
QUEUE=$(arr_get "$ARR_URL/api/v3/queue?includeUnknownSeriesItems=true&page=1&pageSize=500")
ENTRY=$(jq --arg id "$DL_ID" '[.records[] | select(.downloadId == $id)][0] // empty' <<< "$QUEUE")

# Not in queue and not imported — torrent removed or some other oddity. Silent.
[[ -z "$ENTRY" ]] && exit 0

TRACKED_STATUS=$(jq -r '.trackedDownloadStatus // ""' <<< "$ENTRY")

# Only complain if the queue itself flags trouble. "ok" with state=downloading
# means the torrent is still in progress — leave it alone.
case "$TRACKED_STATUS" in
    warning|error) ;;
    *) exit 0 ;;
esac

REASON=$(jq -r '
    ([(.statusMessages // [])[] | (.messages // [])[]] | unique | join("; ")) as $m |
    if ($m | length) > 0 then $m
    elif (.errorMessage // "") != "" then .errorMessage
    else "Downloaded but not imported (queue gives no detail)" end
' <<< "$ENTRY")

fetch_media "$APP" "$MEDIA_ID"
[[ -z "$TITLE" ]] && TITLE="${RELEASE_TITLE:-Unknown release}"

EMBED_TITLE=$(cap 256 "Failed to import — $TITLE")
REASON=$(cap 4096 "$REASON")
RELEASE_TITLE=$(cap 1024 "${RELEASE_TITLE:-unknown}")
DL_CLIENT=$(cap 1024 "${DL_CLIENT:-unknown}")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

payload=$(jq -n \
    --arg u "$LABEL" --arg a "$AVATAR" \
    --arg t "$EMBED_TITLE" --arg d "$REASON" \
    --arg release "$RELEASE_TITLE" --arg client "$DL_CLIENT" \
    --arg poster "${POSTER:-}" \
    --argjson color "$WARN_COLOR" --arg ts "$TIMESTAMP" \
    '{username:$u, avatar_url:$a,
      allowed_mentions:{parse:[]},
      embeds:[{
        title:$t, description:$d, color:$color, timestamp:$ts,
        thumbnail: (if $poster == "" then null else {url:$poster} end),
        footer: {text: ($u + " · Action required")},
        fields: [
            {name:"Release", value:$release, inline:false},
            {name:"Client",  value:$client,  inline:true}
        ]
      } | with_entries(select(.value != null))]}')

post_embed "$payload"
