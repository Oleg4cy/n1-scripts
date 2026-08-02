#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this script as root.\n' >&2
    exit 1
fi

project_directory="${N1_API_DIRECTORY:-/srv/n1/api}"
environment_file="${project_directory}/.env"

required_files=(
    "${project_directory}/artisan"
    "${project_directory}/composer.json"
    "${project_directory}/composer.lock"
    "$environment_file"
)

for required_file in "${required_files[@]}"; do
    if [ ! -f "$required_file" ]; then
        printf 'Required file not found: %s\n' "$required_file" >&2
        exit 1
    fi
done

printf '\n===== FILE OWNERSHIP =====\n'
stat \
    -c '%A %U:%G %s bytes %n' \
    "$environment_file" \
    "${project_directory}/storage" \
    "${project_directory}/bootstrap/cache"

printf '\n===== SECRET-SAFE ENVIRONMENT CHECK =====\n'
for key in \
    APP_NAME \
    APP_ENV \
    APP_DEBUG \
    APP_URL \
    FRONTEND_ORIGINS \
    SANCTUM_STATEFUL_DOMAINS \
    DB_CONNECTION \
    DB_HOST \
    DB_PORT \
    DB_DATABASE \
    DB_USERNAME \
    SESSION_DRIVER \
    SESSION_SECURE_COOKIE \
    QUEUE_CONNECTION \
    CACHE_STORE \
    LOGIN_CODE_DELIVERY \
    MAIL_MAILER
do
    line="$(grep -m 1 -E "^${key}=" "$environment_file" || true)"
    if [ -n "$line" ]; then
        printf '%s\n' "$line"
    else
        printf '%s=<missing>\n' "$key"
    fi
done

for secret_key in \
    APP_KEY \
    DB_PASSWORD \
    REMNAWAVE_API_TOKEN \
    MAIL_PASSWORD \
    AWS_SECRET_ACCESS_KEY
do
    if grep -q -E "^${secret_key}=.+$" "$environment_file"; then
        printf '%s=configured\n' "$secret_key"
    else
        printf '%s=empty-or-missing\n' "$secret_key"
    fi
done

printf '\n===== COMPOSER PLATFORM REQUIREMENTS =====\n'
runuser -u n1 -- \
    composer \
    --working-dir="$project_directory" \
    check-platform-reqs \
    --no-dev

printf '\n===== APPLICATION ENVIRONMENT =====\n'
runuser -u n1 -- \
    php \
    "${project_directory}/artisan" \
    env

printf '\n===== MIGRATION STATUS =====\n'
runuser -u n1 -- \
    php \
    "${project_directory}/artisan" \
    migrate:status

printf '\n===== HEALTH ROUTE =====\n'
runuser -u n1 -- \
    php \
    "${project_directory}/artisan" \
    route:list \
    --path=api/v1/health

printf '\n===== GIT STATUS =====\n'
runuser -u n1 -- \
    git \
    -C "$project_directory" \
    status \
    --short \
    --branch

printf '\nLaravel API verification completed.\n'
