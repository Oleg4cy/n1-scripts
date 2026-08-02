#!/usr/bin/env bash
set -euo pipefail

printf '\n===== DATE AND USER =====\n'
date --iso-8601=seconds
id

printf '\n===== OPERATING SYSTEM =====\n'
uname -a
cat /etc/os-release

printf '\n===== CPU =====\n'
nproc
lscpu | grep -E '^(Architecture|CPU\(s\)|Model name|Thread|Core|Socket|Virtualization):' || true

printf '\n===== MEMORY =====\n'
free -h
swapon --show

printf '\n===== DISKS =====\n'
df -hT
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

printf '\n===== TOP MEMORY PROCESSES =====\n'
ps -eo pid,user,comm,%cpu,%mem,rss --sort=-rss | head -n 31

printf '\n===== LISTENING PORTS =====\n'
ss -lntup

printf '\n===== RUNNING SERVICES =====\n'
systemctl list-units --type=service --state=running --no-pager --no-legend

printf '\n===== API RUNTIME COMMANDS =====\n'
for command_name in nginx php composer git psql; do
    printf '%-12s' "$command_name"
    command -v "$command_name" || printf 'not found\n'
done

printf '\n===== API RUNTIME VERSIONS =====\n'
command -v nginx >/dev/null 2>&1 && nginx -v
command -v php >/dev/null 2>&1 && php -v
command -v composer >/dev/null 2>&1 && COMPOSER_ALLOW_SUPERUSER=1 composer --version
command -v git >/dev/null 2>&1 && git --version
command -v psql >/dev/null 2>&1 && psql --version

printf '\n===== API SERVICES =====\n'
systemctl is-active nginx 2>/dev/null || true
systemctl is-active php8.4-fpm 2>/dev/null || true
systemctl is-active postgresql 2>/dev/null || true
