#!/bin/bash

registry_host() {
    local image_ref="$1"
    local first_part="${image_ref%%/*}"

    if [ "$first_part" = "$image_ref" ]; then
        echo "docker.io"
    elif [[ "$first_part" == *.* || "$first_part" == *:* || "$first_part" == "localhost" ]]; then
        echo "$first_part"
    else
        echo "docker.io"
    fi
}

registry_credential_hint() {
    local host="$1"

    case "$host" in
        ghcr.io)
            echo "Set GHCR_USERNAME and GHCR_TOKEN, or pass username/password arguments."
            ;;
        docker.io | index.docker.io | registry-1.docker.io)
            echo "Set DOCKERHUB_USERNAME and DOCKERHUB_TOKEN, or pass username/password arguments."
            ;;
        *)
            echo "Set BOOTC_USERNAME and BOOTC_PASSWORD, or pass username/password arguments."
            ;;
    esac
}

registry_credentials() {
    local host="$1"
    local username_override="${2:-}"
    local password_override="${3:-}"
    local username=""
    local password=""

    if [ -n "$username_override" ] || [ -n "$password_override" ]; then
        username="$username_override"
        password="$password_override"
    else
        case "$host" in
            ghcr.io)
                username="${GHCR_USERNAME:-}"
                password="${GHCR_TOKEN:-}"
                ;;
            docker.io | index.docker.io | registry-1.docker.io)
                username="${DOCKERHUB_USERNAME:-}"
                password="${DOCKERHUB_TOKEN:-}"
                ;;
            *)
                username="${BOOTC_USERNAME:-}"
                password="${BOOTC_PASSWORD:-}"
                ;;
        esac
    fi

    printf '%s\n%s\n' "$username" "$password"
}

registry_has_credentials() {
    local image_ref="$1"
    local username_override="${2:-}"
    local password_override="${3:-}"
    local host
    local -a credentials
    local username
    local password

    host="$(registry_host "$image_ref")"
    mapfile -t credentials < <(registry_credentials "$host" "$username_override" "$password_override")
    username="${credentials[0]:-}"
    password="${credentials[1]:-}"

    [ -n "$username" ] && [ -n "$password" ]
}

registry_auth() {
    local action="$1"
    local image_ref="$2"
    local username_override="${3:-}"
    local password_override="${4:-}"
    local host
    local -a credentials
    local username
    local password

    host="$(registry_host "$image_ref")"
    mapfile -t credentials < <(registry_credentials "$host" "$username_override" "$password_override")
    username="${credentials[0]:-}"
    password="${credentials[1]:-}"

    if [ -z "$username" ] || [ -z "$password" ]; then
        echo "ERROR: missing credentials for ${image_ref} (${host})."
        echo "       $(registry_credential_hint "$host")"
        return 1
    fi

    case "$action" in
        check)
            return 0
            ;;
        podman-login)
            echo "## Logging into container registry: $host"
            printf '%s\n' "$password" | sudo podman login "$host" -u "$username" --password-stdin
            ;;
        oras-login)
            echo "## Logging into OCI artifact registry: $host"
            printf '%s\n' "$password" | oras login "$host" -u "$username" --password-stdin
            ;;
        *)
            echo "ERROR: unknown registry auth action: $action"
            return 1
            ;;
    esac
}
