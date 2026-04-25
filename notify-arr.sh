#!/bin/bash
# Forwards arr import + manual-interaction events to Discord with rich embeds.
# Imports are filtered to automated grabs only (RSS / scheduled search / release
# push); manual grabs are suppressed. ManualInteractionRequired always posts —
# reason is fetched from the queue API since Sonarr/Radarr don't pass it as env.

set -u

SONARR_LOGO="https://raw.githubusercontent.com/Sonarr/Sonarr/main/Logo/256.png"
RADARR_LOGO="https://raw.githubusercontent.com/Radarr/Radarr/develop/Logo/256.png"
SONARR_COLOR=3589616        # #35C5F0 — cyan, regular Sonarr
SONARR_ANIME_COLOR=10181046 # #9B59B6 — purple, Sonarr Anime instance
RADARR_COLOR=16761904       # #FFC230
WARN_COLOR=15548997         # #ED4245 — Discord red, used for manual-interaction alerts

ENV_FILE="$(dirname "$0")/arr-notify.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
: "${WEBHOOK:?WEBHOOK must be set via $ENV_FILE}"

CURL_OPTS=(-s --max-time 10)

# --- helpers ---

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# Truncate to at most $1 chars; append ellipsis if cut. Safe for non-ASCII since
# bash ${s:0:n} counts bytes, but Discord's limit is codepoints — slightly
# conservative is fine.
cap() {
    local max="$1" s="$2"
    if (( ${#s} <= max )); then
        printf '%s' "$s"
    else
        printf '%s…' "${s:0:max-1}"
    fi
}

# One-sentence summary: keep up to first . ! or ? (cap ~240 chars).
first_sentence() {
    awk -v max=240 'BEGIN{RS="\0"} {
        t=$0; gsub(/[[:space:]]+/," ",t); sub(/^ /,"",t); sub(/ $/,"",t);
        if (match(t, /[.!?]/)) t=substr(t,1,RSTART);
        if (length(t) > max) t=substr(t,1,max-1) "…";
        print t
    }'
}

arr_get() {
    curl "${CURL_OPTS[@]}" -H "X-Api-Key: $ARR_KEY" "$1"
}

post_embed() {
    curl "${CURL_OPTS[@]}" -o /dev/null -X POST \
        -H "Content-Type: application/json" \
        --data "$1" "$WEBHOOK"
}

# Populate TITLE, POSTER, OVERVIEW, LINK from the series/movie API. Sonarr
# returns series metadata; Radarr returns movie metadata with a year appended
# to TITLE.
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
    QUALITY="${sonarr_episodefile_quality:-${sonarr_release_quality:-}}"
    EP_TITLES="${sonarr_episodefile_episodetitles:-${sonarr_release_episodetitles:-}}"
    SEASON_NUM="${sonarr_episodefile_seasonnumber:-${sonarr_release_seasonnumber:-}}"
    EP_NUMS="${sonarr_episodefile_episodenumbers:-${sonarr_release_episodenumbers:-}}"
    AVATAR="$SONARR_LOGO"
    # Distinguish the anime instance by embed color (instance name is set in Sonarr settings).
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
    QUALITY="${radarr_moviefile_quality:-${radarr_release_quality:-}}"
    AVATAR="$RADARR_LOGO"
    COLOR=$RADARR_COLOR
else
    exit 0
fi

ARR_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' /config/config.xml)
ARR_URL="http://localhost:${ARR_PORT}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ "$EVENT" == "Test" ]]; then
    payload=$(jq -n \
        --arg u "$LABEL" --arg a "$AVATAR" \
        --arg t "$LABEL test notification" \
        --arg d "Filter script is wired up and the Discord webhook works. Real notifications will include a poster and fanart." \
        --argjson color "$COLOR" --arg ts "$TIMESTAMP" \
        '{username:$u, avatar_url:$a,
          allowed_mentions:{parse:[]},
          embeds:[{title:$t, description:$d, color:$color, timestamp:$ts}]}')
    post_embed "$payload"
    exit 0
fi

# Manual-interaction branch: posts an alert with the reason from the queue.
# Fires when Sonarr/Radarr downloaded something but couldn't import it
# automatically (unmatched file, not-an-upgrade, missing episode, etc.)
if [[ "$EVENT" == "ManualInteractionRequired" ]]; then
    [[ -z "$DL_ID" ]] && exit 0

    QUEUE=$(arr_get "$ARR_URL/api/v3/queue?includeUnknownSeriesItems=true&page=1&pageSize=500")
    REASON=$(jq -r --arg id "$DL_ID" '
        [.records[] | select(.downloadId == $id)][0] as $r |
        if $r == null then "No matching queue entry"
        else
            ([($r.statusMessages // [])[] | (.messages // [])[]] | unique | join("; ")) as $msgs |
            if ($msgs | length) > 0 then $msgs
            elif ($r.errorMessage // "") != "" then $r.errorMessage
            else "Manual import required (no detail from queue)" end
        end' <<< "$QUEUE")

    RELEASE_TITLE="${sonarr_download_title:-${radarr_download_title:-}}"
    DL_CLIENT="${sonarr_download_client:-${radarr_download_client:-}}"

    fetch_media "$APP" "$MEDIA_ID"
    [[ -z "$TITLE" ]] && TITLE="${RELEASE_TITLE:-Unknown release}"

    EMBED_TITLE=$(cap 256 "Manual import needed — $TITLE")
    REASON=$(cap 4096 "$REASON")
    RELEASE_TITLE=$(cap 1024 "${RELEASE_TITLE:-unknown}")
    DL_CLIENT=$(cap 1024 "${DL_CLIENT:-unknown}")

    payload=$(jq -n \
        --arg u "$LABEL" --arg a "$AVATAR" \
        --arg t "$EMBED_TITLE" \
        --arg d "$REASON" \
        --arg release "$RELEASE_TITLE" \
        --arg client "$DL_CLIENT" \
        --arg poster "${POSTER:-}" \
        --argjson color "$WARN_COLOR" --arg ts "$TIMESTAMP" \
        '{username:$u, avatar_url:$a,
          allowed_mentions:{parse:[]},
          embeds:[{
            title:$t,
            description:$d,
            color:$color,
            timestamp:$ts,
            thumbnail: (if $poster == "" then null else {url:$poster} end),
            footer: {text: ($u + " · Manual interaction required")},
            fields: [
                {name:"Release", value:$release, inline:false},
                {name:"Client",  value:$client,  inline:true}
            ]
          } | with_entries(select(.value != null))]}')
    post_embed "$payload"
    exit 0
fi

case "$EVENT" in
    Download) ;;
    *) exit 0 ;;
esac

# Filter on grab source — only notify for automated grabs.
if [[ -n "$DL_ID" ]]; then
    HISTORY=$(arr_get "$ARR_URL/api/v3/history?downloadId=$(urlencode "$DL_ID")&pageSize=50")
    SOURCE=$(jq -r '[.records[] | select(.eventType=="grabbed")][0].data.releaseSource // "Unknown"' <<< "$HISTORY")
else
    exit 0
fi

case "$SOURCE" in
    Rss|Search|ReleasePush|Unknown) ;;
    *) exit 0 ;;
esac

# Upgrade detection: env var is only set on OnDownload, not OnImportComplete.
# Fall back to history — any *FileDeletedForUpgrade record for this downloadId
# means the import replaced an existing file.
IS_UPGRADE="${sonarr_isupgrade:-${radarr_isupgrade:-}}"
if [[ -z "$IS_UPGRADE" ]]; then
    UPGRADE_COUNT=$(jq '[.records[] | select(.eventType=="episodeFileDeletedForUpgrade" or .eventType=="movieFileDeletedForUpgrade")] | length' <<< "$HISTORY")
    [[ "${UPGRADE_COUNT:-0}" -gt 0 ]] && IS_UPGRADE="True" || IS_UPGRADE="False"
fi

fetch_media "$APP" "$MEDIA_ID"

# For Sonarr, prefer the episode overview over the series overview.
if [[ "$APP" == "sonarr" ]]; then
    EP_ID="${sonarr_episodefile_episodeids:-}"
    EP_ID="${EP_ID%%,*}"
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
    # Sonarr pipe-joins episode titles on OnImportComplete; render as a list.
    EP_TITLES_DISPLAY="${EP_TITLES//|/, }"
    [[ -n "$EP_TITLES_DISPLAY" ]] && EMBED_TITLE="$EMBED_TITLE — $EP_TITLES_DISPLAY"
else
    EMBED_TITLE="$TITLE"
fi

OVERVIEW=$(printf '%s' "$OVERVIEW" | first_sentence)
EMBED_TITLE=$(cap 256 "$EMBED_TITLE")
OVERVIEW=$(cap 4096 "$OVERVIEW")

EVENT_LABEL="Imported"
[[ "$IS_UPGRADE" == "True" ]] && EVENT_LABEL="Upgraded"

payload=$(jq -n \
    --arg u "$LABEL" --arg a "$AVATAR" \
    --arg t "$EMBED_TITLE" --arg d "$OVERVIEW" --arg l "${LINK:-}" \
    --arg poster "${POSTER:-}" \
    --arg quality "${QUALITY:-unknown}" --arg source "$SOURCE" \
    --arg event "$EVENT_LABEL" --arg ts "$TIMESTAMP" \
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
            footer: {text: ($u + " · " + $event)},
            fields: [
                {name:"Quality", value:$quality, inline:true},
                {name:"Source",  value:$source,  inline:true}
            ]
        } | with_entries(select(.value != null))]
    }')

post_embed "$payload"
