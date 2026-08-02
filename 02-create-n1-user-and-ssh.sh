#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this script as root.\n' >&2
    exit 1
fi

required_commands=(
    getent
    useradd
    install
    runuser
    ssh-keygen
    stat
)

for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$required_command" >&2
        exit 1
    fi
done

if ! getent passwd n1 >/dev/null 2>&1; then
    useradd \
        --create-home \
        --shell /bin/bash \
        --user-group \
        n1
fi

install \
    -d \
    -m 0755 \
    -o n1 \
    -g n1 \
    /srv/n1

install \
    -d \
    -m 0700 \
    -o n1 \
    -g n1 \
    /home/n1/.ssh

if [ ! -f /home/n1/.ssh/id_ed25519 ]; then
    runuser -u n1 -- ssh-keygen \
        -t ed25519 \
        -C 'n1 production Git pull key' \
        -f /home/n1/.ssh/id_ed25519 \
        -N ''
fi

chown -R n1:n1 /home/n1/.ssh
chmod 0700 /home/n1/.ssh
chmod 0600 /home/n1/.ssh/id_ed25519
chmod 0644 /home/n1/.ssh/id_ed25519.pub

printf '\n===== N1 USER =====\n'
id n1
getent passwd n1

printf '\n===== DIRECTORIES =====\n'
stat \
    -c '%A %U:%G %n' \
    /srv/n1 \
    /home/n1/.ssh

printf '\n===== GITHUB PUBLIC KEY =====\n'
cat /home/n1/.ssh/id_ed25519.pub
