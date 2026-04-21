#!/bin/bash
# Forwards arr "on import / on upgrade" events to Discord with rich embeds,
# but only when the underlying grab was automated (RSS sync, scheduled search,
# release push). Manual grabs are suppressed.

set -u

SONARR_LOGO="https://raw.githubusercontent.com/Sonarr/Sonarr/main/Logo/256.png"
RADARR_LOGO="https://raw.githubusercontent.com/Radarr/Radarr/develop/Logo/256.png"
SONARR_COLOR=3589616   # #35C5F0
RADARR_COLOR=16761904  # #FFC230

ENV_FILE="$(dirname "$0")/notify-discord.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
: "${WEBHOOK:?WEBHOOK must be set via $ENV_FILE}"

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
    COLOR=$SONARR_COLOR
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

post_embed() {
    local json="$1"
    curl -s -o /dev/null -X POST -H "Content-Type: application/json" \
        --data "$json" "$WEBHOOK"
}

if [[ "$EVENT" == "Test" ]]; then
    payload=$(jq -n \
        --arg u "$LABEL" --arg a "$AVATAR" \
        --arg t "$LABEL test notification" \
        --arg d "Filter script is wired up and the Discord webhook works. Real notifications will include a poster and fanart." \
        --argjson color "$COLOR" --arg ts "$TIMESTAMP" \
        '{username:$u, avatar_url:$a,
          embeds:[{title:$t, description:$d, color:$color, timestamp:$ts}]}')
    post_embed "$payload"
    exit 0
fi

case "$EVENT" in
    Download) ;;
    *) exit 0 ;;
esac

IS_UPGRADE="${sonarr_isupgrade:-${radarr_isupgrade:-False}}"

# Filter on grab source — only notify for automated grabs
if [[ -n "$DL_ID" ]]; then
    SOURCE=$(curl -s -H "X-Api-Key: $ARR_KEY" \
        "$ARR_URL/api/v3/history?downloadId=$DL_ID&pageSize=50" \
        | jq -r '[.records[] | select(.eventType=="grabbed")][0].data.releaseSource // "Unknown"')
else
    exit 0
fi

case "$SOURCE" in
    Rss|Search|ReleasePush|Unknown) ;;
    *) exit 0 ;;
esac

# One-sentence summary: keep up to first . ! or ? (cap ~240 chars)
first_sentence() {
    awk -v max=240 'BEGIN{RS="\0"} {
        t=$0; gsub(/[[:space:]]+/," ",t); sub(/^ /,"",t); sub(/ $/,"",t);
        if (match(t, /[.!?]/)) t=substr(t,1,RSTART);
        if (length(t) > max) t=substr(t,1,max-1) "…";
        print t
    }'
}

# Fetch media details for poster / overview / link
if [[ "$APP" == "sonarr" ]]; then
    MEDIA=$(curl -s -H "X-Api-Key: $ARR_KEY" "$ARR_URL/api/v3/series/$MEDIA_ID")
    TITLE=$(jq -r '.title // "Unknown series"' <<< "$MEDIA")
    POSTER=$(jq -r '[.images[] | select(.coverType=="poster") | .remoteUrl][0] // empty' <<< "$MEDIA")
    TVDB=$(jq -r '.tvdbId // empty' <<< "$MEDIA")
    LINK=${TVDB:+https://www.thetvdb.com/?tab=series&id=$TVDB}

    # Prefer episode overview over series overview
    EP_ID="${sonarr_episodefile_episodeids:-}"
    EP_ID="${EP_ID%%,*}"   # first id if multi
    OVERVIEW=""
    if [[ -n "$EP_ID" ]]; then
        OVERVIEW=$(curl -s -H "X-Api-Key: $ARR_KEY" "$ARR_URL/api/v3/episode/$EP_ID" | jq -r '.overview // ""')
    fi
    [[ -z "$OVERVIEW" ]] && OVERVIEW=$(jq -r '.overview // ""' <<< "$MEDIA")

    EP_LABEL=""
    if [[ -n "$SEASON_NUM" && -n "$EP_NUMS" ]]; then
        EP_LABEL=$(printf "S%02dE%s" "$SEASON_NUM" "$EP_NUMS")
    fi
    EMBED_TITLE="$TITLE"
    [[ -n "$EP_LABEL" ]] && EMBED_TITLE="$EMBED_TITLE · $EP_LABEL"
    [[ -n "$EP_TITLES" ]] && EMBED_TITLE="$EMBED_TITLE — $EP_TITLES"
else
    MEDIA=$(curl -s -H "X-Api-Key: $ARR_KEY" "$ARR_URL/api/v3/movie/$MEDIA_ID")
    TITLE=$(jq -r '.title // "Unknown movie"' <<< "$MEDIA")
    YEAR=$(jq -r '.year // empty' <<< "$MEDIA")
    OVERVIEW=$(jq -r '.overview // ""' <<< "$MEDIA")
    POSTER=$(jq -r '[.images[] | select(.coverType=="poster") | .remoteUrl][0] // empty' <<< "$MEDIA")
    IMDB=$(jq -r '.imdbId // empty' <<< "$MEDIA")
    LINK=${IMDB:+https://www.imdb.com/title/$IMDB/}
    EMBED_TITLE="$TITLE${YEAR:+ ($YEAR)}"
fi

OVERVIEW=$(printf '%s' "$OVERVIEW" | first_sentence)

EVENT_LABEL="Imported"
[[ "$IS_UPGRADE" == "True" ]] && EVENT_LABEL="Upgraded"

# Assemble the embed
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
