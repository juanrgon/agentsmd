#!/usr/bin/env bash

set -euo pipefail

if [[ -n "${AGENTSMD_SOURCE_URL:-}" ]]; then
    SOURCE_URL="$AGENTSMD_SOURCE_URL"
else
    # GitHub caches raw branch URLs briefly. Use a unique URL so a just-pushed
    # main branch is not mistaken for the latest version.
    SOURCE_URL="https://raw.githubusercontent.com/juanrgon/agentsmd/main/agentsmd?cache=$(date +%s)-$$"
fi
INSTALL_DIR="${AGENTSMD_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_FILE="$INSTALL_DIR/agentsmd"
TEMP_FILE=""

cleanup() {
    if [[ -n "$TEMP_FILE" && -e "$TEMP_FILE" ]]; then
        rm "$TEMP_FILE"
    fi
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

display_path() {
    local file_path="$1"

    case "$file_path" in
        "$HOME")
            printf '~'
            ;;
        "$HOME"/*)
            printf '~/%s' "${file_path#"$HOME"/}"
            ;;
        *)
            printf '%s' "$file_path"
            ;;
    esac
}

next_backup_path() {
    local timestamp
    local backup_path
    local collision=2

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_path="$INSTALL_FILE.$timestamp.bak"

    while [[ -e "$backup_path" || -L "$backup_path" ]]; do
        backup_path="$INSTALL_FILE.$timestamp-$collision.bak"
        collision=$((collision + 1))
    done

    printf '%s' "$backup_path"
}

download() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$destination" "$url"
    else
        printf 'error: curl or wget is required\n' >&2
        exit 1
    fi
}

main() {
    local backup_path=""

    command -v bash >/dev/null 2>&1 || {
        printf 'error: bash is required\n' >&2
        exit 1
    }

    mkdir -p "$INSTALL_DIR"
    TEMP_FILE="$(mktemp "$INSTALL_DIR/.agentsmd.XXXXXX")"
    download "$SOURCE_URL" "$TEMP_FILE"

    if ! bash -n "$TEMP_FILE"; then
        printf 'error: downloaded agentsmd script is not valid Bash\n' >&2
        exit 1
    fi

    chmod 755 "$TEMP_FILE"

    if [[ -e "$INSTALL_FILE" || -L "$INSTALL_FILE" ]]; then
        backup_path="$(next_backup_path)"
        mv "$INSTALL_FILE" "$backup_path"
    fi

    mv "$TEMP_FILE" "$INSTALL_FILE"
    TEMP_FILE=""

    if [[ -n "$backup_path" ]]; then
        printf 'Backup: %s\n' "$(display_path "$backup_path")"
    fi

    printf 'Installed: %s\n' "$(display_path "$INSTALL_FILE")"

    case ":$PATH:" in
        *":$INSTALL_DIR:"*) ;;
        *) printf 'Add %s to PATH to run agentsmd directly.\n' "$(display_path "$INSTALL_DIR")" ;;
    esac
}

main "$@"
