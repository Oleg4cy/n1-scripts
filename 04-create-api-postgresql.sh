#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this script as root.\n' >&2
    exit 1
fi

required_commands=(
    runuser
    psql
    createdb
    openssl
    install
    stat
)

for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$required_command" >&2
        exit 1
    fi
done

role_name="${N1_API_DB_USERNAME:-n1_api}"
database_name="${N1_API_DB_DATABASE:-n1_api}"
secrets_directory="${N1_API_SECRETS_DIRECTORY:-/root/.n1-secrets}"
password_file="${secrets_directory}/api-db-password"
test_passfile='/home/n1/.pgpass.n1-api-test'
password_was_created=false

install \
    -d \
    -m 0700 \
    -o root \
    -g root \
    "$secrets_directory"

if [ ! -f "$password_file" ]; then
    umask 077
    openssl rand -hex 32 > "$password_file"
    chown root:root "$password_file"
    chmod 0600 "$password_file"
    password_was_created=true
fi

database_password="$(
    tr -d '\r\n' < "$password_file"
)"

if [[ ! "$database_password" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'Unexpected password format in %s.\n' "$password_file" >&2
    exit 1
fi

password_encryption="$(
    runuser -u postgres -- \
        psql \
        --no-psqlrc \
        --tuples-only \
        --no-align \
        --dbname=postgres \
        --command='SHOW password_encryption;'
)"

if [ "$password_encryption" != 'scram-sha-256' ]; then
    printf 'Unexpected PostgreSQL password encryption: %s\n' "$password_encryption" >&2
    exit 1
fi

role_exists="$(
    runuser -u postgres -- \
        psql \
        --no-psqlrc \
        --tuples-only \
        --no-align \
        --dbname=postgres \
        --command="SELECT 1 FROM pg_roles WHERE rolname = '${role_name}';"
)"

if [ "$role_exists" != '1' ]; then
    runuser -u postgres -- \
        psql \
        --no-psqlrc \
        --set=ON_ERROR_STOP=1 \
        --dbname=postgres <<SQL
CREATE ROLE "${role_name}"
    WITH
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS
    PASSWORD '${database_password}';
SQL
elif [ "$password_was_created" = true ]; then
    runuser -u postgres -- \
        psql \
        --no-psqlrc \
        --set=ON_ERROR_STOP=1 \
        --dbname=postgres <<SQL
ALTER ROLE "${role_name}" PASSWORD '${database_password}';
SQL
fi

database_exists="$(
    runuser -u postgres -- \
        psql \
        --no-psqlrc \
        --tuples-only \
        --no-align \
        --dbname=postgres \
        --command="SELECT 1 FROM pg_database WHERE datname = '${database_name}';"
)"

if [ "$database_exists" != '1' ]; then
    runuser -u postgres -- \
        createdb \
        --owner="$role_name" \
        "$database_name"
fi

runuser -u postgres -- \
    psql \
    --no-psqlrc \
    --set=ON_ERROR_STOP=1 \
    --dbname=postgres <<SQL
ALTER DATABASE "${database_name}" OWNER TO "${role_name}";
ALTER DATABASE "${database_name}" SET timezone TO 'UTC';
REVOKE ALL ON DATABASE "${database_name}" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE "${database_name}" TO "${role_name}";
SQL

install \
    -m 0600 \
    -o n1 \
    -g n1 \
    /dev/null \
    "$test_passfile"

printf \
    '127.0.0.1:5432:%s:%s:%s\n' \
    "$database_name" \
    "$role_name" \
    "$database_password" \
    > "$test_passfile"

chown n1:n1 "$test_passfile"
chmod 0600 "$test_passfile"

cleanup_test_passfile() {
    rm -f "$test_passfile"
}
trap cleanup_test_passfile EXIT

printf '\n===== APPLICATION CONNECTION TEST =====\n'
runuser -u n1 -- \
    env PGPASSFILE="$test_passfile" \
    psql \
    --no-psqlrc \
    --host=127.0.0.1 \
    --port=5432 \
    --username="$role_name" \
    --dbname="$database_name" \
    --tuples-only \
    --no-align \
    --command="SELECT current_user || '|' || current_database() || '|' || current_setting('TimeZone');"

printf '\n===== ROLE =====\n'
runuser -u postgres -- \
    psql \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --dbname=postgres \
    --command="SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname = '${role_name}';"

printf '\n===== DATABASE =====\n'
runuser -u postgres -- \
    psql \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --dbname=postgres \
    --command="SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${database_name}';"

printf '\n===== PASSWORD FILE =====\n'
stat \
    -c '%A %U:%G %s bytes %n' \
    "$password_file"

rm -f "$test_passfile"
trap - EXIT
unset database_password

printf '\nPostgreSQL initialization completed.\n'
