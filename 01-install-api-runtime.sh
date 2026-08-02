#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this script as root.\n' >&2
    exit 1
fi

for required_command in apt-get apt-cache; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$required_command" >&2
        exit 1
    fi
done

packages=(
    nginx
    php8.4-cli
    php8.4-fpm
    php8.4-opcache
    php8.4-pgsql
    php8.4-mbstring
    php8.4-xml
    php8.4-curl
    php8.4-zip
    php8.4-bcmath
    php8.4-intl
    composer
    postgresql
    postgresql-client
    git
    unzip
    ca-certificates
)

missing_packages=()

apt-get update

for package_name in "${packages[@]}"; do
    if ! apt-cache show "$package_name" >/dev/null 2>&1; then
        missing_packages+=("$package_name")
    fi
done

if ((${#missing_packages[@]} > 0)); then
    printf 'Packages unavailable in configured repositories:\n' >&2
    printf ' - %s\n' "${missing_packages[@]}" >&2
    exit 1
fi

DEBIAN_FRONTEND=noninteractive apt-get install \
    --yes \
    --no-install-recommends \
    "${packages[@]}"

printf '\n===== INSTALLED VERSIONS =====\n'
nginx -v
php -v
php -m | grep -E '^(bcmath|curl|dom|intl|mbstring|pdo_pgsql|pgsql|xml|xmlwriter|zip)$'
COMPOSER_ALLOW_SUPERUSER=1 composer --version
psql --version
git --version

printf '\n===== SERVICE STATES =====\n'
systemctl is-active nginx
systemctl is-active php8.4-fpm
systemctl is-active postgresql

printf '\n===== LISTENING PORTS =====\n'
ss -lntup
