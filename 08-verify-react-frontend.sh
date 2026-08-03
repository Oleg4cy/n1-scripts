#!/usr/bin/env bash
set -Eeuo pipefail

project_directory="${N1_FRONT_DIRECTORY:-/srv/n1/front}"
environment_file="${project_directory}/.env"
dist_directory="${project_directory}/dist"

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this script as root.\n' >&2
    exit 1
fi

required_commands=(
    node
    npm
    git
    stat
    find
    grep
    du
    cut
    tr
    wc
    runuser
)

for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$required_command" >&2
        exit 1
    fi
done

required_files=(
    "${project_directory}/package.json"
    "${project_directory}/package-lock.json"
    "$environment_file"
    "${dist_directory}/index.html"
)

for required_file in "${required_files[@]}"; do
    if [ ! -f "$required_file" ]; then
        printf 'Required file not found: %s\n' "$required_file" >&2
        exit 1
    fi
done

if [ ! -d "${dist_directory}/assets" ]; then
    printf 'Required directory not found: %s\n' "${dist_directory}/assets" >&2
    exit 1
fi

printf '\n===== NODE AND NPM =====\n'
printf 'node: %s\n' "$(node --version)"
printf 'npm: %s\n' "$(npm --version)"

printf '\n===== FRONTEND ENVIRONMENT =====\n'
stat \
    -c '%A %U:%G %s bytes %n' \
    "$environment_file"

api_base_url_line="$(
    grep -m 1 -E '^VITE_API_BASE_URL=' "$environment_file" \
        || true
)"

if [ -z "$api_base_url_line" ]; then
    printf 'VITE_API_BASE_URL is missing from %s\n' "$environment_file" >&2
    exit 1
fi

printf '%s\n' "$api_base_url_line"

api_base_url="${api_base_url_line#*=}"
api_base_url="${api_base_url%\"}"
api_base_url="${api_base_url#\"}"
api_base_url="${api_base_url%\'}"
api_base_url="${api_base_url#\'}"

case "$api_base_url" in
    http://*|https://*)
        ;;
    *)
        printf 'VITE_API_BASE_URL is not an absolute HTTP(S) URL: %s\n' "$api_base_url" >&2
        exit 1
        ;;
esac

printf '\n===== BUILD FILES =====\n'

build_file_count="$(
    find "$dist_directory" \
        -type f \
        | wc -l \
        | tr -d '[:space:]'
)"

asset_file_count="$(
    find "${dist_directory}/assets" \
        -type f \
        | wc -l \
        | tr -d '[:space:]'
)"

if [ "$build_file_count" -lt 2 ]; then
    printf 'Unexpectedly few build files: %s\n' "$build_file_count" >&2
    exit 1
fi

if [ "$asset_file_count" -lt 1 ]; then
    printf 'No frontend assets were found.\n' >&2
    exit 1
fi

printf 'Build directory: %s\n' "$dist_directory"
printf 'Build files: %s\n' "$build_file_count"
printf 'Asset files: %s\n' "$asset_file_count"
printf 'Build size: '
du -sh "$dist_directory" | cut -f1

printf '\n===== INDEX REFERENCES =====\n'

index_asset_references="$(
    grep \
        -oE '/assets/[^"[:space:]]+' \
        "${dist_directory}/index.html" \
        || true
)"

if [ -z "$index_asset_references" ]; then
    printf 'No /assets/ references found in dist/index.html.\n' >&2
    exit 1
fi

printf '%s\n' "$index_asset_references"

missing_asset=false

while IFS= read -r asset_reference; do
    asset_path="${dist_directory}${asset_reference}"

    if [ ! -f "$asset_path" ]; then
        printf 'Referenced asset is missing: %s\n' "$asset_path" >&2
        missing_asset=true
    fi
done <<< "$index_asset_references"

if [ "$missing_asset" = true ]; then
    exit 1
fi

printf '\n===== API URL IN BUILD =====\n'

if grep \
    -RqsF \
    "$api_base_url" \
    "${dist_directory}/assets"
then
    printf 'Configured API URL is present in the compiled assets.\n'
else
    printf 'WARNING: configured API URL was not found as plain text in compiled assets.\n'
    printf 'This may be valid if the bundler transformed the value, but it requires browser verification later.\n'
fi

printf '\n===== GIT STATUS =====\n'

runuser -u n1 -- \
    git \
    -C "$project_directory" \
    status \
    --short \
    --branch

printf '\nReact frontend verification completed.\n'
printf 'The build is not public yet; Nginx routing remains to be configured.\n'
