#!/usr/bin/env bash
set -euo pipefail

# Constants
RUNNER_DIR="${HOME}/actions-runner"
ARCH="x64"  # Update this to "arm64" if needed
RUNNER_ALLOW_RUNASROOT="${RUNNER_ALLOW_RUNASROOT:-false}"

# Setup logging — send logs to stderr so command substitutions capture only stdout (token)
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

error() {
    log "ERROR: $1" >&2
    exit "${2:-1}"
}

# Validate required environment variables
: "${REPO_URL:?'REPO_URL env is required (e.g. https://github.com/org/repo)'}"
: "${LABELS:=}"

# Sanitize tokens/URLs: remove CR/LF characters that break HTTP headers
GITHUB_PAT="${GITHUB_PAT:-}"
REGISTRATION_TOKEN_API_URL="${REGISTRATION_TOKEN_API_URL:-}"

GITHUB_PAT="$(echo -n "$GITHUB_PAT" | tr -d '\r\n')"
REGISTRATION_TOKEN_API_URL="$(echo -n "$REGISTRATION_TOKEN_API_URL" | tr -d '\r\n')"

# Basic sanity: fail if PAT contains whitespace
if [[ -n "$GITHUB_PAT" && "$GITHUB_PAT" =~ [[:space:]] ]]; then
    error "GITHUB_PAT contains whitespace characters. Please provide a clean token."
fi

get_registration_token() {
    log "Getting registration token..."
    
    if [ -n "${REGISTRATION_TOKEN_API_URL:-}" ]; then
        log "Using REGISTRATION_TOKEN_API_URL: ${REGISTRATION_TOKEN_API_URL}"
        if echo "${REGISTRATION_TOKEN_API_URL}" | grep -q "api.github.com"; then
            # GitHub API endpoint - use POST with auth
            if [ -n "${GITHUB_PAT:-}" ]; then
                response=$(curl -fsS -X POST \
                    -H "Authorization: token ${GITHUB_PAT}" \
                    -H "Accept: application/vnd.github+json" \
                    "${REGISTRATION_TOKEN_API_URL}" 2>/dev/null || true)
            else
                response=$(curl -fsS -X POST \
                    -H "Accept: application/vnd.github+json" \
                    "${REGISTRATION_TOKEN_API_URL}" 2>/dev/null || true)
            fi
        else
            # Custom endpoint
            response=$(curl -fsS "${REGISTRATION_TOKEN_API_URL}" 2>/dev/null || true)
        fi
        
        token=$(echo "${response}" | jq -r .token 2>/dev/null || true)
        if [ -n "${token}" ] && [ "${token}" != "null" ]; then
            echo "${token}"
            return 0
        fi
        log "Warning: Failed to get token from REGISTRATION_TOKEN_API_URL. Response: ${response:-<empty>}"
    fi

    if [ -n "${GITHUB_PAT:-}" ]; then
        log "Using GITHUB_PAT to generate token..."
        
        # Parse REPO_URL
        host=$(echo "${REPO_URL}" | sed -E 's#https?://([^/]+).*#\1#')
        repo_path=$(echo "${REPO_URL}" | sed -E 's#https?://[^/]+/##; s#/*$##')

        # Determine API base URL
        if [[ "${host}" =~ ^(www\.)?github\.com$ ]]; then
            api_base="https://api.github.com"
        else
            api_base="https://${host}/api/v3"
        fi

        # Build API URL
        if echo "${repo_path}" | grep -q '/'; then
            api_url="${api_base}/repos/${repo_path}/actions/runners/registration-token"
        else
            api_url="${api_base}/orgs/${repo_path}/actions/runners/registration-token"
        fi

        log "Calling GitHub API: ${api_url}"
        response=$(curl -fsS -X POST \
            -H "Authorization: token ${GITHUB_PAT}" \
            -H "Accept: application/vnd.github+json" \
            "${api_url}" 2>/dev/null)
        
        token=$(echo "${response}" | jq -r .token)
        if [ -n "${token}" ] && [ "${token}" != "null" ]; then
            echo "${token}"
            return 0
        fi
        error "Failed to get token from GitHub API. Response: ${response}"
    fi

    error "Neither REGISTRATION_TOKEN_API_URL nor GITHUB_PAT provided."
}

cleanup() {
    log "Performing cleanup..."
    token=$(get_registration_token || true)
    if [ -n "${token:-}" ]; then
        ./config.sh remove --unattended --token "${token}" || true
    else
        log "Warning: Could not get token for cleanup. Runner may remain registered."
    fi
    exit 0
}

main() {
    cd "${RUNNER_DIR}"

    # Download runner if needed
    if [ ! -f "${RUNNER_DIR}/config.sh" ]; then
        log "Downloading GitHub Actions runner..."
        latest=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)
        tarball_url="https://github.com/actions/runner/releases/download/${latest}/actions-runner-linux-${ARCH}-${latest#v}.tar.gz"
        log "Latest runner: ${latest} -> ${tarball_url}"
        curl -fsSL "${tarball_url}" -o runner.tar.gz
        tar -xzf runner.tar.gz
        rm -f runner.tar.gz
    fi

    # Get registration token
    raw_token="$(get_registration_token)"
    # Log the raw token response for debugging
    # log "DEBUG: Raw token response: '$raw_token'"

    # Remove CR/LF that may come from envs or remote responses
    token="$(echo -n "$raw_token" | tr -d '\r\n')"

    # Fail if token is empty or contains whitespace/control chars
    if [ -z "$token" ]; then
        error "Registration token is empty (was: $(echo -n "$raw_token" | od -An -t x1 | sed 's/^ *//'))"
    fi

    # Detect any remaining ASCII control characters (0x00-0x1F,0x7F)
    if echo -n "$token" | od -An -t x1 | grep -Eq '\b(0[0-9]|1[0-9]|7f)\b' 2>/dev/null; then
        error "Registration token contains control characters"
    fi

    # Check for whitespace in the token
    if printf '%s' "$token" | grep -q '[[:space:]]'; then
        # log "DEBUG: Registration token value: '$token'"  # Print the token value for debugging
        error "Registration token contains whitespace characters"
    fi

    # Configure runner
    log "Configuring runner for ${REPO_URL}"
    if [ -f .runner ]; then
        log "Removing existing runner configuration..."
        ./config.sh remove --unattended --token "${token}" || true
        rm -f .runner
    fi

    log "Registering new runner..."
    ./config.sh \
        --unattended \
        --url "${REPO_URL}" \
        --token "${token}" \
        --name "$(hostname)-${RANDOM}" \
        --labels "${LABELS}" \
        --work "${RUNNER_WORKDIR:-_work}"

    # Set up cleanup trap
    trap cleanup EXIT INT TERM

    # Start runner
    log "Starting runner..."
    ./run.sh
}

# Start script
main "$@"