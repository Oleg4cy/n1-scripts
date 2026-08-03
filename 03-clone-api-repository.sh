#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this script as root.\n' >&2
    exit 1
fi

repository_url="${N1_API_REPOSITORY_URL:-git@github.com:Oleg4cy/n1-api.git}"
branch_name="${N1_API_BRANCH:-main}"
target_directory="${N1_API_DIRECTORY:-/srv/n1/api}"

if ! id n1 >/dev/null 2>&1; then
    printf 'System user n1 does not exist. Run 02-create-n1-user-and-ssh.sh first.\n' >&2
    exit 1
fi

if [ -d "${target_directory}/.git" ]; then
    current_remote="$(
        runuser -u n1 -- git -C "$target_directory" remote get-url origin
    )"

    if [ "$current_remote" != "$repository_url" ]; then
        printf 'Unexpected origin in %s:\n' "$target_directory" >&2
        printf '  expected: %s\n' "$repository_url" >&2
        printf '  actual:   %s\n' "$current_remote" >&2
        exit 1
    fi

    printf 'Repository already exists; no clone or pull was performed.\n'
elif [ -e "$target_directory" ]; then
    if [ -d "$target_directory" ] && [ -z "$(find "$target_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        rmdir "$target_directory"
    else
        printf 'Target exists and is not an empty clone destination: %s\n' "$target_directory" >&2
        exit 1
    fi

    runuser -u n1 -- git clone
else
    runuser -u n1 -- git clone
fi

runuser -u n1 -- git \
    -C "$target_directory" \
    config \
    --local \
    pull.ff \
    only

runuser -u n1 -- git \
    -C "$target_directory" \
    config \
    --local \
    fetch.prune \
    true

printf '\n===== API REPOSITORY =====\n'
printf 'remote: '
runuser -u n1 -- git -C "$target_directory" remote get-url origin
printf 'branch: '
runuser -u n1 -- git -C "$target_directory" branch --show-current
printf 'upstream: '
runuser -u n1 -- git \
    -C "$target_directory" \
    rev-parse \
    --abbrev-ref \
    --symbolic-full-name \
    '@{upstream}'
printf 'commit: '
runuser -u n1 -- git -C "$target_directory" rev-parse HEAD
runuser -u n1 -- git -C "$target_directory" status --short --branch

