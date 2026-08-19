#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export EXPORT_DIR="${TEST_DIR}/export"
# shellcheck source=../vernissage-migrator.sh
source "${ROOT_DIR}/vernissage-migrator.sh"

pass_count=0

pass() {
    pass_count=$((pass_count + 1))
    printf 'ok %d - %s\n' "$pass_count" "$1"
}

fail() {
    printf 'not ok %d - %s\n' "$((pass_count + 1))" "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "${message}: expected '${expected}', got '${actual}'"
    pass "$message"
}

mkdir -p "$EXPORT_DIR"
printf '1234\n' > "$RESUME_FILE"
if is_imported 123; then
    fail "resume lookup requires a complete ID match"
fi
is_imported 1234 || fail "resume lookup finds an exact ID"
pass "resume lookup requires a complete ID match"

(
    curl() { return 22; }
    if api_get_paginated "users/test/statuses" >/dev/null 2>&1; then
        exit 1
    fi
) || fail "pagination propagates transport failures"
pass "pagination propagates transport failures"

(
    curl() { printf '%s\n' '{"unexpected":[]}'; }
    if api_get_paginated "users/test/statuses" >/dev/null 2>&1; then
        exit 1
    fi
) || fail "pagination rejects malformed payloads"
pass "pagination rejects malformed payloads"

fixture="${TEST_DIR}/gallery"
mkdir -p "${fixture}/photos"
printf '%s\n' '{"name":"<img src=x onerror=alert(1)>","account":"review@example.test"}' > "${fixture}/profile.json"
printf '%s\n' '[{"id":"1","note":"multi photo","createdAt":"2026-01-01T00:00:00Z","sensitive":true,"tags":[{"name":"travel"}],"attachments":[{"_local_file":"photos/1_0.jpg","description":"<img src=x onerror=alert(1)>"},{"_local_file":"photos/1_1.jpg","description":"second"}]}]' > "${fixture}/statuses.json"
do_gallery "$fixture" >/dev/null

gallery_count=$(grep -o 'id="count-total">[0-9]*' "${fixture}/gallery.html" | grep -o '[0-9]*')
assert_eq 2 "$gallery_count" "gallery renders and counts every attachment"

grep -q 'document.getElementById.*search.*value = tag' "${fixture}/gallery.html" \
    || fail "tag clicks use the searchable value"
pass "tag clicks use the searchable value"

if grep -q 'onclick="filterTag\|onclick="openLb' "${fixture}/gallery.html"; then
    fail "gallery avoids data-bearing inline event handlers"
fi
grep -q 'escapeHtml(att.description' "${fixture}/gallery.html" \
    || fail "gallery escapes attachment descriptions"
pass "gallery escapes exported content before using innerHTML"

awk '/^<script>$/ { capture=1; next } /^<\/script>$/ { capture=0 } capture' \
    "${fixture}/gallery.html" > "${TEST_DIR}/gallery-inline.js"
node --check "${TEST_DIR}/gallery-inline.js" >/dev/null
pass "generated gallery JavaScript is syntactically valid"

portable_export="${TEST_DIR}/portable-export"
EXPORT_DIR="$portable_export"
RESUME_FILE="${EXPORT_DIR}/.imported_ids"
api_get() {
    printf '%s\n' '{"id":"account-1","account":"test@example.test","name":"Test"}'
}
api_get_paginated() {
    case "$1" in
        */statuses)
            printf '%s\n' '[{"id":"status-1","createdAt":"2026-01-01T00:00:00Z","attachments":[{"originalFile":{"url":"https://media.example.test/photo.jpeg"}}]}]'
            ;;
        *) printf '%s\n' '[]' ;;
    esac
}
curl() {
    local output=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-o" ]]; then
            output="$2"
            shift 2
        else
            shift
        fi
    done
    [[ -n "$output" ]] || return 1
    printf 'image' > "$output"
}
do_export "https://source.example.test" test >/dev/null
local_path=$(jq -r '.[0].attachments[0]._local_file' "${portable_export}/statuses.json")
assert_eq 'photos/status-1_0.jpeg' "$local_path" "export stores portable relative photo paths"

partial_import="${TEST_DIR}/partial-import"
mkdir -p "${partial_import}/photos"
printf 'a' > "${partial_import}/photos/a.jpg"
printf 'b' > "${partial_import}/photos/b.jpg"
printf '%s\n' '{"name":"Test","bio":""}' > "${partial_import}/profile.json"
printf '%s\n' '[{"id":"status-2","createdAt":"2026-01-01T00:00:00Z","attachments":[{"_local_file":"photos/a.jpg"},{"_local_file":"photos/b.jpg"}]}]' > "${partial_import}/statuses.json"
EXPORT_DIR="$partial_import"
RESUME_FILE="${EXPORT_DIR}/.imported_ids"
api_put() { printf '%s\n' '{"name":"Test"}'; }
api_post_multipart() {
    if [[ "$*" == *'a.jpg'* ]]; then printf '%s\n' '{"id":"media-1"}'; else printf '%s\n' '{}'; fi
}
api_post_json() {
    : > "${TEST_DIR}/status-posted"
    printf '%s\n' '{"id":"new-status"}'
}
sleep() { :; }
do_import "https://target.example.test" test >/dev/null || :
[[ ! -e "${TEST_DIR}/status-posted" ]] || fail "partial attachment uploads are not published"
[[ ! -e "$RESUME_FILE" ]] || fail "partial attachment uploads are not marked as imported"
pass "partial attachment uploads remain retryable"

printf '1..%d\n' "$pass_count"
