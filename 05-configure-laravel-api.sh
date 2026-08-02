#!/usr/bin/env bash
set -Eeuo pipefail

project_directory='/srv/n1/api'
environment_file="${project_directory}/.env"
database_password_file='/root/.n1-secrets/api-db-password'
backup_directory='/root/.n1-backups/laravel-env'

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this script as root.\n' >&2
    exit 1
fi

required_commands=(
    bash
    composer
    php
    runuser
    mktemp
    install
    grep
    stat
    psql
    tr
    find
    date
    cp
    mv
    chmod
    chown
    id
)

for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$required_command" >&2
        exit 1
    fi
done

required_files=(
    "${project_directory}/artisan"
    "${project_directory}/composer.json"
    "${project_directory}/composer.lock"
    "${project_directory}/.gitignore"
)

for required_file in "${required_files[@]}"; do
    if [ ! -f "$required_file" ]; then
        printf 'Required file not found: %s\n' "$required_file" >&2
        exit 1
    fi
done

if ! id n1 >/dev/null 2>&1; then
    printf 'System user n1 does not exist.\n' >&2
    exit 1
fi

get_env_value() {
    local key="$1"
    local fallback="${2-}"
    local line=''
    local value=''

    if [ -f "$environment_file" ]; then
        line="$(
            grep -m 1 -E "^${key}=" "$environment_file" 2>/dev/null \
                || true
        )"
    fi

    if [ -z "$line" ]; then
        printf '%s' "$fallback"
        return
    fi

    value="${line#*=}"

    if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\\\"/\"}"
        value="${value//\\\\/\\}"
    elif [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

prompt_value() {
    local -n destination_ref="$1"
    local label="$2"
    local default_value="${3-}"
    local input_value=''

    if [ -n "$default_value" ]; then
        IFS= read -r -p "${label} [${default_value}]: " input_value
        input_value="${input_value:-$default_value}"
    else
        IFS= read -r -p "${label}: " input_value
    fi

    destination_ref="$input_value"
}

prompt_required() {
    local -n destination_ref="$1"
    local label="$2"
    local default_value="${3-}"
    local input_value=''

    while true; do
        if [ -n "$default_value" ]; then
            IFS= read -r -p "${label} [${default_value}]: " input_value
            input_value="${input_value:-$default_value}"
        else
            IFS= read -r -p "${label}: " input_value
        fi

        if [ -n "$input_value" ]; then
            destination_ref="$input_value"
            return
        fi

        printf '%s cannot be empty.\n' "$label" >&2
    done
}

prompt_secret() {
    local variable_name="$1"
    local label="$2"
    local existing_value="${3-}"
    local answer=''

    if [ -n "$existing_value" ] && [ "$existing_value" != 'null' ]; then
        IFS= read -r -s -p "${label} [press Enter to keep existing]: " answer
        printf '\n'
        answer="${answer:-$existing_value}"
    else
        while true; do
            IFS= read -r -s -p "${label}: " answer
            printf '\n'

            if [ -n "$answer" ]; then
                break
            fi

            printf '%s cannot be empty.\n' "$label" >&2
        done
    fi

    if [[ "$answer" == *$'\n'* || "$answer" == *$'\r'* ]]; then
        printf '%s contains a line break.\n' "$label" >&2
        exit 1
    fi

    printf -v "$variable_name" '%s' "$answer"
}

prompt_optional_secret() {
    local variable_name="$1"
    local label="$2"
    local existing_value="${3-}"
    local answer=''

    if [ -n "$existing_value" ] && [ "$existing_value" != 'null' ]; then
        IFS= read -r -s -p "${label} [press Enter to keep existing; type NULL to clear]: " answer
        printf '\n'

        if [ -z "$answer" ]; then
            answer="$existing_value"
        elif [ "$answer" = 'NULL' ]; then
            answer=''
        fi
    else
        IFS= read -r -s -p "${label} [optional]: " answer
        printf '\n'
    fi

    if [[ "$answer" == *$'\n'* || "$answer" == *$'\r'* ]]; then
        printf '%s contains a line break.\n' "$label" >&2
        exit 1
    fi

    printf -v "$variable_name" '%s' "$answer"
}

validate_url() {
    local label="$1"
    local value="$2"

    if [[ ! "$value" =~ ^https?://[^[:space:]]+$ ]]; then
        printf '%s must be an absolute HTTP(S) URL: %s\n' "$label" "$value" >&2
        exit 1
    fi
}

strip_trailing_slash() {
    local value="$1"

    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done

    printf '%s' "$value"
}

validate_positive_integer() {
    local label="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s must be a positive integer: %s\n' "$label" "$value" >&2
        exit 1
    fi
}

validate_boolean() {
    local label="$1"
    local value="${2,,}"

    case "$value" in
        true|false)
            ;;
        *)
            printf '%s must be true or false: %s\n' "$label" "$value" >&2
            exit 1
            ;;
    esac
}

validate_nullable_boolean() {
    local label="$1"
    local value="${2,,}"

    case "$value" in
        true|false|null)
            ;;
        *)
            printf '%s must be true, false, or null: %s\n' "$label" "$value" >&2
            exit 1
            ;;
    esac
}

validate_uuid_list() {
    local label="$1"
    local value="$2"
    local uuid_pattern='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

    if [[ ! "$value" =~ ^${uuid_pattern}(,${uuid_pattern})*$ ]]; then
        printf '%s must contain one or more comma-separated UUIDs.\n' "$label" >&2
        exit 1
    fi
}

validate_optional_uuid() {
    local label="$1"
    local value="$2"
    local uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

    if [ -n "$value" ] && [[ ! "$value" =~ $uuid_pattern ]]; then
        printf '%s must be empty or contain one UUID.\n' "$label" >&2
        exit 1
    fi
}

dotenv_quote() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"

    printf '"%s"' "$value"
}

write_env_string() {
    local key="$1"
    local value="$2"

    printf '%s=' "$key"
    dotenv_quote "$value"
    printf '\n'
}

write_env_raw() {
    local key="$1"
    local value="$2"

    printf '%s=%s\n' "$key" "$value"
}

current_app_key="$(get_env_value APP_KEY '')"
if [[ ! "$current_app_key" =~ ^base64: ]]; then
    current_app_key=''
fi

default_app_name="$(get_env_value APP_NAME 'N1')"
default_app_url="$(get_env_value APP_URL 'https://virtual-privat-n1.ru')"
default_frontend_origins="$(get_env_value FRONTEND_ORIGINS "$default_app_url")"

default_sanctum_domains="$(get_env_value SANCTUM_STATEFUL_DOMAINS '')"
if [ -z "$default_sanctum_domains" ]; then
    default_sanctum_domains="$(
        php -r '
            $origins = array_filter(array_map("trim", explode(",", $argv[1])));
            $domains = [];

            foreach ($origins as $origin) {
                $host = parse_url($origin, PHP_URL_HOST);
                $port = parse_url($origin, PHP_URL_PORT);

                if ($host === null || $host === false || $host === "") {
                    continue;
                }

                $domains[] = $port ? $host.":".$port : $host;
            }

            echo implode(",", array_values(array_unique($domains)));
        ' "$default_frontend_origins"
    )"
fi

printf '\n===== APPLICATION AND DOMAINS =====\n'

prompt_required app_name \
    'APP_NAME' \
    "$default_app_name"

prompt_required app_url \
    'APP_URL (Laravel public URL)' \
    "$default_app_url"
app_url="$(strip_trailing_slash "$app_url")"
validate_url APP_URL "$app_url"

prompt_required frontend_origins \
    'FRONTEND_ORIGINS (comma-separated origins)' \
    "$default_frontend_origins"

IFS=',' read -r -a frontend_origin_items <<< "$frontend_origins"
for frontend_origin_item in "${frontend_origin_items[@]}"; do
    frontend_origin_item="$(
        printf '%s' "$frontend_origin_item" | tr -d '[:space:]'
    )"
    validate_url FRONTEND_ORIGINS "$frontend_origin_item"
done
frontend_origins="$(
    printf '%s' "$frontend_origins" | tr -d '[:space:]'
)"

prompt_required sanctum_stateful_domains \
    'SANCTUM_STATEFUL_DOMAINS (without scheme; comma-separated)' \
    "$default_sanctum_domains"
sanctum_stateful_domains="$(
    printf '%s' "$sanctum_stateful_domains" | tr -d '[:space:]'
)"

printf '\n===== REMNAWAVE =====\n'

prompt_required remnawave_base_url \
    'REMNAWAVE_BASE_URL' \
    "$(get_env_value REMNAWAVE_BASE_URL 'https://panel.virtual-privat-n1.ru')"
remnawave_base_url="$(strip_trailing_slash "$remnawave_base_url")"
validate_url REMNAWAVE_BASE_URL "$remnawave_base_url"

prompt_secret remnawave_api_token \
    'REMNAWAVE_API_TOKEN' \
    "$(get_env_value REMNAWAVE_API_TOKEN '')"

prompt_required remnawave_internal_squad_uuids \
    'REMNAWAVE_ACTIVE_INTERNAL_SQUAD_UUIDS' \
    "$(get_env_value REMNAWAVE_ACTIVE_INTERNAL_SQUAD_UUIDS '01db8d9f-d5e2-4496-ad70-5d46a61cf8f2')"
remnawave_internal_squad_uuids="$(
    printf '%s' "$remnawave_internal_squad_uuids" | tr -d '[:space:]'
)"
validate_uuid_list \
    REMNAWAVE_ACTIVE_INTERNAL_SQUAD_UUIDS \
    "$remnawave_internal_squad_uuids"

prompt_value remnawave_external_squad_uuid \
    'REMNAWAVE_ACTIVE_EXTERNAL_SQUAD_UUID (optional)' \
    "$(get_env_value REMNAWAVE_ACTIVE_EXTERNAL_SQUAD_UUID '173a9ea4-e7a9-4e0b-921b-140888e9ab01')"
remnawave_external_squad_uuid="$(
    printf '%s' "$remnawave_external_squad_uuid" | tr -d '[:space:]'
)"
validate_optional_uuid \
    REMNAWAVE_ACTIVE_EXTERNAL_SQUAD_UUID \
    "$remnawave_external_squad_uuid"

prompt_required remnawave_connect_timeout \
    'REMNAWAVE_CONNECT_TIMEOUT' \
    "$(get_env_value REMNAWAVE_CONNECT_TIMEOUT '5')"
validate_positive_integer \
    REMNAWAVE_CONNECT_TIMEOUT \
    "$remnawave_connect_timeout"

prompt_required remnawave_request_timeout \
    'REMNAWAVE_REQUEST_TIMEOUT' \
    "$(get_env_value REMNAWAVE_REQUEST_TIMEOUT '15')"
validate_positive_integer \
    REMNAWAVE_REQUEST_TIMEOUT \
    "$remnawave_request_timeout"

printf '\n===== LOCALE, LOGGING, AND HASHING =====\n'

prompt_required app_locale \
    'APP_LOCALE' \
    "$(get_env_value APP_LOCALE 'en')"

prompt_required app_fallback_locale \
    'APP_FALLBACK_LOCALE' \
    "$(get_env_value APP_FALLBACK_LOCALE 'en')"

prompt_required app_faker_locale \
    'APP_FAKER_LOCALE' \
    "$(get_env_value APP_FAKER_LOCALE 'en_US')"

prompt_required app_maintenance_driver \
    'APP_MAINTENANCE_DRIVER' \
    "$(get_env_value APP_MAINTENANCE_DRIVER 'file')"

prompt_value app_maintenance_store \
    'APP_MAINTENANCE_STORE (optional; normally empty for file driver)' \
    "$(get_env_value APP_MAINTENANCE_STORE '')"

prompt_required bcrypt_rounds \
    'BCRYPT_ROUNDS' \
    "$(get_env_value BCRYPT_ROUNDS '12')"
validate_positive_integer BCRYPT_ROUNDS "$bcrypt_rounds"

prompt_required log_channel \
    'LOG_CHANNEL' \
    "$(get_env_value LOG_CHANNEL 'stack')"

prompt_required log_stack \
    'LOG_STACK' \
    "$(get_env_value LOG_STACK 'single')"

prompt_required log_deprecations_channel \
    'LOG_DEPRECATIONS_CHANNEL' \
    "$(get_env_value LOG_DEPRECATIONS_CHANNEL 'null')"

prompt_required log_level \
    'LOG_LEVEL' \
    "$(get_env_value LOG_LEVEL 'info')"

printf '\n===== PAYMENTS =====\n'

prompt_required payment_provider_driver \
    'PAYMENT_PROVIDER_DRIVER' \
    "$(get_env_value PAYMENT_PROVIDER_DRIVER 'stub')"

prompt_required payment_return_url \
    'PAYMENT_RETURN_URL' \
    "$(get_env_value PAYMENT_RETURN_URL "${frontend_origin_items[0]%/}/payment/return")"
validate_url PAYMENT_RETURN_URL "$payment_return_url"

prompt_required payment_stub_confirmation_url_base \
    'PAYMENT_STUB_CONFIRMATION_URL_BASE' \
    "$(get_env_value PAYMENT_STUB_CONFIRMATION_URL_BASE "$app_url")"
payment_stub_confirmation_url_base="$(
    strip_trailing_slash "$payment_stub_confirmation_url_base"
)"
validate_url \
    PAYMENT_STUB_CONFIRMATION_URL_BASE \
    "$payment_stub_confirmation_url_base"

prompt_required payment_stub_allow_insecure_loopback \
    'PAYMENT_STUB_ALLOW_INSECURE_LOOPBACK' \
    "$(get_env_value PAYMENT_STUB_ALLOW_INSECURE_LOOPBACK 'false')"
payment_stub_allow_insecure_loopback="${payment_stub_allow_insecure_loopback,,}"
validate_boolean \
    PAYMENT_STUB_ALLOW_INSECURE_LOOPBACK \
    "$payment_stub_allow_insecure_loopback"

printf '\n===== LOGIN CODES =====\n'

prompt_required login_code_delivery \
    'LOGIN_CODE_DELIVERY' \
    "$(get_env_value LOGIN_CODE_DELIVERY 'mail')"
login_code_delivery="${login_code_delivery,,}"

case "$login_code_delivery" in
    mail|browser)
        ;;
    *)
        printf 'LOGIN_CODE_DELIVERY must be mail or browser.\n' >&2
        exit 1
        ;;
esac

if [ "$login_code_delivery" = 'browser' ]; then
    printf 'LOGIN_CODE_DELIVERY=browser is not valid for APP_ENV=production.\n' >&2
    exit 1
fi

prompt_required login_code_lifetime_minutes \
    'LOGIN_CODE_LIFETIME_MINUTES' \
    "$(get_env_value LOGIN_CODE_LIFETIME_MINUTES '10')"
validate_positive_integer \
    LOGIN_CODE_LIFETIME_MINUTES \
    "$login_code_lifetime_minutes"

prompt_required login_code_maximum_attempts \
    'LOGIN_CODE_MAXIMUM_ATTEMPTS' \
    "$(get_env_value LOGIN_CODE_MAXIMUM_ATTEMPTS '5')"
validate_positive_integer \
    LOGIN_CODE_MAXIMUM_ATTEMPTS \
    "$login_code_maximum_attempts"

printf '\n===== POSTGRESQL =====\n'

prompt_required db_host \
    'DB_HOST' \
    "$(get_env_value DB_HOST '127.0.0.1')"

prompt_required db_port \
    'DB_PORT' \
    "$(get_env_value DB_PORT '5432')"
validate_positive_integer DB_PORT "$db_port"

prompt_required db_database \
    'DB_DATABASE' \
    "$(get_env_value DB_DATABASE 'n1_api')"

prompt_required db_username \
    'DB_USERNAME' \
    "$(get_env_value DB_USERNAME 'n1_api')"

existing_database_password="$(get_env_value DB_PASSWORD '')"

if [ -f "$database_password_file" ]; then
    generated_database_password="$(
        tr -d '\r\n' < "$database_password_file"
    )"

    if [ -n "$generated_database_password" ]; then
        existing_database_password="$generated_database_password"
    fi
fi

prompt_secret db_password \
    'DB_PASSWORD' \
    "$existing_database_password"

prompt_required db_timezone \
    'DB_TIMEZONE' \
    "$(get_env_value DB_TIMEZONE 'UTC')"

printf '\n===== SESSION, QUEUE, CACHE, AND STORAGE =====\n'

prompt_required session_driver \
    'SESSION_DRIVER' \
    "$(get_env_value SESSION_DRIVER 'database')"

prompt_required session_secure_cookie \
    'SESSION_SECURE_COOKIE' \
    "$(get_env_value SESSION_SECURE_COOKIE 'true')"
session_secure_cookie="${session_secure_cookie,,}"
validate_boolean SESSION_SECURE_COOKIE "$session_secure_cookie"

prompt_required session_same_site \
    'SESSION_SAME_SITE' \
    "$(get_env_value SESSION_SAME_SITE 'lax')"

prompt_required session_cookie \
    'SESSION_COOKIE' \
    "$(get_env_value SESSION_COOKIE 'n1_api_session')"

prompt_required session_lifetime \
    'SESSION_LIFETIME' \
    "$(get_env_value SESSION_LIFETIME '120')"
validate_positive_integer SESSION_LIFETIME "$session_lifetime"

prompt_required session_encrypt \
    'SESSION_ENCRYPT' \
    "$(get_env_value SESSION_ENCRYPT 'false')"
session_encrypt="${session_encrypt,,}"
validate_boolean SESSION_ENCRYPT "$session_encrypt"

prompt_required session_path \
    'SESSION_PATH' \
    "$(get_env_value SESSION_PATH '/')"

prompt_required session_domain \
    'SESSION_DOMAIN (null for host-only cookie)' \
    "$(get_env_value SESSION_DOMAIN 'null')"

prompt_required broadcast_connection \
    'BROADCAST_CONNECTION' \
    "$(get_env_value BROADCAST_CONNECTION 'log')"

prompt_required filesystem_disk \
    'FILESYSTEM_DISK' \
    "$(get_env_value FILESYSTEM_DISK 'local')"

prompt_required queue_connection \
    'QUEUE_CONNECTION' \
    "$(get_env_value QUEUE_CONNECTION 'database')"

prompt_required cache_store \
    'CACHE_STORE' \
    "$(get_env_value CACHE_STORE 'database')"

prompt_value cache_prefix \
    'CACHE_PREFIX (optional)' \
    "$(get_env_value CACHE_PREFIX '')"

prompt_required memcached_host \
    'MEMCACHED_HOST' \
    "$(get_env_value MEMCACHED_HOST '127.0.0.1')"

printf '\n===== REDIS COMPATIBILITY SETTINGS =====\n'

prompt_required redis_client \
    'REDIS_CLIENT' \
    "$(get_env_value REDIS_CLIENT 'phpredis')"

prompt_required redis_host \
    'REDIS_HOST' \
    "$(get_env_value REDIS_HOST '127.0.0.1')"

prompt_value redis_password \
    'REDIS_PASSWORD (null when unused)' \
    "$(get_env_value REDIS_PASSWORD 'null')"

prompt_required redis_port \
    'REDIS_PORT' \
    "$(get_env_value REDIS_PORT '6379')"
validate_positive_integer REDIS_PORT "$redis_port"

printf '\n===== MAIL =====\n'

prompt_required mail_mailer \
    'MAIL_MAILER' \
    "$(get_env_value MAIL_MAILER 'log')"

prompt_required mail_scheme \
    'MAIL_SCHEME (null, smtp, smtps, or another configured scheme)' \
    "$(get_env_value MAIL_SCHEME 'null')"

prompt_required mail_host \
    'MAIL_HOST' \
    "$(get_env_value MAIL_HOST '127.0.0.1')"

prompt_required mail_port \
    'MAIL_PORT' \
    "$(get_env_value MAIL_PORT '25')"
validate_positive_integer MAIL_PORT "$mail_port"

prompt_value mail_username \
    'MAIL_USERNAME (null when unused)' \
    "$(get_env_value MAIL_USERNAME 'null')"

prompt_optional_secret mail_password \
    'MAIL_PASSWORD' \
    "$(get_env_value MAIL_PASSWORD '')"

default_mail_from_address="$(
    php -r '
        $host = parse_url($argv[1], PHP_URL_HOST);
        echo "no-reply@".($host ?: "localhost");
    ' "$app_url"
)"

prompt_required mail_from_address \
    'MAIL_FROM_ADDRESS' \
    "$(get_env_value MAIL_FROM_ADDRESS "$default_mail_from_address")"

existing_mail_from_name="$(get_env_value MAIL_FROM_NAME "$app_name")"
if [ "$existing_mail_from_name" = '${APP_NAME}' ]; then
    existing_mail_from_name="$app_name"
fi

prompt_required mail_from_name \
    'MAIL_FROM_NAME' \
    "$existing_mail_from_name"

printf '\n===== AWS/S3 COMPATIBILITY SETTINGS =====\n'

prompt_value aws_access_key_id \
    'AWS_ACCESS_KEY_ID (optional)' \
    "$(get_env_value AWS_ACCESS_KEY_ID '')"

prompt_optional_secret aws_secret_access_key \
    'AWS_SECRET_ACCESS_KEY' \
    "$(get_env_value AWS_SECRET_ACCESS_KEY '')"

prompt_required aws_default_region \
    'AWS_DEFAULT_REGION' \
    "$(get_env_value AWS_DEFAULT_REGION 'us-east-1')"

prompt_value aws_bucket \
    'AWS_BUCKET (optional)' \
    "$(get_env_value AWS_BUCKET '')"

prompt_required aws_use_path_style_endpoint \
    'AWS_USE_PATH_STYLE_ENDPOINT' \
    "$(get_env_value AWS_USE_PATH_STYLE_ENDPOINT 'false')"
aws_use_path_style_endpoint="${aws_use_path_style_endpoint,,}"
validate_boolean \
    AWS_USE_PATH_STYLE_ENDPOINT \
    "$aws_use_path_style_endpoint"

printf '\n===== VITE COMPATIBILITY VALUE =====\n'

prompt_required vite_app_name \
    'VITE_APP_NAME' \
    "$(get_env_value VITE_APP_NAME "$app_name")"

printf '\n===== REVIEW =====\n'
printf 'APP_NAME: %s\n' "$app_name"
printf 'APP_ENV: production\n'
printf 'APP_DEBUG: false\n'
printf 'APP_URL: %s\n' "$app_url"
printf 'FRONTEND_ORIGINS: %s\n' "$frontend_origins"
printf 'SANCTUM_STATEFUL_DOMAINS: %s\n' "$sanctum_stateful_domains"
printf 'REMNAWAVE_BASE_URL: %s\n' "$remnawave_base_url"
printf 'REMNAWAVE_API_TOKEN: configured\n'
printf 'REMNAWAVE_ACTIVE_INTERNAL_SQUAD_UUIDS: %s\n' "$remnawave_internal_squad_uuids"
printf 'REMNAWAVE_ACTIVE_EXTERNAL_SQUAD_UUID: %s\n' "${remnawave_external_squad_uuid:-<empty>}"
printf 'DB: %s@%s:%s/%s\n' "$db_username" "$db_host" "$db_port" "$db_database"
printf 'DB_PASSWORD: configured\n'
printf 'PAYMENT_PROVIDER_DRIVER: %s\n' "$payment_provider_driver"
printf 'LOGIN_CODE_DELIVERY: %s\n' "$login_code_delivery"
printf 'MAIL_MAILER: %s\n' "$mail_mailer"
printf 'MAIL_PASSWORD: %s\n' "$([ -n "$mail_password" ] && printf configured || printf empty)"
printf 'APP_KEY: %s\n' "$([ -n "$current_app_key" ] && printf 'preserve existing' || printf 'generate new')"

confirmation=''
IFS= read -r -p 'Write the production .env and continue Laravel initialization? [y/N]: ' confirmation

case "${confirmation,,}" in
    y|yes)
        ;;
    *)
        printf 'Cancelled before changing files.\n'
        exit 0
        ;;
esac

install \
    -d \
    -m 0700 \
    -o root \
    -g root \
    "$backup_directory"

if [ -f "$environment_file" ]; then
    backup_file="${backup_directory}/api.env.$(date +%Y%m%d-%H%M%S)"
    cp \
        --preserve=mode,ownership,timestamps \
        "$environment_file" \
        "$backup_file"
    chmod 0600 "$backup_file"
    chown root:root "$backup_file"
    printf 'Existing .env backup: %s\n' "$backup_file"
fi

umask 077
temporary_environment_file="$(
    mktemp "${project_directory}/.env.tmp.XXXXXX"
)"

cleanup_temporary_environment() {
    rm -f "$temporary_environment_file"
}

trap cleanup_temporary_environment EXIT

{
    write_env_string APP_NAME "$app_name"
    write_env_raw APP_ENV production
    write_env_string APP_KEY "$current_app_key"
    write_env_raw APP_DEBUG false
    write_env_string APP_URL "$app_url"
    printf '\n'

    write_env_string REMNAWAVE_BASE_URL "$remnawave_base_url"
    write_env_string REMNAWAVE_API_TOKEN "$remnawave_api_token"
    write_env_raw REMNAWAVE_CONNECT_TIMEOUT "$remnawave_connect_timeout"
    write_env_raw REMNAWAVE_REQUEST_TIMEOUT "$remnawave_request_timeout"
    write_env_string REMNAWAVE_ACTIVE_INTERNAL_SQUAD_UUIDS "$remnawave_internal_squad_uuids"
    write_env_string REMNAWAVE_ACTIVE_EXTERNAL_SQUAD_UUID "$remnawave_external_squad_uuid"
    printf '\n'

    write_env_string APP_LOCALE "$app_locale"
    write_env_string APP_FALLBACK_LOCALE "$app_fallback_locale"
    write_env_string APP_FAKER_LOCALE "$app_faker_locale"
    printf '\n'

    write_env_string APP_MAINTENANCE_DRIVER "$app_maintenance_driver"
    if [ -n "$app_maintenance_store" ]; then
        write_env_string APP_MAINTENANCE_STORE "$app_maintenance_store"
    fi
    printf '\n'

    write_env_raw BCRYPT_ROUNDS "$bcrypt_rounds"
    printf '\n'

    write_env_string LOG_CHANNEL "$log_channel"
    write_env_string LOG_STACK "$log_stack"
    write_env_raw LOG_DEPRECATIONS_CHANNEL "$log_deprecations_channel"
    write_env_string LOG_LEVEL "$log_level"
    printf '\n'

    write_env_string FRONTEND_ORIGINS "$frontend_origins"
    write_env_string SANCTUM_STATEFUL_DOMAINS "$sanctum_stateful_domains"
    printf '\n'

    write_env_string PAYMENT_PROVIDER_DRIVER "$payment_provider_driver"
    write_env_string PAYMENT_RETURN_URL "$payment_return_url"
    write_env_string PAYMENT_STUB_CONFIRMATION_URL_BASE "$payment_stub_confirmation_url_base"
    write_env_raw PAYMENT_STUB_ALLOW_INSECURE_LOOPBACK "$payment_stub_allow_insecure_loopback"
    printf '\n'

    write_env_string LOGIN_CODE_DELIVERY "$login_code_delivery"
    write_env_raw LOGIN_CODE_LIFETIME_MINUTES "$login_code_lifetime_minutes"
    write_env_raw LOGIN_CODE_MAXIMUM_ATTEMPTS "$login_code_maximum_attempts"
    printf '\n'

    write_env_raw DB_CONNECTION pgsql
    write_env_string DB_HOST "$db_host"
    write_env_raw DB_PORT "$db_port"
    write_env_string DB_DATABASE "$db_database"
    write_env_string DB_USERNAME "$db_username"
    write_env_string DB_PASSWORD "$db_password"
    write_env_string DB_TIMEZONE "$db_timezone"
    printf '\n'

    write_env_string SESSION_DRIVER "$session_driver"
    write_env_raw SESSION_SECURE_COOKIE "$session_secure_cookie"
    write_env_string SESSION_SAME_SITE "$session_same_site"
    write_env_string SESSION_COOKIE "$session_cookie"
    write_env_raw SESSION_LIFETIME "$session_lifetime"
    write_env_raw SESSION_ENCRYPT "$session_encrypt"
    write_env_string SESSION_PATH "$session_path"
    if [ "$session_domain" = 'null' ]; then
        write_env_raw SESSION_DOMAIN null
    else
        write_env_string SESSION_DOMAIN "$session_domain"
    fi
    printf '\n'

    write_env_string BROADCAST_CONNECTION "$broadcast_connection"
    write_env_string FILESYSTEM_DISK "$filesystem_disk"
    write_env_string QUEUE_CONNECTION "$queue_connection"
    printf '\n'

    write_env_string CACHE_STORE "$cache_store"
    if [ -n "$cache_prefix" ]; then
        write_env_string CACHE_PREFIX "$cache_prefix"
    fi
    printf '\n'

    write_env_string MEMCACHED_HOST "$memcached_host"
    printf '\n'

    write_env_string REDIS_CLIENT "$redis_client"
    write_env_string REDIS_HOST "$redis_host"
    if [ "$redis_password" = 'null' ]; then
        write_env_raw REDIS_PASSWORD null
    else
        write_env_string REDIS_PASSWORD "$redis_password"
    fi
    write_env_raw REDIS_PORT "$redis_port"
    printf '\n'

    write_env_string MAIL_MAILER "$mail_mailer"
    if [ "$mail_scheme" = 'null' ]; then
        write_env_raw MAIL_SCHEME null
    else
        write_env_string MAIL_SCHEME "$mail_scheme"
    fi
    write_env_string MAIL_HOST "$mail_host"
    write_env_raw MAIL_PORT "$mail_port"
    if [ "$mail_username" = 'null' ] || [ -z "$mail_username" ]; then
        write_env_raw MAIL_USERNAME null
    else
        write_env_string MAIL_USERNAME "$mail_username"
    fi
    if [ -z "$mail_password" ]; then
        write_env_raw MAIL_PASSWORD null
    else
        write_env_string MAIL_PASSWORD "$mail_password"
    fi
    write_env_string MAIL_FROM_ADDRESS "$mail_from_address"
    write_env_string MAIL_FROM_NAME "$mail_from_name"
    printf '\n'

    write_env_string AWS_ACCESS_KEY_ID "$aws_access_key_id"
    write_env_string AWS_SECRET_ACCESS_KEY "$aws_secret_access_key"
    write_env_string AWS_DEFAULT_REGION "$aws_default_region"
    write_env_string AWS_BUCKET "$aws_bucket"
    write_env_raw AWS_USE_PATH_STYLE_ENDPOINT "$aws_use_path_style_endpoint"
    printf '\n'

    write_env_string VITE_APP_NAME "$vite_app_name"
} > "$temporary_environment_file"

chown n1:n1 "$temporary_environment_file"
chmod 0600 "$temporary_environment_file"

mv \
    "$temporary_environment_file" \
    "$environment_file"

trap - EXIT

install \
    -d \
    -m 0770 \
    -o n1 \
    -g n1 \
    "${project_directory}/storage/framework/cache/data" \
    "${project_directory}/storage/framework/sessions" \
    "${project_directory}/storage/framework/views" \
    "${project_directory}/storage/logs" \
    "${project_directory}/bootstrap/cache"

chown \
    -R \
    n1:n1 \
    "${project_directory}/storage" \
    "${project_directory}/bootstrap/cache"

find \
    "${project_directory}/storage" \
    "${project_directory}/bootstrap/cache" \
    -type d \
    -exec chmod 0770 {} +

find \
    "${project_directory}/storage" \
    "${project_directory}/bootstrap/cache" \
    -type f \
    -exec chmod 0660 {} +

umask 007

printf '\n===== CLEAR STALE LARAVEL CACHES =====\n'

runuser -u n1 -- \
    php \
    "${project_directory}/artisan" \
    optimize:clear

printf '\n===== COMPOSER INSTALL =====\n'

runuser -u n1 -- \
    composer \
    --working-dir="$project_directory" \
    install \
    --no-dev \
    --prefer-dist \
    --no-interaction \
    --no-progress \
    --optimize-autoloader

if [ -z "$current_app_key" ]; then
    printf '\n===== APPLICATION KEY =====\n'

    runuser -u n1 -- \
        php \
        "${project_directory}/artisan" \
        key:generate \
        --force \
        --no-interaction
else
    printf '\n===== APPLICATION KEY =====\n'
    printf 'Preserved the existing server APP_KEY.\n'
fi

printf '\n===== DATABASE MIGRATIONS =====\n'

runuser -u n1 -- \
    php \
    "${project_directory}/artisan" \
    migrate \
    --force \
    --no-interaction

tariff_seeder_status='not-present'

if [ -f "${project_directory}/database/seeders/TariffCatalogSeeder.php" ]; then
    printf '\n===== TARIFF CATALOG =====\n'

    runuser -u n1 -- \
        php \
        "${project_directory}/artisan" \
        db:seed \
        --class=TariffCatalogSeeder \
        --force \
        --no-interaction

    tariff_seeder_status='executed'
else
    printf '\n===== TARIFF CATALOG =====\n'
    printf 'SKIPPED: database/seeders/TariffCatalogSeeder.php is absent in the current checkout.\n'
fi

printf '\n===== LARAVEL CACHES =====\n'

runuser -u n1 -- \
    php \
    "${project_directory}/artisan" \
    config:cache

runuser -u n1 -- \
    php \
    "${project_directory}/artisan" \
    event:cache

runuser -u n1 -- \
    php \
    "${project_directory}/artisan" \
    view:cache

find \
    "${project_directory}/storage" \
    "${project_directory}/bootstrap/cache" \
    -type d \
    -exec chmod 0770 {} +

find \
    "${project_directory}/storage" \
    "${project_directory}/bootstrap/cache" \
    -type f \
    -exec chmod 0660 {} +

printf '\n===== PLATFORM REQUIREMENTS =====\n'

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

printf '\n===== DATABASE TABLES =====\n'

runuser -u postgres -- \
    psql \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --dbname="$db_database" <<'SQL'
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
SQL

printf '\n===== HEALTH ROUTE =====\n'

runuser -u n1 -- \
    php \
    "${project_directory}/artisan" \
    route:list \
    --path=api/v1/health

printf '\n===== REMNAWAVE CONFIG SUPPORT IN CURRENT CODE =====\n'

if grep -Rqs "REMNAWAVE_ACTIVE_INTERNAL_SQUAD_UUIDS" \
    "${project_directory}/config/remnawave.php" \
    "${project_directory}/app"
then
    printf 'Internal Squad variable is referenced by the current code.\n'
else
    printf 'WARNING: Internal Squad variable is written to .env but is not referenced by the current checkout.\n'
fi

if grep -Rqs "REMNAWAVE_ACTIVE_EXTERNAL_SQUAD_UUID" \
    "${project_directory}/config/remnawave.php" \
    "${project_directory}/app"
then
    printf 'External Squad variable is referenced by the current code.\n'
else
    printf 'WARNING: External Squad variable is written to .env but is not referenced by the current checkout.\n'
fi

printf '\n===== REMNAWAVE CHECK =====\n'

artisan_command_list="$(
    runuser -u n1 -- \
        php \
        "${project_directory}/artisan" \
        list \
        --raw
)"

if grep -q '^remnawave:check' <<< "$artisan_command_list"
then
    if runuser -u n1 -- \
        php \
        "${project_directory}/artisan" \
        remnawave:check
    then
        printf 'Remnawave check status: OK\n'
    else
        printf 'Remnawave check status: FAILED\n' >&2
    fi
else
    printf 'SKIPPED: remnawave:check command is absent in the current checkout.\n'
fi

printf '\n===== ENVIRONMENT FILE =====\n'

if grep -q '^APP_KEY="base64:' "$environment_file" \
    || grep -q '^APP_KEY=base64:' "$environment_file"
then
    printf 'APP_KEY: configured\n'
else
    printf 'APP_KEY: missing or invalid\n' >&2
    exit 1
fi

stat \
    -c '%A %U:%G %s bytes %n' \
    "$environment_file"

printf '\n===== GIT STATUS =====\n'

runuser -u n1 -- \
    git \
    -C "$project_directory" \
    status \
    --short \
    --branch

printf '\n===== INITIALIZATION RESULT =====\n'
printf 'Laravel base initialization completed.\n'
printf 'TariffCatalogSeeder: %s\n' "$tariff_seeder_status"

if [ "$tariff_seeder_status" = 'not-present' ]; then
    printf 'ACTION REQUIRED: update the production branch with the tariff migrations and TariffCatalogSeeder before tariffs can work.\n'
fi

printf 'The protected database-password file was retained at %s.\n' "$database_password_file"

unset db_password
unset existing_database_password
unset generated_database_password
unset remnawave_api_token
unset mail_password
unset aws_secret_access_key
