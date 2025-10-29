#!/usr/bin/env bash
set -euo pipefail

RUNNER_DIR="${HOME}/actions-runner"
cd "${RUNNER_DIR}"

# env inputs (expected)
: "${REPO_URL:?REPO_URL env is required (e.g. https://github.com/org/repo)}"
: "${LABELS:=}"   # optional
# You should provide either REGISTRATION_TOKEN_API_URL (recommended) or GITHUB_PAT to call GitHub API
# If REGISTRATION_TOKEN_API_URL is provided we do a simple GET/POST to fetch registration token JSON {token: "..."}
# Example: REGISTRATION_TOKEN_API_URL returns {"token":"..."} via a secure internal service.

get_registration_token() {
  if [ -n "${REGISTRATION_TOKEN_API_URL:-}" ]; then
    echo "Fetching registration token from REGISTRATION_TOKEN_API_URL..."
    token=$(curl -fsS "${REGISTRATION_TOKEN_API_URL}" | jq -r .token)
    echo "$token"
  elif [ -n "${GITHUB_PAT:-}" ]; then
    echo "Creating registration token via GitHub REST API using GITHUB_PAT..."
    # detect repo vs org based on REPO_URL
    # extract owner/repo from URL like https://github.com/owner/repo
    owner_repo=$(echo "${REPO_URL}" | sed -E 's#https?://github.com/##; s#/*$##')
    IFS='/' read -r owner repo <<< "$owner_repo"
    if [ -z "$repo" ]; then
      # org-level: REPO_URL might be https://github.com/org
      api_url="https://api.github.com/orgs/${owner}/actions/runners/registration-token"
    else
      api_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"
    fi
    token=$(curl -fsS -X POST -H "Authorization: token ${GITHUB_PAT}" -H "Accept: application/vnd.github+json" "${api_url}" | jq -r .token)
    echo "$token"
  else
    echo "ERROR: Neither REGISTRATION_TOKEN_API_URL nor GITHUB_PAT provided." >&2
    exit 2
  fi
}

# Download latest runner release into runner dir (if not present)
if [ ! -f "${RUNNER_DIR}/config.sh" ]; then
  echo "Downloading GitHub Actions runner..."
  # auto-detect arch x64; adjust for arm64 if needed
  ARCH="x64"
  # fetch latest release metadata and download tarball
  latest=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)
  tarball_url="https://github.com/actions/runner/releases/download/${latest}/actions-runner-linux-${ARCH}-${latest#v}.tar.gz"
  echo "Latest runner: ${latest} -> ${tarball_url}"
  curl -fsSL "${tarball_url}" -o runner.tar.gz
  tar -xzf runner.tar.gz
  rm -f runner.tar.gz
fi

token=$(get_registration_token)

# Configure runner
echo "Configuring runner for ${REPO_URL}"
# cleanup previous config if exists
if [ -f .runner ]; then
  echo "Runner already configured - removing previous config..."
  ./config.sh remove --unattended --token "${token}" || true
  rm -f .runner
fi

# configure
./config.sh --unattended --url "${REPO_URL}" --token "${token}" --name "$(hostname)-${RANDOM}" --labels "${LABELS}" --work "${RUNNER_WORKDIR}"

# When the container stops we should remove the runner
cleanup() {
  echo "Cleaning up runner registration..."
  # the remove command needs a fresh token to unregister; try with GITHUB_PAT or the REGISTRATION_TOKEN_API_URL
  if [ -n "${REGISTRATION_TOKEN_API_URL:-}" ]; then
    token2=$(curl -fsS "${REGISTRATION_TOKEN_API_URL}" | jq -r .token)
    ./config.sh remove --unattended --token "${token2}" || true
  elif [ -n "${GITHUB_PAT:-}" ]; then
    token2=$(curl -fsS -X POST -H "Authorization: token ${GITHUB_PAT}" -H "Accept: application/vnd.github+json" "$(echo "${REPO_URL}" | sed -E 's#https?://github.com/##; s#/*$##' | awk -F/ '{if (NF==1) print "https://api.github.com/orgs/"$1"/actions/runners/registration-token"; else print "https://api.github.com/repos/"$1"/"$2"/actions/runners/registration-token"}')" | jq -r .token) || true
    ./config.sh remove --unattended --token "${token2}" || true
  else
    echo "No token method available for cleanup; runner may remain registered." >&2
  fi
  exit
}

trap 'cleanup' EXIT INT TERM

# run the runner (this blocks)
./run.sh
