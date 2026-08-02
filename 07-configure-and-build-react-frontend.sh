#!/usr/bin/env bash
set -Eeuo pipefail

project_directory="${N1_FRONT_DIRECTORY:-/srv/n1/front}"
environment_file="${project_directory}/.env"
backup_directory='/root/.n1-backups/frontend-env'

minimum_node_version='22.22.0'
node_install_version="${N1_NODE_VERSION:-22.22.3}"

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this script as root.\n' >&2
    exit 1
fi

required_commands=(
    uname
    sort
    head
    grep
    sed
    tr
    mktemp
    install
    stat
    runuser
    git
    find
    du
    cp
    mv
    chmod
    chown
    ln
    id
)

for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$required_command" >&2
        exit 1
    fi
done

if ! id n1 >/dev/null 2>&1; then
    printf 'System user n1 does not exist.\n' >&2
    exit 1
fi

required_files=(
    "${project_directory}/package.json"
    "${project_directory}/package-lock.json"
    "${project_directory}/vite.config.js"
    "${project_directory}/src/main.jsx"
)

for required_file in "${required_files[@]}"; do
    if [ ! -f "$required_file" ]; then
        printf 'Required frontend file not found: %s\n' "$required_file" >&2
        exit 1
    fi
done

if [ ! -d "${project_directory}/.git" ]; then
    printf 'Frontend Git repository not found: %s\n' "$project_directory" >&2
    exit 1
fi

project_owner="$(
    stat -c '%U' "$project_directory"
)"

if [ "$project_owner" != 'n1' ]; then
    printf 'Unexpected frontend directory owner: %s (expected n1)\n' "$project_owner" >&2
    exit 1
fi

version_is_at_least() {
    local current_version="${1#v}"
    local required_version="${2#v}"
    local lowest_version=''

    lowest_version="$(
        printf '%s\n%s\n' \
            "$required_version" \
            "$current_version" \
            | sort -V \
            | head -n 1
    )"

    [ "$lowest_version" = "$required_version" ]
}

install_official_node() {
    local machine_architecture=''
    local node_architecture=''
    local node_archive=''
    local node_base_url=''
    local node_install_directory=''
    local temporary_directory=''
    local checksum_line=''

    machine_architecture="$(uname -m)"

    case "$machine_architecture" in
        x86_64)
            node_architecture='x64'
            ;;
        aarch64|arm64)
            node_architecture='arm64'
            ;;
        *)
            printf 'Unsupported CPU architecture for this installer: %s\n' "$machine_architecture" >&2
            exit 1
            ;;
    esac

    local packages_to_install=()

    command -v curl >/dev/null 2>&1 || packages_to_install+=(curl)
    command -v xz >/dev/null 2>&1 || packages_to_install+=(xz-utils)
    command -v tar >/dev/null 2>&1 || packages_to_install+=(tar)
    command -v sha256sum >/dev/null 2>&1 || packages_to_install+=(coreutils)

    if ((${#packages_to_install[@]} > 0)); then
        if ! command -v apt-get >/dev/null 2>&1; then
            printf 'apt-get is required to install: %s\n' "${packages_to_install[*]}" >&2
            exit 1
        fi

        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install \
            --yes \
            --no-install-recommends \
            ca-certificates \
            "${packages_to_install[@]}"
    fi

    node_archive="node-v${node_install_version}-linux-${node_architecture}.tar.xz"
    node_base_url="https://nodejs.org/dist/v${node_install_version}"
    node_install_directory="/opt/node-v${node_install_version}-linux-${node_architecture}"

    if [ ! -x "${node_install_directory}/bin/node" ]; then
        temporary_directory="$(mktemp -d /tmp/n1-node-install.XXXXXX)"

        cleanup_node_download() {
            rm -rf "$temporary_directory"
        }

        trap cleanup_node_download RETURN

        curl \
            --fail \
            --location \
            --silent \
            --show-error \
            "${node_base_url}/SHASUMS256.txt" \
            --output "${temporary_directory}/SHASUMS256.txt"

        curl \
            --fail \
            --location \
            --silent \
            --show-error \
            "${node_base_url}/${node_archive}" \
            --output "${temporary_directory}/${node_archive}"

        checksum_line="$(
            grep -E "  ${node_archive}$" \
                "${temporary_directory}/SHASUMS256.txt" \
                || true
        )"

        if [ -z "$checksum_line" ]; then
            printf 'Checksum for %s was not found in SHASUMS256.txt.\n' "$node_archive" >&2
            exit 1
        fi

        printf '%s\n' "$checksum_line" \
            > "${temporary_directory}/CHECKSUM"

        (
            cd "$temporary_directory"
            sha256sum \
                --check \
                --status \
                CHECKSUM
        )

        install \
            -d \
            -m 0755 \
            -o root \
            -g root \
            /opt

        tar \
            -xJf "${temporary_directory}/${node_archive}" \
            -C /opt

        chown \
            -R \
            root:root \
            "$node_install_directory"

        cleanup_node_download
        trap - RETURN
    fi

    ln -sfn \
        "${node_install_directory}/bin/node" \
        /usr/local/bin/node

    ln -sfn \
        "${node_install_directory}/bin/npm" \
        /usr/local/bin/npm

    ln -sfn \
        "${node_install_directory}/bin/npx" \
        /usr/local/bin/npx

    if [ -x "${node_install_directory}/bin/corepack" ]; then
        ln -sfn \
            "${node_install_directory}/bin/corepack" \
            /usr/local/bin/corepack
    fi

    hash -r
}

current_node_version=''

if command -v node >/dev/null 2>&1; then
    current_node_version="$(
        node --version
    )"
fi

printf '\n===== NODE.JS PREFLIGHT =====\n'
printf 'Current Node.js: %s\n' "${current_node_version:-not installed}"
printf 'Required Node.js: >=%s\n' "$minimum_node_version"

if [ -z "$current_node_version" ] \
    || ! version_is_at_least "$current_node_version" "$minimum_node_version"
then
    printf 'Installing official Node.js %s for the frontend build.\n' "$node_install_version"
    install_official_node
fi

current_node_version="$(
    /usr/local/bin/node --version
)"

if ! version_is_at_least "$current_node_version" "$minimum_node_version"; then
    printf 'Node.js version is still incompatible: %s\n' "$current_node_version" >&2
    exit 1
fi

printf 'Selected Node.js: %s\n' "$current_node_version"
printf 'Selected npm: %s\n' "$(
    env PATH='/usr/local/bin:/usr/bin:/bin' npm --version
)"

get_existing_api_url() {
    local line=''
    local value=''

    if [ -f "$environment_file" ]; then
        line="$(
            grep -m 1 -E '^VITE_API_BASE_URL=' "$environment_file" \
                || true
        )"
    fi

    if [ -z "$line" ]; then
        printf '%s' 'https://virtual-privat-n1.ru'
        return
    fi

    value="${line#*=}"

    if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

validate_http_url() {
    local value="$1"

    env \
        PATH='/usr/local/bin:/usr/bin:/bin' \
        node \
        --input-type=module \
        --eval '
            const value = process.argv[1];

            let parsed;

            try {
                parsed = new URL(value);
            } catch {
                process.exit(1);
            }

            if (!["http:", "https:"].includes(parsed.protocol)) {
                process.exit(1);
            }

            if (!parsed.hostname || parsed.username || parsed.password) {
                process.exit(1);
            }
        ' \
        "$value"
}

default_api_base_url="$(
    get_existing_api_url
)"

printf '\n===== FRONTEND CONFIGURATION =====\n'

frontend_api_base_url=''
IFS= read -r -p \
    "VITE_API_BASE_URL [${default_api_base_url}]: " \
    frontend_api_base_url

frontend_api_base_url="${frontend_api_base_url:-$default_api_base_url}"

while [[ "$frontend_api_base_url" == */ ]]; do
    frontend_api_base_url="${frontend_api_base_url%/}"
done

if ! validate_http_url "$frontend_api_base_url"; then
    printf 'VITE_API_BASE_URL must be an absolute HTTP(S) URL without credentials.\n' >&2
    exit 1
fi

printf '\n===== REVIEW =====\n'
printf 'Frontend directory: %s\n' "$project_directory"
printf 'Node.js: %s\n' "$current_node_version"
printf 'VITE_API_BASE_URL: %s\n' "$frontend_api_base_url"
printf 'Dependency installation: npm ci\n'
printf 'Quality check: npm run lint\n'
printf 'Production build: npm run build\n'

confirmation=''
IFS= read -r -p \
    'Write frontend .env and build production assets? [y/N]: ' \
    confirmation

case "${confirmation,,}" in
    y|yes)
        ;;
    *)
        printf 'Cancelled before changing frontend files.\n'
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
    backup_file="${backup_directory}/front.env.$(date +%Y%m%d-%H%M%S)"

    cp \
        --preserve=mode,ownership,timestamps \
        "$environment_file" \
        "$backup_file"

    chown root:root "$backup_file"
    chmod 0600 "$backup_file"

    printf 'Existing frontend .env backup: %s\n' "$backup_file"
fi

umask 077
temporary_environment_file="$(
    mktemp "${project_directory}/.env.tmp.XXXXXX"
)"

cleanup_temporary_environment() {
    rm -f "$temporary_environment_file"
}

trap cleanup_temporary_environment EXIT

printf 'VITE_API_BASE_URL=%s\n' "$frontend_api_base_url" \
    > "$temporary_environment_file"

chown n1:n1 "$temporary_environment_file"
chmod 0640 "$temporary_environment_file"

mv \
    "$temporary_environment_file" \
    "$environment_file"

trap - EXIT

printf '\n===== NPM CLEAN INSTALL =====\n'

runuser -u n1 -- \
    env PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix "$project_directory" \
    ci \
    --no-audit \
    --no-fund

printf '\n===== FRONTEND LINT =====\n'

runuser -u n1 -- \
    env PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix "$project_directory" \
    run \
    lint

printf '\n===== FRONTEND PRODUCTION BUILD =====\n'

runuser -u n1 -- \
    env PATH='/usr/local/bin:/usr/bin:/bin' \
    npm \
    --prefix "$project_directory" \
    run \
    build

printf '\n===== BUILD VERIFICATION =====\n'

required_build_files=(
    "${project_directory}/dist/index.html"
)

for required_build_file in "${required_build_files[@]}"; do
    if [ ! -f "$required_build_file" ]; then
        printf 'Required build file not found: %s\n' "$required_build_file" >&2
        exit 1
    fi
done

if [ ! -d "${project_directory}/dist/assets" ]; then
    printf 'Build assets directory not found: %s\n' "${project_directory}/dist/assets" >&2
    exit 1
fi

build_file_count="$(
    find "${project_directory}/dist" \
        -type f \
        | wc -l \
        | tr -d '[:space:]'
)"

printf 'Build directory: %s\n' "${project_directory}/dist"
printf 'Build files: %s\n' "$build_file_count"
printf 'Build size: '
du -sh "${project_directory}/dist" | awk '{print $1}'

printf '\n===== ENVIRONMENT FILE =====\n'
stat \
    -c '%A %U:%G %s bytes %n' \
    "$environment_file"

grep \
    -E '^VITE_API_BASE_URL=' \
    "$environment_file"

printf '\n===== GIT STATUS =====\n'

runuser -u n1 -- \
    git \
    -C "$project_directory" \
    status \
    --short \
    --branch

printf '\nFrontend production build completed.\n'
printf 'The build is not public yet; Nginx routing is configured at step 10.\n'
