#!/usr/bin/env bash
# vernissage-migrator.sh
# Copyright (c) 2026 Oliver Pifferi, E-Mail: oliver@pifferi.io
# ---------------------
# Migrates user data between two Vernissage instances.
# Dependencies: curl, jq
#
# Usage:
#   chmod +x vernissage-migrator.sh
#   ./vernissage-migrator.sh export --source https://source-instance.example --user myuser --token "eyJ..."
#   ./vernissage-migrator.sh import --target https://new-instance.example --user myuser --token "eyJ..."
#   ./vernissage-migrator.sh cors   --s3-endpoint https://your.s3.endpoint.tld\
#                                  --s3-bucket vernissage-assets \
#                                  --s3-key ACCESSKEY --s3-secret SECRETKEY \
#                                  --origin https://new-instance.example

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

EXPORT_DIR="vernissage_export"
# Ensure absolute path (also works when EXPORT_DIR is passed via environment variable)
if [[ "${EXPORT_DIR}" != /* ]]; then
    EXPORT_DIR="$(pwd)/${EXPORT_DIR}"
fi

REQUEST_DELAY=0.5   # Seconds between API calls
DEBUG=0             # Set to 1 for verbose curl output

# Hashtag mapping: entries of the form "#old=#new"
# Example: HASHTAG_MAP=("#sourceinstance=#targetinstance")
HASHTAG_MAP=()

# Profile overrides (empty = take value from export)
OVERRIDE_DISPLAYNAME=""
OVERRIDE_BIO=""

# Resume file: stores already imported status IDs
RESUME_FILE="${EXPORT_DIR}/.imported_ids"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

check_deps() {
    local missing=()
    for cmd in curl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing required tools: ${missing[*]}"
        echo "  Debian/Ubuntu: sudo apt install curl jq"
        echo "  macOS:         brew install jq"
        exit 1
    fi
}

rdelay() { sleep "$REQUEST_DELAY"; }

apply_hashtag_map() {
    local text="$1"
    for mapping in "${HASHTAG_MAP[@]+"${HASHTAG_MAP[@]}"}"; do
        local old="${mapping%%=*}"
        local new="${mapping#*=}"
        text="${text//$old/$new}"
    done
    echo "$text"
}

json_escape() {
    printf '%s' "$1" | jq -Rs .
}

# Check whether a status ID has already been imported
is_imported() {
    local sid="$1"
    [[ -f "$RESUME_FILE" ]] && grep -qF "$sid" "$RESUME_FILE"
}

# Mark a status ID as imported
mark_imported() {
    local sid="$1"
    echo "$sid" >> "$RESUME_FILE"
}

# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------

API_TOKEN=""
API_BASE=""

api_login() {
    local base="$1" user="$2" pass="$3"
    API_BASE="${base%/}/api/v1"
    echo "  Logging in to ${base} as '${user}' ..."
    rdelay

    local curl_debug_flags=()
    [[ "$DEBUG" -eq 1 ]] && curl_debug_flags=(-v)

    local http_code body tmpfile
    tmpfile=$(mktemp)
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        "${curl_debug_flags[@]+"${curl_debug_flags[@]}"}" \
        -X POST "${API_BASE}/account/login" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{\"userNameOrEmail\":$(json_escape "$user"),\"password\":$(json_escape "$pass")}")
    body=$(cat "$tmpfile"); rm -f "$tmpfile"

    if [[ "$http_code" -ne 200 ]]; then
        echo ""
        echo "  ✗ Login failed (HTTP ${http_code}): ${body}"
        echo ""
        echo "  Hint: For OAuth-only instances (login via Mastodon/Apple/Google)"
        echo "        grab the token from browser DevTools and use --token instead."
        exit 1
    fi

    API_TOKEN=$(echo "$body" | jq -r '.accessToken // empty')
    if [[ -z "$API_TOKEN" ]]; then
        echo "  ✗ No accessToken in response: ${body}"
        exit 1
    fi
    echo "  ✓ Login successful."
}

api_get() {
    local path="$1"; shift
    rdelay
    curl -sf "${API_BASE}/${path}" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "$@" || true
}

api_get_paginated() {
    local path="$1"
    local all="[]"
    local max_id=""
    local limit=20

    while true; do
        local params="limit=${limit}"
        [[ -n "$max_id" ]] && params="${params}&maxId=${max_id}"
        rdelay
        local page
        page=$(curl -sf "${API_BASE}/${path}?${params}" \
            -H "Accept: application/json" \
            -H "Authorization: Bearer ${API_TOKEN}" || echo "[]")

        local items
        if echo "$page" | jq -e 'type == "array"' &>/dev/null; then
            items="$page"
        else
            items=$(echo "$page" | jq '.data // .items // []')
        fi

        local count
        count=$(echo "$items" | jq 'length')
        [[ "$count" -eq 0 ]] && break

        all=$(echo "$all $items" | jq -s 'add')
        [[ "$count" -lt "$limit" ]] && break
        max_id=$(echo "$items" | jq -r '.[-1].id // empty')
        [[ -z "$max_id" ]] && break
    done

    echo "$all"
}

api_put() {
    local path="$1" data="$2"
    rdelay
    curl -sf -X PUT "${API_BASE}/${path}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -d "$data" || true
}

api_post_json() {
    local path="$1" data="$2"
    rdelay
    local tmpfile http_code body
    tmpfile=$(mktemp)
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        -X POST "${API_BASE}/${path}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -d "$data")
    body=$(cat "$tmpfile"); rm -f "$tmpfile"
    if [[ "$http_code" -eq 429 ]]; then
        # Rate limit – return body so caller can read waitSeconds
        echo "$body"
    elif [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        echo "  ✗ POST ${path} → HTTP ${http_code}: ${body}" >&2
        echo ""
    else
        echo "$body"
    fi
}

api_post_multipart() {
    local path="$1"; shift
    rdelay
    local tmpfile http_code body
    tmpfile=$(mktemp)
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        -X POST "${API_BASE}/${path}" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "$@")
    body=$(cat "$tmpfile"); rm -f "$tmpfile"
    if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        echo "  ✗ POST ${path} → HTTP ${http_code}: ${body}" >&2
        echo ""
    else
        echo "$body"
    fi
}

# ---------------------------------------------------------------------------
# CORS configuration
# ---------------------------------------------------------------------------

do_cors() {
    local endpoint="$1" bucket="$2" key="$3" secret="$4" origin="$5"

    echo "=== CORS Configuration for ${bucket} ==="
    echo ""

    if ! command -v aws &>/dev/null; then
        echo "  ✗ AWS CLI not found."
        echo ""
        echo "  Install it:"
        echo "    macOS:         brew install awscli"
        echo "    Debian/Ubuntu: sudo apt install awscli"
        echo "    Or:            pip install awscli"
        echo ""
        echo "  Alternative: set CORS manually via the Hetzner console."
        exit 1
    fi

    local cors_config
    cors_config=$(jq -n \
        --arg origin "$origin" \
        '{
            CORSRules: [{
                AllowedOrigins: [$origin],
                AllowedMethods: ["GET", "HEAD"],
                AllowedHeaders: ["*"],
                MaxAgeSeconds: 3600
            }]
        }')

    echo "  Setting CORS for origin: ${origin}"
    AWS_ACCESS_KEY_ID="$key" \
    AWS_SECRET_ACCESS_KEY="$secret" \
    aws s3api put-bucket-cors \
        --bucket "$bucket" \
        --cors-configuration "$cors_config" \
        --endpoint-url "$endpoint" \
        --region us-east-1 2>&1

    echo ""
    echo "  Verifying CORS headers ..."
    local cors_check
    cors_check=$(curl -sI "${endpoint}/${bucket}/" \
        -H "Origin: ${origin}" | grep -i "access-control" || true)

    if [[ -n "$cors_check" ]]; then
        echo "  ✓ CORS is active:"
        echo "$cors_check" | sed 's/^/    /'
    else
        echo "  ⚠ CORS headers not yet visible – may become active after the first request."
        echo "  Test with:"
        echo "  curl -sI \"${endpoint}/${bucket}/\" -H \"Origin: ${origin}\" | grep -i access-control"
    fi
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

do_export() {
    local source_url="$1" username="$2"
    mkdir -p "${EXPORT_DIR}/photos"

    echo ""
    echo "[1/4] Fetching profile ..."
    local profile
    profile=$(api_get "users/${username}")
    if [[ -z "$profile" || "$(echo "$profile" | jq -r '.account // empty')" == "" ]]; then
        echo "  ✗ Could not load profile: ${profile}"
        echo "  Hint: Token expired? Grab a fresh one from browser DevTools."
        exit 1
    fi
    echo "$profile" > "${EXPORT_DIR}/profile.json"
    echo "  ✓ $(echo "$profile" | jq -r '.account // .userName')"

    local account_id
    account_id=$(echo "$profile" | jq -r '.id // empty')
    if [[ -z "$account_id" ]]; then
        echo "  ✗ No ID found in profile."; exit 1
    fi

    echo ""
    echo "[2/4] Fetching statuses (photos) ..."
    local statuses
    statuses=$(api_get_paginated "users/${username}/statuses")
    local count
    count=$(echo "$statuses" | jq 'length')
    echo "  ${count} statuses found."

    local updated_statuses="$statuses"
    while IFS= read -r status_json; do
        local sid
        sid=$(echo "$status_json" | jq -r '.id')
        local att_index=0

        while IFS= read -r att_json; do
            local url
            url=$(echo "$att_json" | jq -r '.originalFile.url // .smallFile.url // .url // empty')
            if [[ -n "$url" ]]; then
                local ext="${url##*.}"
                ext="${ext%%\?*}"
                ext="${ext:0:4}"
                local fname
                fname="${EXPORT_DIR}/photos/${sid}_${att_index}.${ext}"
                if curl -sfL -o "$fname" "$url"; then
                    echo "  Photo: ${fname##*/}"
                    updated_statuses=$(echo "$updated_statuses" | jq \
                        --arg sid "$sid" \
                        --argjson idx "$att_index" \
                        --arg lf "$fname" \
                        '(.[] | select(.id == $sid) | .attachments[$idx]._local_file) |= $lf')
                else
                    echo "  ✗ Download failed: ${url}"
                fi
                att_index=$((att_index + 1))
            fi
        done < <(echo "$status_json" | jq -c '.attachments[]? // empty')

    done < <(echo "$statuses" | jq -c '.[]')

    echo "$updated_statuses" | jq '.' > "${EXPORT_DIR}/statuses.json"

    echo ""
    echo "[3/4] Fetching following list ..."
    local following
    following=$(api_get_paginated "users/${username}/following")
    echo "$following" > "${EXPORT_DIR}/following.json"
    echo "  $(echo "$following" | jq 'length') accounts."

    echo ""
    echo "[4/4] Fetching followers list ..."
    local followers
    followers=$(api_get_paginated "users/${username}/followers")
    echo "$followers" > "${EXPORT_DIR}/followers.json"
    echo "  $(echo "$followers" | jq 'length') followers."

    echo ""
    echo "✓ Export complete → ${EXPORT_DIR}"
}

# ---------------------------------------------------------------------------
# Registration (open instances only)
# ---------------------------------------------------------------------------

check_or_register() {
    local base="$1" username="$2" email="$3" password="$4"
    API_BASE="${base%/}/api/v1"

    echo "  Checking whether account '${username}' exists on ${base} ..."

    local http_code body tmpfile
    tmpfile=$(mktemp)
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        -X POST "${API_BASE}/account/login" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{\"userNameOrEmail\":$(json_escape "$username"),\"password\":$(json_escape "$password")}")
    body=$(cat "$tmpfile"); rm -f "$tmpfile"

    if [[ "$http_code" -eq 200 ]]; then
        API_TOKEN=$(echo "$body" | jq -r '.accessToken // empty')
        echo "  ✓ Login successful."
        return 0
    fi

    if [[ "$http_code" -eq 400 ]]; then
        local error_code
        error_code=$(echo "$body" | jq -r '.code // empty')
        if [[ "$error_code" == "invalidLoginCredentials" ]]; then
            local profile_code
            profile_code=$(curl -s -o /dev/null -w "%{http_code}" "${API_BASE}/users/${username}")
            if [[ "$profile_code" -eq 200 ]]; then
                echo "  ✗ Account '${username}' exists but password is wrong."
                echo "  Please check your password or use --token instead."
                exit 1
            else
                echo "  Account '${username}' not found (HTTP ${profile_code}), attempting registration ..."
            fi
        else
            echo "  Login failed (HTTP 400, code: ${error_code}), attempting registration ..."
        fi
    else
        echo "  Account not reachable (HTTP ${http_code}), attempting registration ..."
    fi

    local reg_body
    reg_body=$(jq -n \
        --arg u "$username" --arg e "$email" \
        --arg p "$password" --arg r "$base" \
        '{userName: $u, email: $e, password: $p, redirectBaseUrl: $r,
          agreement: true, emailNotifications: false, locale: "en_US"}')

    tmpfile=$(mktemp)
    for reg_ep in "account/register" "register"; do
        http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
            -X POST "${API_BASE}/${reg_ep}" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "$reg_body")
        body=$(cat "$tmpfile")
        [[ "$http_code" -eq 404 ]] && continue

        if [[ "$http_code" -eq 403 ]]; then
            echo "  ✗ Instance is closed (HTTP 403) – registration not possible."
            echo "  → Ask the admin to create the account, then import using --token."
            rm -f "$tmpfile"; exit 1
        fi

        local failures
        failures=$(echo "$body" | jq -r '.failures[]?.field // empty' 2>/dev/null)
        if echo "$failures" | grep -q "securityToken"; then
            echo "  ✗ Instance requires CAPTCHA – automatic registration not possible."
            echo ""
            echo "  Please register manually:"
            echo "    1. Open ${base} in your browser and create an account"
            echo "    2. Confirm your email and log in"
            echo "    3. Grab the token from DevTools (F12 → Network → Authorization: Bearer eyJ...)"
            echo "    4. Re-run the import using --token"
            rm -f "$tmpfile"; exit 1
        fi

        if [[ "$http_code" -eq 200 || "$http_code" -eq 201 ]]; then
            echo "  ✓ Account registered."
            echo "  → Confirm the email sent to '${email}', then re-run import using --token."
            rm -f "$tmpfile"; exit 0
        fi

        echo "  ✗ Registration failed (HTTP ${http_code}): ${body}"
        rm -f "$tmpfile"; exit 1
    done

    rm -f "$tmpfile"
    echo "  ✗ No registration endpoint found."
    echo "  → Ask the admin to create account '${username}' manually."
    exit 1
}

# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------

do_import() {
    local target_url="$1" username="$2"

    if [[ ! -d "$EXPORT_DIR" ]]; then
        echo "  ✗ Export directory '${EXPORT_DIR}' not found."
        echo "  Run the script from the directory containing 'vernissage_export'."
        echo "  Or: EXPORT_DIR=/path/to/vernissage_export $0 import ..."
        exit 1
    fi

    # Resume mode: load already imported IDs
    local resume_count=0
    if [[ -f "$RESUME_FILE" ]]; then
        resume_count=$(wc -l < "$RESUME_FILE")
        echo "  ↩ Resume mode: ${resume_count} already imported statuses will be skipped."
    fi

    echo ""
    echo "[1/2] Updating profile ..."
    local profile
    profile=$(cat "${EXPORT_DIR}/profile.json")
    local name bio
    name="${OVERRIDE_DISPLAYNAME:-$(echo "$profile" | jq -r '.name // ""')}"
    local bio_raw
    bio_raw=$(echo "$profile" | jq -r '.bio // ""')
    bio=$(apply_hashtag_map "${OVERRIDE_BIO:-$bio_raw}")

    local profile_data
    profile_data=$(jq -n --arg n "$name" --arg b "$bio" '{name: $n, bio: $b}')
    if api_put "users/${username}" "$profile_data" | jq -e '.name' &>/dev/null; then
        echo "  ✓ Profile updated (name: ${name})."
    else
        echo "  ⚠ Profile update failed – please check manually."
    fi

    echo ""
    echo "[2/2] Uploading photos and publishing statuses ..."

    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Strip control characters and sort by date
    local clean_statuses
    clean_statuses=$(mktemp)
    tr -d '\000-\010\013\014\016-\037' < "${EXPORT_DIR}/statuses.json" > "$clean_statuses"
    jq -c 'sort_by(.createdAt) | .[]' "$clean_statuses" > "${tmp_dir}/all.ndjson"
    rm -f "$clean_statuses"

    local skipped=0 resumed=0 published=0 failed=0 total
    total=$(wc -l < "${tmp_dir}/all.ndjson")
    local current=0

    while IFS= read -r status_json; do
        current=$((current + 1))
        local sid
        sid=$(echo "$status_json" | jq -r '.id')

        # Resume: skip already imported statuses
        if is_imported "$sid"; then
            resumed=$((resumed + 1))
            echo "  [${current}/${total}] ↩ Skipped (already imported): ${sid}"
            continue
        fi

        local att_count
        att_count=$(echo "$status_json" | jq '.attachments | length')
        if [[ "$att_count" -eq 0 ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        echo "$status_json" | jq -c '.attachments[]' > "${tmp_dir}/atts.ndjson"

        local media_ids="[]"
        while IFS= read -r att_json; do
            local local_file
            local_file=$(echo "$att_json" | jq -r '._local_file // empty')
            if [[ -n "$local_file" && ! -f "$local_file" ]]; then
                local alt
                alt="$(dirname "$EXPORT_DIR")/$local_file"
                [[ -f "$alt" ]] && local_file="$alt"
            fi
            if [[ -z "$local_file" || ! -f "$local_file" ]]; then
                echo "  ✗ File missing: ${local_file:-'(no path)'}"; continue
            fi

            local desc
            desc=$(echo "$att_json" | jq -r '.description // ""')
            desc=$(apply_hashtag_map "$desc")

            local upload mid
            upload=$(api_post_multipart "attachments" \
                -F "file=@${local_file}" \
                -F "description=${desc}")
            mid=$(echo "$upload" | jq -r '.id // empty')

            if [[ -n "$mid" ]]; then
                echo "  [${current}/${total}] ↑ ${local_file##*/} → Attachment ${mid}"
                media_ids=$(echo "$media_ids" | jq --arg id "$mid" '. + [$id]')
                sleep 3
            else
                echo "  [${current}/${total}] ✗ Upload failed: ${local_file##*/}"
            fi
        done < "${tmp_dir}/atts.ndjson"

        local media_count
        media_count=$(echo "$media_ids" | jq 'length')
        if [[ "$media_count" -eq 0 ]]; then
            skipped=$((skipped + 1)); continue
        fi

        local note visibility sensitive comments_disabled post_data
        note=$(echo "$status_json" | jq -r '.note // ""')
        note=$(apply_hashtag_map "$note")
        visibility=$(echo "$status_json" | jq -r '.visibility // "public"')
        sensitive=$(echo "$status_json" | jq -r '.sensitive // false')
        comments_disabled=$(echo "$status_json" | jq -r '.commentsDisabled // false')
        post_data=$(jq -n \
            --arg note "$note" \
            --arg vis "$visibility" \
            --argjson sens "$sensitive" \
            --argjson cd "$comments_disabled" \
            --argjson mids "$media_ids" \
            '{note: $note, visibility: $vis, sensitive: $sens,
              commentsDisabled: $cd, attachmentIds: $mids}')

        local new_status new_id attempts=0 max_attempts=10
        while [[ $attempts -lt $max_attempts ]]; do
            new_status=$(api_post_json "statuses" "$post_data")
            new_id=$(echo "$new_status" | jq -r '.id // empty')
            if [[ -n "$new_id" ]]; then
                published=$((published + 1))
                mark_imported "$sid"
                echo "  [${current}/${total}] ✓ Status published: ${new_id}"
                break
            fi
            local wait_seconds
            wait_seconds=$(echo "$new_status" | jq -r '.parameters.waitSeconds // empty')
            if [[ -n "$wait_seconds" && "$wait_seconds" -gt 0 ]]; then
                echo "  [${current}/${total}] ⏳ Rate limit – waiting ${wait_seconds}s ..."
                sleep "$wait_seconds"
                attempts=$((attempts + 1))
            else
                echo "  [${current}/${total}] ✗ Status post failed: ${new_status}"
                failed=$((failed + 1))
                break
            fi
        done

    done < "${tmp_dir}/all.ndjson"

    rm -rf "$tmp_dir"
    echo ""
    echo "  ✓ Published: ${published} | ↩ Resumed: ${resumed} | Skipped: ${skipped} | ✗ Failed: ${failed}"
    echo ""
    echo "✓ Import complete."
    [[ -f "$RESUME_FILE" ]] && echo "  Resume file: ${RESUME_FILE}"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage:
  $0 export  --source URL --user NAME [--password PASS | --token TOKEN] [--debug]
  $0 import  --target URL --user NAME [--password PASS | --token TOKEN] [--email EMAIL] [--debug]
  $0 full    --source URL --source-user NAME --source-password PASS \\
              --target URL --target-user NAME --target-password PASS [--debug]
  $0 cors    --s3-endpoint URL --s3-bucket NAME --s3-key KEY --s3-secret SECRET --origin URL
  $0 gallery [--export-dir PATH]

Options:
  --password PASS   Password for direct login (only works with email+password accounts)
  --token TOKEN     Pass a Bearer token directly (recommended, always works)
                    Get the token: Browser → F12 → Network → any /api/v1/ request
                    → Request Headers → copy "Authorization: Bearer eyJ..."
  --email EMAIL     Email address for registration on the target instance (open instances only)
  --debug           Verbose curl output
  --export-dir PATH Path to export directory for the gallery subcommand (default: vernissage_export)

CORS configuration (run once before importing):
  $0 cors \\
    --s3-endpoint https://your.s3.endpoint.tld\\
    --s3-bucket vernissage-assets \\
    --s3-key ACCESSKEY \\
    --s3-secret SECRETKEY \\
    --origin https://new-instance.example

Resume after interruption:
  Successfully imported statuses are tracked in '${EXPORT_DIR}/.imported_ids'.
  Simply re-run the import command – already imported statuses will be skipped.
  To start fresh: rm ${EXPORT_DIR}/.imported_ids

Typical workflow:
  Export:           $0 export --source URL --user NAME --token "eyJ..."
  Set CORS:         $0 cors --s3-endpoint URL --s3-bucket NAME --s3-key K --s3-secret S --origin URL
  Import:           $0 import --target URL --user NAME --token "eyJ..."
  Resume:           $0 import --target URL --user NAME --token "eyJ..."  (just re-run)
EOF
    exit 1
}

[[ $# -lt 1 ]] && usage
MODE="$1"; shift

check_deps

case "$MODE" in
    export)
        SOURCE="" USER="" PASSWORD="" TOKEN=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --source)   SOURCE="$2";   shift 2 ;;
                --user)     USER="$2";     shift 2 ;;
                --password) PASSWORD="$2"; shift 2 ;;
                --token)    TOKEN="$2";    shift 2 ;;
                --debug)    DEBUG=1;       shift   ;;
                *) echo "Unknown option: $1"; usage ;;
            esac
        done
        [[ -z "$SOURCE" || -z "$USER" ]] && usage
        echo "=== EXPORT from ${SOURCE} ==="
        if [[ -n "$TOKEN" ]]; then
            API_BASE="${SOURCE%/}/api/v1"
            API_TOKEN="$TOKEN"
            echo "  Token provided directly."
        else
            [[ -z "$PASSWORD" ]] && usage
            api_login "$SOURCE" "$USER" "$PASSWORD"
        fi
        do_export "$SOURCE" "$USER"
        do_gallery "$EXPORT_DIR"
        ;;

    import)
        TARGET="" USER="" EMAIL="" PASSWORD="" TOKEN=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --target)   TARGET="$2";   shift 2 ;;
                --user)     USER="$2";     shift 2 ;;
                --email)    EMAIL="$2";    shift 2 ;;
                --password) PASSWORD="$2"; shift 2 ;;
                --token)    TOKEN="$2";    shift 2 ;;
                --debug)    DEBUG=1;       shift   ;;
                *) echo "Unknown option: $1"; usage ;;
            esac
        done
        [[ -z "$TARGET" || -z "$USER" ]] && usage
        echo "=== IMPORT to ${TARGET} ==="
        if [[ -n "$TOKEN" ]]; then
            API_BASE="${TARGET%/}/api/v1"
            API_TOKEN="$TOKEN"
            echo "  Token provided directly."
        elif [[ -n "$PASSWORD" ]]; then
            check_or_register "$TARGET" "$USER" "${EMAIL:-${USER}@${TARGET#*://}}" "$PASSWORD"
        else
            echo "  Error: --token or --password required."
            usage
        fi
        do_import "$TARGET" "$USER"
        ;;

    cors)
        S3_ENDPOINT="" S3_BUCKET="" S3_KEY="" S3_SECRET="" S3_ORIGIN=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --s3-endpoint) S3_ENDPOINT="$2"; shift 2 ;;
                --s3-bucket)   S3_BUCKET="$2";   shift 2 ;;
                --s3-key)      S3_KEY="$2";       shift 2 ;;
                --s3-secret)   S3_SECRET="$2";    shift 2 ;;
                --origin)      S3_ORIGIN="$2";    shift 2 ;;
                *) echo "Unknown option: $1"; usage ;;
            esac
        done
        [[ -z "$S3_ENDPOINT" || -z "$S3_BUCKET" || -z "$S3_KEY" || \
           -z "$S3_SECRET"   || -z "$S3_ORIGIN" ]] && usage
        do_cors "$S3_ENDPOINT" "$S3_BUCKET" "$S3_KEY" "$S3_SECRET" "$S3_ORIGIN"
        ;;

    gallery)
        GDIR=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --export-dir) GDIR="$2"; shift 2 ;;
                *) echo "Unknown option: $1"; usage ;;
            esac
        done
        GDIR="${GDIR:-$EXPORT_DIR}"
        if [[ "${GDIR}" != /* ]]; then GDIR="$(pwd)/${GDIR}"; fi
        echo "=== GALLERY from ${GDIR} ==="
        do_gallery "$GDIR"
        ;;

    full)
        SOURCE="" SRC_USER="" SRC_PASS="" TARGET="" TGT_USER="" TGT_PASS=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --source)          SOURCE="$2";   shift 2 ;;
                --source-user)     SRC_USER="$2"; shift 2 ;;
                --source-password) SRC_PASS="$2"; shift 2 ;;
                --target)          TARGET="$2";   shift 2 ;;
                --target-user)     TGT_USER="$2"; shift 2 ;;
                --target-password) TGT_PASS="$2"; shift 2 ;;
                --debug)           DEBUG=1;        shift   ;;
                *) echo "Unknown option: $1"; usage ;;
            esac
        done
        [[ -z "$SOURCE" || -z "$SRC_USER" || -z "$SRC_PASS" || \
           -z "$TARGET" || -z "$TGT_USER" || -z "$TGT_PASS" ]] && usage
        echo "=== FULL MIGRATION: ${SOURCE} → ${TARGET} ==="
        api_login "$SOURCE" "$SRC_USER" "$SRC_PASS"
        do_export "$SOURCE" "$SRC_USER"
        do_gallery "$EXPORT_DIR"
        echo ""
        api_login "$TARGET" "$TGT_USER" "$TGT_PASS"
        do_import "$TARGET" "$TGT_USER"
        ;;

    *) echo "Unknown mode: ${MODE}"; usage ;;
esac

# ---------------------------------------------------------------------------
# HTML photo album gallery
# ---------------------------------------------------------------------------

do_gallery() {
    local export_dir="$1"

    if [[ ! -f "${export_dir}/statuses.json" ]]; then
        echo "  ✗ statuses.json not found in ${export_dir}"
        exit 1
    fi

    echo ""
    echo "Generating photo album ..."

    local profile_name profile_account
    profile_name=$(jq -r '.name // .userName // "Unknown"' "${export_dir}/profile.json" 2>/dev/null || echo "Unknown")
    profile_account=$(jq -r '.account // ""' "${export_dir}/profile.json" 2>/dev/null || echo "")

    local out="${export_dir}/gallery.html"

    # Build photo entries as JSON array for embedding
    local clean_statuses
    clean_statuses=$(mktemp)
    tr -d '\000-\010\013\014\016-\037' < "${export_dir}/statuses.json" > "$clean_statuses"

    local entries
    entries=$(jq -c '[
        .[] |
        select((.attachments | length) > 0) |
        {
            id: .id,
            note: (.note // ""),
            createdAt: (.createdAt // ""),
            visibility: (.visibility // "public"),
            sensitive: (.sensitive // false),
            tags: ([.tags[]?.name] // []),
            attachments: [
                .attachments[] |
                {
                    local_file: (._local_file // ""),
                    description: (.description // ""),
                    location_name: (.location.name // ""),
                    location_country: (.location.country.name // ""),
                    exif_make: (.metadata.exif.make // ""),
                    exif_model: (.metadata.exif.model // ""),
                    exif_exposure: (.metadata.exif.exposureTime // ""),
                    exif_aperture: (.metadata.exif.fNumber // ""),
                    exif_iso: (.metadata.exif.photographicSensitivity // ""),
                    exif_focal: (.metadata.exif.focalLenIn35mmFilm // "")
                }
            ]
        }
    ] | sort_by(.createdAt)' "$clean_statuses")
    rm -f "$clean_statuses"

    local total_photos
    total_photos=$(echo "$entries" | jq 'length')

    cat > "$out" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${profile_name} · Photo Archive</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Playfair+Display:ital,wght@0,400;0,700;1,400&family=DM+Mono:wght@300;400&display=swap');

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg: #0e0e0e;
    --surface: #161616;
    --surface2: #1e1e1e;
    --border: #2a2a2a;
    --text: #e8e4dc;
    --text-muted: #7a7570;
    --accent: #c8a96e;
    --accent2: #8fb4a0;
    --danger: #c0604a;
    --radius: 4px;
    --font-serif: 'Playfair Display', Georgia, serif;
    --font-mono: 'DM Mono', 'Courier New', monospace;
  }

  html { scroll-behavior: smooth; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--font-mono);
    font-size: 13px;
    font-weight: 300;
    line-height: 1.6;
    min-height: 100vh;
  }

  /* Header */
  header {
    position: sticky;
    top: 0;
    z-index: 100;
    background: rgba(14,14,14,0.92);
    backdrop-filter: blur(12px);
    border-bottom: 1px solid var(--border);
    padding: 16px 32px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 24px;
  }

  .header-title {
    font-family: var(--font-serif);
    font-size: 22px;
    font-weight: 400;
    letter-spacing: 0.02em;
    color: var(--text);
  }

  .header-title span {
    color: var(--accent);
    font-style: italic;
  }

  .header-meta {
    color: var(--text-muted);
    font-size: 11px;
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }

  .header-controls {
    display: flex;
    gap: 8px;
    align-items: center;
  }

  /* Search & filter */
  .search-wrap {
    position: relative;
  }

  #search {
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--text);
    font-family: var(--font-mono);
    font-size: 12px;
    padding: 6px 12px;
    border-radius: var(--radius);
    width: 220px;
    outline: none;
    transition: border-color 0.2s;
  }

  #search:focus { border-color: var(--accent); }
  #search::placeholder { color: var(--text-muted); }

  /* View toggle */
  .view-btn {
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--text-muted);
    font-family: var(--font-mono);
    font-size: 11px;
    padding: 6px 10px;
    border-radius: var(--radius);
    cursor: pointer;
    transition: all 0.2s;
    letter-spacing: 0.05em;
  }

  .view-btn.active, .view-btn:hover {
    border-color: var(--accent);
    color: var(--accent);
  }

  /* Stats bar */
  .stats {
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    padding: 10px 32px;
    display: flex;
    gap: 32px;
    font-size: 11px;
    color: var(--text-muted);
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }

  .stats strong { color: var(--accent); font-weight: 400; }

  /* Main grid */
  main {
    padding: 32px;
    max-width: 1600px;
    margin: 0 auto;
  }

  /* Grid view */
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
    gap: 2px;
  }

  /* List view */
  .list { display: flex; flex-direction: column; gap: 1px; }

  /* Card */
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    overflow: hidden;
    transition: border-color 0.2s, transform 0.2s;
    cursor: pointer;
    position: relative;
  }

  .card:hover { border-color: var(--accent); z-index: 1; }

  .card-image-wrap {
    position: relative;
    overflow: hidden;
    background: var(--bg);
  }

  .grid .card-image-wrap {
    aspect-ratio: 4/3;
  }

  .list .card-image-wrap {
    width: 200px;
    min-width: 200px;
    aspect-ratio: 4/3;
    flex-shrink: 0;
  }

  .card img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
    transition: transform 0.4s ease;
  }

  .card:hover img { transform: scale(1.03); }

  .card-sensitive-overlay {
    position: absolute;
    inset: 0;
    background: var(--bg);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 11px;
    color: var(--text-muted);
    letter-spacing: 0.08em;
    text-transform: uppercase;
    cursor: pointer;
    z-index: 2;
    transition: opacity 0.3s;
  }

  /* Copy button */
  .copy-btn {
    position: absolute;
    top: 8px;
    right: 8px;
    background: rgba(14,14,14,0.85);
    border: 1px solid var(--border);
    color: var(--text-muted);
    font-family: var(--font-mono);
    font-size: 10px;
    padding: 4px 8px;
    border-radius: var(--radius);
    cursor: pointer;
    opacity: 0;
    transition: all 0.2s;
    z-index: 3;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }

  .card:hover .copy-btn { opacity: 1; }
  .copy-btn:hover { background: var(--accent); color: var(--bg); border-color: var(--accent); }
  .copy-btn.copied { background: var(--accent2); color: var(--bg); border-color: var(--accent2); }

  /* Card body */
  .card-body {
    padding: 14px 16px;
  }

  .list .card {
    display: flex;
    flex-direction: row;
  }

  .list .card-body {
    flex: 1;
    min-width: 0;
  }

  .card-note {
    font-family: var(--font-serif);
    font-size: 14px;
    line-height: 1.5;
    color: var(--text);
    margin-bottom: 10px;
    display: -webkit-box;
    -webkit-line-clamp: 3;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .card-desc {
    font-size: 11px;
    color: var(--text-muted);
    line-height: 1.5;
    margin-bottom: 10px;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .card-meta {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    align-items: center;
  }

  .tag {
    background: var(--surface2);
    border: 1px solid var(--border);
    color: var(--accent);
    font-size: 10px;
    padding: 2px 7px;
    border-radius: 2px;
    letter-spacing: 0.05em;
    cursor: pointer;
    transition: all 0.15s;
  }

  .tag:hover { background: var(--accent); color: var(--bg); }

  .location-chip {
    font-size: 10px;
    color: var(--accent2);
    letter-spacing: 0.04em;
  }

  .location-chip::before { content: "◎ "; }

  .date-chip {
    font-size: 10px;
    color: var(--text-muted);
    margin-left: auto;
    letter-spacing: 0.04em;
  }

  /* EXIF strip */
  .exif-strip {
    display: flex;
    gap: 12px;
    font-size: 10px;
    color: var(--text-muted);
    padding: 8px 16px;
    border-top: 1px solid var(--border);
    background: var(--bg);
    letter-spacing: 0.04em;
    flex-wrap: wrap;
  }

  .exif-strip span { white-space: nowrap; }

  /* Lightbox */
  #lightbox {
    display: none;
    position: fixed;
    inset: 0;
    z-index: 1000;
    background: rgba(0,0,0,0.93);
    backdrop-filter: blur(6px);
    align-items: center;
    justify-content: center;
  }

  #lightbox.open { display: flex; }

  .lb-inner {
    display: grid;
    grid-template-columns: 1fr 360px;
    max-width: 1400px;
    width: 100%;
    max-height: 96vh;
    margin: 0 24px;
    gap: 0;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
  }

  .lb-img-wrap {
    background: #000;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    max-height: 96vh;
  }

  .lb-img-wrap img {
    max-width: 100%;
    max-height: 96vh;
    object-fit: contain;
    display: block;
  }

  .lb-panel {
    display: flex;
    flex-direction: column;
    overflow-y: auto;
    border-left: 1px solid var(--border);
  }

  .lb-panel-header {
    padding: 20px 24px 16px;
    border-bottom: 1px solid var(--border);
    position: sticky;
    top: 0;
    background: var(--surface);
    z-index: 1;
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 12px;
  }

  .lb-date {
    font-size: 10px;
    color: var(--text-muted);
    letter-spacing: 0.08em;
    text-transform: uppercase;
    margin-bottom: 4px;
  }

  .lb-panel-title {
    font-family: var(--font-serif);
    font-size: 16px;
    line-height: 1.4;
    color: var(--text);
    flex: 1;
  }

  .lb-close {
    background: none;
    border: 1px solid var(--border);
    color: var(--text-muted);
    font-size: 16px;
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius);
    cursor: pointer;
    flex-shrink: 0;
    transition: all 0.2s;
  }

  .lb-close:hover { border-color: var(--danger); color: var(--danger); }

  .lb-section {
    padding: 16px 24px;
    border-bottom: 1px solid var(--border);
  }

  .lb-section-label {
    font-size: 9px;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--text-muted);
    margin-bottom: 8px;
  }

  .lb-desc {
    font-size: 12px;
    line-height: 1.6;
    color: var(--text);
  }

  .lb-tags { display: flex; flex-wrap: wrap; gap: 6px; }

  .lb-location {
    font-size: 12px;
    color: var(--accent2);
  }

  .lb-exif {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px 16px;
  }

  .lb-exif-item { font-size: 11px; color: var(--text-muted); }
  .lb-exif-item strong { color: var(--text); display: block; font-weight: 400; }

  .lb-copy-btn {
    margin: 16px 24px;
    background: var(--surface2);
    border: 1px solid var(--border);
    color: var(--text);
    font-family: var(--font-mono);
    font-size: 11px;
    padding: 10px 16px;
    border-radius: var(--radius);
    cursor: pointer;
    transition: all 0.2s;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    width: calc(100% - 48px);
  }

  .lb-copy-btn:hover { border-color: var(--accent); color: var(--accent); }
  .lb-copy-btn.copied { border-color: var(--accent2); color: var(--accent2); }

  /* Nav arrows */
  .lb-nav {
    position: fixed;
    top: 50%;
    transform: translateY(-50%);
    background: rgba(14,14,14,0.7);
    border: 1px solid var(--border);
    color: var(--text);
    font-size: 20px;
    width: 44px;
    height: 44px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius);
    cursor: pointer;
    z-index: 1001;
    transition: all 0.2s;
  }

  .lb-nav:hover { border-color: var(--accent); color: var(--accent); }
  #lb-prev { left: 16px; }
  #lb-next { right: 392px; }

  /* No results */
  .no-results {
    grid-column: 1/-1;
    text-align: center;
    padding: 80px 32px;
    color: var(--text-muted);
    font-size: 13px;
    letter-spacing: 0.06em;
  }

  .no-results::before {
    content: "◯";
    display: block;
    font-size: 32px;
    margin-bottom: 16px;
    color: var(--border);
  }

  /* Scrollbar */
  ::-webkit-scrollbar { width: 4px; }
  ::-webkit-scrollbar-track { background: var(--bg); }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }

  @media (max-width: 900px) {
    header { padding: 12px 16px; flex-wrap: wrap; }
    main { padding: 16px; }
    .stats { padding: 8px 16px; gap: 16px; flex-wrap: wrap; }
    .lb-inner { grid-template-columns: 1fr; max-height: 100vh; }
    .lb-panel { max-height: 50vh; border-left: none; border-top: 1px solid var(--border); }
    #lb-next { right: 16px; }
    .list .card { flex-direction: column; }
    .list .card-image-wrap { width: 100%; }
  }
</style>
</head>
<body>

<header>
  <div>
    <div class="header-title"><span>${profile_name}</span> · Photo Archive</div>
    <div class="header-meta">${profile_account}</div>
  </div>
  <div class="header-controls">
    <div class="search-wrap">
      <input type="text" id="search" placeholder="Search notes, tags, places …" autocomplete="off">
    </div>
    <button class="view-btn active" id="btn-grid" onclick="setView('grid')">Grid</button>
    <button class="view-btn" id="btn-list" onclick="setView('list')">List</button>
  </div>
</header>

<div class="stats">
  <div>Total <strong id="count-total">${total_photos}</strong></div>
  <div>Visible <strong id="count-visible">${total_photos}</strong></div>
  <div>Archive generated <strong>$(date '+%Y-%m-%d')</strong></div>
</div>

<main>
  <div class="grid" id="gallery"></div>
</main>

<!-- Lightbox -->
<div id="lightbox">
  <button class="lb-nav" id="lb-prev" onclick="lbNav(-1)">‹</button>
  <div class="lb-inner">
    <div class="lb-img-wrap">
      <img id="lb-img" src="" alt="">
    </div>
    <div class="lb-panel">
      <div class="lb-panel-header">
        <div>
          <div class="lb-date" id="lb-date"></div>
          <div class="lb-panel-title" id="lb-note"></div>
        </div>
        <button class="lb-close" onclick="closeLb()">✕</button>
      </div>
      <div class="lb-section" id="lb-desc-section">
        <div class="lb-section-label">Description</div>
        <div class="lb-desc" id="lb-desc"></div>
      </div>
      <div class="lb-section" id="lb-location-section">
        <div class="lb-section-label">Location</div>
        <div class="lb-location" id="lb-location"></div>
      </div>
      <div class="lb-section" id="lb-tags-section">
        <div class="lb-section-label">Tags</div>
        <div class="lb-tags" id="lb-tags"></div>
      </div>
      <div class="lb-section" id="lb-exif-section">
        <div class="lb-section-label">Camera</div>
        <div class="lb-exif" id="lb-exif"></div>
      </div>
      <button class="lb-copy-btn" id="lb-copy-btn" onclick="copyImage()">Copy image to clipboard</button>
    </div>
  </div>
  <button class="lb-nav" id="lb-next" onclick="lbNav(1)">›</button>
</div>

<script>
const DATA = PHOTODATAPLACEHOLDER;

let currentView = 'grid';
let visibleCards = [];
let lbIndex = 0;

function formatDate(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  return d.toLocaleDateString('en-GB', { year: 'numeric', month: 'short', day: 'numeric' });
}

function imgSrc(att) {
  if (att.local_file) {
    const rel = att.local_file.replace(/^.*vernissage_export\//, 'photos/');
    return rel;
  }
  return '';
}

function renderCard(entry, idx) {
  const att = entry.attachments[0];
  const src = imgSrc(att);
  if (!src) return '';

  const date = formatDate(entry.createdAt);
  const tags = entry.tags.map(t =>
    `<span class="tag" onclick="filterTag('${t}')">#${t}</span>`
  ).join('');

  const loc = att.location_name
    ? `<span class="location-chip">${att.location_name}${att.location_country ? ', ' + att.location_country : ''}</span>`
    : '';

  const hasExif = att.exif_make || att.exif_model || att.exif_exposure;
  const exifText = hasExif
    ? `${att.exif_make || ''} ${att.exif_model || ''} · ${att.exif_exposure ? att.exif_exposure + 's' : ''} ${att.exif_aperture || ''} ISO${att.exif_iso || ''}`
    : '';

  const noteHtml = entry.note
    ? `<div class="card-note">${entry.note.replace(/<[^>]+>/g, '').substring(0, 200)}</div>`
    : '';

  const descHtml = att.description
    ? `<div class="card-desc">${att.description.substring(0, 150)}</div>`
    : '';

  const sensitiveOverlay = entry.sensitive
    ? `<div class="card-sensitive-overlay" onclick="revealSensitive(this)">⚠ Sensitive — click to reveal</div>`
    : '';

  return `
    <div class="card" data-idx="${idx}"
         data-note="${entry.note.replace(/"/g,'&quot;').toLowerCase()}"
         data-tags="${entry.tags.join(' ').toLowerCase()}"
         data-loc="${(att.location_name||'').toLowerCase()}"
         onclick="openLb(${idx})">
      <div class="card-image-wrap">
        ${sensitiveOverlay}
        <img src="${src}" alt="${att.description || ''}" loading="lazy">
        <button class="copy-btn" onclick="event.stopPropagation(); copyCardImage('${src}', this)">Copy</button>
      </div>
      <div class="card-body">
        ${noteHtml}
        ${descHtml}
        <div class="card-meta">
          ${tags}
          ${loc}
          <span class="date-chip">${date}</span>
        </div>
      </div>
      ${exifText ? `<div class="exif-strip"><span>${exifText}</span></div>` : ''}
    </div>`;
}

function render() {
  const q = document.getElementById('search').value.toLowerCase().trim();
  const container = document.getElementById('gallery');
  container.className = currentView;

  let html = '';
  let visible = 0;
  visibleCards = [];

  DATA.forEach((entry, idx) => {
    const att = entry.attachments[0];
    if (!att || !imgSrc(att)) return;

    const searchStr = [
      entry.note, att.description,
      entry.tags.join(' '), att.location_name, att.location_country
    ].join(' ').toLowerCase();

    if (q && !searchStr.includes(q)) return;

    visibleCards.push(idx);
    html += renderCard(entry, idx);
    visible++;
  });

  if (visible === 0) {
    html = '<div class="no-results">No photos match your search</div>';
  }

  container.innerHTML = html;
  document.getElementById('count-visible').textContent = visible;
}

function setView(v) {
  currentView = v;
  document.getElementById('btn-grid').classList.toggle('active', v === 'grid');
  document.getElementById('btn-list').classList.toggle('active', v === 'list');
  render();
}

function filterTag(tag) {
  document.getElementById('search').value = '#' + tag;
  render();
}

function revealSensitive(el) {
  el.style.opacity = '0';
  setTimeout(() => el.remove(), 300);
}

// Lightbox
function openLb(dataIdx) {
  lbIndex = visibleCards.indexOf(dataIdx);
  if (lbIndex === -1) lbIndex = 0;
  showLb();
}

function showLb() {
  const entry = DATA[visibleCards[lbIndex]];
  const att = entry.attachments[0];
  const src = imgSrc(att);

  document.getElementById('lb-img').src = src;
  document.getElementById('lb-img').alt = att.description || '';
  document.getElementById('lb-date').textContent = formatDate(entry.createdAt);
  document.getElementById('lb-note').textContent = entry.note.replace(/<[^>]+>/g, '') || '—';

  // Description
  const descSec = document.getElementById('lb-desc-section');
  const descEl = document.getElementById('lb-desc');
  if (att.description) {
    descEl.textContent = att.description;
    descSec.style.display = '';
  } else {
    descSec.style.display = 'none';
  }

  // Location
  const locSec = document.getElementById('lb-location-section');
  const locEl = document.getElementById('lb-location');
  if (att.location_name) {
    locEl.textContent = att.location_name + (att.location_country ? ', ' + att.location_country : '');
    locSec.style.display = '';
  } else {
    locSec.style.display = 'none';
  }

  // Tags
  const tagsSec = document.getElementById('lb-tags-section');
  const tagsEl = document.getElementById('lb-tags');
  if (entry.tags.length) {
    tagsEl.innerHTML = entry.tags.map(t =>
      `<span class="tag" onclick="closeLb(); filterTag('${t}')">#${t}</span>`
    ).join('');
    tagsSec.style.display = '';
  } else {
    tagsSec.style.display = 'none';
  }

  // EXIF
  const exifSec = document.getElementById('lb-exif-section');
  const exifEl = document.getElementById('lb-exif');
  const exifItems = [
    att.exif_make && att.exif_model ? { label: 'Camera', val: att.exif_make + ' ' + att.exif_model } : null,
    att.exif_exposure  ? { label: 'Shutter', val: att.exif_exposure + 's' } : null,
    att.exif_aperture  ? { label: 'Aperture', val: att.exif_aperture } : null,
    att.exif_iso       ? { label: 'ISO', val: att.exif_iso } : null,
    att.exif_focal     ? { label: 'Focal length', val: att.exif_focal + 'mm' } : null,
  ].filter(Boolean);

  if (exifItems.length) {
    exifEl.innerHTML = exifItems.map(i =>
      `<div class="lb-exif-item"><strong>${i.val}</strong>${i.label}</div>`
    ).join('');
    exifSec.style.display = '';
  } else {
    exifSec.style.display = 'none';
  }

  // Reset copy button
  const cpBtn = document.getElementById('lb-copy-btn');
  cpBtn.textContent = 'Copy image to clipboard';
  cpBtn.classList.remove('copied');

  document.getElementById('lightbox').classList.add('open');
  document.body.style.overflow = 'hidden';
}

function closeLb() {
  document.getElementById('lightbox').classList.remove('open');
  document.body.style.overflow = '';
}

function lbNav(dir) {
  lbIndex = (lbIndex + dir + visibleCards.length) % visibleCards.length;
  showLb();
}

// Copy to clipboard
async function copyCardImage(src, btn) {
  try {
    const res = await fetch(src);
    const blob = await res.blob();
    const jpegBlob = blob.type === 'image/png' ? blob : blob;
    await navigator.clipboard.write([new ClipboardItem({ [blob.type]: blob })]);
    btn.textContent = 'Copied!';
    btn.classList.add('copied');
    setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 2000);
  } catch(e) {
    btn.textContent = 'Error';
    setTimeout(() => { btn.textContent = 'Copy'; }, 2000);
  }
}

async function copyImage() {
  const img = document.getElementById('lb-img');
  const btn = document.getElementById('lb-copy-btn');
  try {
    const res = await fetch(img.src);
    const blob = await res.blob();
    await navigator.clipboard.write([new ClipboardItem({ [blob.type]: blob })]);
    btn.textContent = '✓ Copied to clipboard';
    btn.classList.add('copied');
    setTimeout(() => { btn.textContent = 'Copy image to clipboard'; btn.classList.remove('copied'); }, 2500);
  } catch(e) {
    btn.textContent = 'Could not copy — try right-clicking the image';
    setTimeout(() => { btn.textContent = 'Copy image to clipboard'; }, 3000);
  }
}

// Keyboard navigation
document.addEventListener('keydown', e => {
  if (!document.getElementById('lightbox').classList.contains('open')) return;
  if (e.key === 'Escape') closeLb();
  if (e.key === 'ArrowLeft') lbNav(-1);
  if (e.key === 'ArrowRight') lbNav(1);
});

// Close lightbox on backdrop click
document.getElementById('lightbox').addEventListener('click', e => {
  if (e.target === document.getElementById('lightbox')) closeLb();
});

// Search
document.getElementById('search').addEventListener('input', render);

// Init
render();
</script>
</body>
</html>
HTMLEOF

    # Inject the actual photo data
    local json_data
    json_data=$(echo "$entries" | jq -c '.')
    sed -i "s|PHOTODATAPLACEHOLDER|${json_data}|" "$out"

    echo "  ✓ Gallery generated → ${out}"
    echo "  ${total_photos} photos — open in your browser to view."
}
