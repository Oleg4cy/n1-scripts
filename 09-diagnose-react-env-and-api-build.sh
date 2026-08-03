#!/usr/bin/env bash
set -Eeuo pipefail

project_directory="${N1_FRONT_DIRECTORY:-/srv/n1/front}"
source_directory="${project_directory}/src"
build_directory="${project_directory}/dist"
environment_file="${project_directory}/.env"
gitignore_file="${project_directory}/.gitignore"

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this script as root.\n' >&2
    exit 1
fi

required_commands=(
    git
    grep
    nl
    stat
)

for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$required_command" >&2
        exit 1
    fi
done

required_paths=(
    "$project_directory"
    "$source_directory"
    "$gitignore_file"
    "$environment_file"
    "$build_directory"
)

for required_path in "${required_paths[@]}"; do
    if [ ! -e "$required_path" ]; then
        printf 'Required path not found: %s\n' "$required_path" >&2
        exit 1
    fi
done

if [ ! -d "${project_directory}/.git" ]; then
    printf 'Git repository not found: %s\n' "$project_directory" >&2
    exit 1
fi

printf '\n===== FRONTEND PATHS =====\n'
stat \
    -c '%A %U:%G %s bytes %n' \
    "$project_directory" \
    "$gitignore_file" \
    "$environment_file" \
    "$build_directory"

printf '\n===== GITIGNORE =====\n'
nl -ba "$gitignore_file"

printf '\n===== GIT IGNORE CHECK =====\n'
if git \
    -C "$project_directory" \
    check-ignore \
    -v \
    .env
then
    printf 'Result: .env is ignored by Git.\n'
else
    printf 'Result: .env is NOT ignored by Git.\n'
fi

printf '\n===== GIT STATUS =====\n'
git \
    -C "$project_directory" \
    status \
    --short \
    --branch

printf '\n===== API CONFIGURATION IN SOURCE =====\n'
grep \
    -RniE \
    'VITE_API_BASE_URL|import[.]meta[.]env|API_BASE_URL' \
    "$source_directory" \
    "${project_directory}/vite.config.js" \
    "${project_directory}/package.json" \
    2>/dev/null \
    || true

printf '\n===== PRODUCTION DOMAIN IN BUILD =====\n'
grep \
    -RnaF \
    'virtual-privat-n1.ru' \
    "$build_directory" \
    2>/dev/null \
    || true

printf '\n===== API PATHS IN BUILD =====\n'
grep \
    -RnaE \
    '/api/v1|/sanctum/csrf-cookie|csrf-cookie' \
    "${build_directory}/assets" \
    2>/dev/null \
    || true

printf '\nReact frontend diagnostic completed.\n'
