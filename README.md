# GitHub Actions Self-Hosted Runner

Custom GitHub Actions runner container image with configurable registration.

## Prerequisites

- Docker installed on host machine
- GitHub account with repository access
- Personal Access Token (PAT) with appropriate permissions
  - For repository runners: `repo` scope
  - For organization runners: `admin:org` scope

## Project Structure

```
github-actions-runner/
├── Dockerfile          # Container image definition
├── entrypoint.sh       # Runner registration and startup script
└── README.md           # This documentation
```

## Quick Start

1. Build the runner image:
```bash
docker build -t github-actions-runner:1.0.0 .
```

2. Run the container:
```bash
docker run -d --restart always \
  -e REPO_URL="https://github.com/username/repository" \
  -e GITHUB_PAT="your-pat-here" \
  -e LABELS="custom-image" \
  github-actions-runner:1.0.0
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `REPO_URL` | Yes | GitHub repository or organization URL (e.g. https://github.com/org/repo) |
| `GITHUB_PAT` | Yes | GitHub Personal Access Token (no whitespace/newlines) |
| `LABELS` | No | Custom labels for runner (comma-separated) |
| `RUNNER_WORKDIR` | No | Custom work directory (default: `/tmp/_work`) |
| `REGISTRATION_TOKEN_API_URL` | No | Optional internal endpoint that returns {"token":"..."} or a GitHub API URL |

## Using in Workflows

Example workflow using the self-hosted runner:

```yaml
name: Custom Runner Workflow
on: [push]

jobs:
  build:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v2
      - name: Test Runner
        run: echo "Running on self-hosted runner"
```

## Security Considerations

- Never commit PATs or sensitive information.
- Use GitHub Secrets for sensitive data.
- Rotate PATs immediately if exposed.
- Limit PAT scopes to the minimum required.
- Prefer short-lived tokens or an internal service that vends registration tokens.
- Rotate PATs regularly
- Review runner access permissions
- Consider network isolation requirements

## Customization

The base image includes:
- Ubuntu 24.04 LTS
- Essential build tools
- Azure CLI
- Docker CLI (for container operations)

To add additional tools, create a derived image:

```dockerfile
FROM github-actions-runner:1.0.0

USER root
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

USER runner
```

## Troubleshooting

### Common Issues

1. Runner fails to register:
```bash
# Check container logs
docker logs <container-id>

# Verify PAT permissions and REPO_URL
# Ensure network connectivity
```

2. "New-line characters are not allowed in header values." or whitespace errors:
- Ensure GITHUB_PAT and REGISTRATION_TOKEN_API_URL have no CR/LF or whitespace.
- Provide clean token (no trailing newline) or let the script strip CR/LF.
- Do not pass tokens via command history; use env file or secrets manager.

3. Runner disconnects:
- Check container health
- Verify GitHub connectivity
- Review Actions logs in GitHub

### Maintenance

1. Monitor runner status:
- GitHub repository → Settings → Actions → Runners

2. Update runner image:
```bash
# Build new version
docker build -t github-actions-runner:1.0.1 .

# Stop old runner and start new one
docker stop <container-id>
docker run -d [... environment variables ...] github-actions-runner:1.0.1
```

## Dockerfile — detailed explanation

This section explains the Dockerfile used to build the image.

- FROM ubuntu:24.04
  - Base image. Choose an LTS version for stability.

- ENV DEBIAN_FRONTEND=noninteractive \
      RUNNER_USER=runner \
      RUNNER_HOME=/home/runner \
      RUNNER_WORKDIR=/tmp/_work
  - Sets defaults: non-interactive apt, non-root user name, runner home, and workdir.

- ENV HOME=${RUNNER_HOME}
  - Ensures $HOME is set for the runner user so scripts relying on $HOME work correctly.

- apt-get update && apt-get install -y --no-install-recommends [...]
  - Installs minimal required packages (curl, jq, git, tar, unzip, docker CLI, etc.).
  - Keep the image minimal; language runtimes (Python/Node) should be added in derived images if needed.

- RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash && az version
  - Installs Azure CLI if you need Azure tooling. Remove if not required.

- RUN apt-get update && apt-get install -y --no-install-recommends <libs>
  - Installs shared libraries required by the GitHub Actions runner binaries.

- RUN useradd -m -d ${RUNNER_HOME} -s /bin/bash ${RUNNER_USER} \
      && mkdir -p ${RUNNER_HOME}/actions-runner ${RUNNER_WORKDIR} \
      && chown -R ${RUNNER_USER}:${RUNNER_USER} ${RUNNER_HOME} ${RUNNER_WORKDIR} \
      && usermod -aG docker ${RUNNER_USER}
  - Creates a dedicated non-root user for running the runner process and prepares directories.
  - Adds the user to the docker group so workflows that require docker (docker CLI) can run containers. (On some hosts you may prefer mounting docker socket and managing permissions on the host side.)

- WORKDIR ${RUNNER_HOME}/actions-runner
  - Sets working directory where the runner will be downloaded and run.

- COPY --chown=${RUNNER_USER}:${RUNNER_USER} entrypoint.sh /entrypoint.sh
  - Copies entrypoint and sets ownership to the runner user.

- RUN chmod +x /entrypoint.sh
  - Ensures entrypoint is executable.

- USER ${RUNNER_USER}
  - Switches to non-root user for runtime to follow least-privilege.

- ENTRYPOINT ["/entrypoint.sh"]
  - Starts the entrypoint which handles downloading, registering, and running the GitHub Actions runner.

Notes:
- Keep secrets out of the image. Pass tokens as runtime environment variables or use an internal token vending service.
- If you need docker-in-docker, consider carefully mounting /var/run/docker.sock and security implications.

## entrypoint.sh — detailed explanation

This file automates runner download, registration, lifecycle, and cleanup.

Key behavior and components:

- #!/usr/bin/env bash; set -euo pipefail
  - Strict mode: exit on errors, unset vars treated as errors, pipelines fail if any command fails.

- Constants:
  - RUNNER_DIR="${HOME}/actions-runner"
  - ARCH="x64"
  - RUNNER_ALLOW_RUNASROOT (optional)

- log() and error()
  - log writes human timestamps to stderr to avoid polluting stdout (stdout is reserved for returning token when needed).
  - error prints and exit with non-zero code.

- Environment validation:
  - : "${REPO_URL:?...}" ensures REPO_URL is provided.
  - LABELS defaulted if not set.

- Sanitize inputs:
  - Strips CR/LF from GITHUB_PAT and REGISTRATION_TOKEN_API_URL to prevent "new-line characters are not allowed in header values".
  - Validates GITHUB_PAT does not contain whitespace.

- get_registration_token()
  - Tries these methods (in order):
    1. If REGISTRATION_TOKEN_API_URL is provided:
       - If it points to api.github.com, POST to it and include Authorization header when GITHUB_PAT present.
       - Otherwise, treat it as a custom GET endpoint that returns JSON { "token": "..." }.
    2. If GITHUB_PAT provided:
       - Parses REPO_URL to determine host and repo path.
       - Chooses API base (api.github.com for GitHub.com; https://<host>/api/v3 for GitHub Enterprise).
       - Builds the correct endpoint for repo or org registration-token and POSTs with Authorization.
    - Parses JSON and returns the token on stdout. The function logs to stderr only, so command substitutions capture only token.

- Main flow:
  1. cd ${RUNNER_DIR}
  2. If runner not present, download the latest GitHub Actions runner tarball for the detected ARCH, extract it.
  3. raw_token="$(get_registration_token)" — captures token only (logging goes to stderr).
  4. Sanitizes token: remove CR/LF, validates emptiness, control characters, and whitespace.
  5. Calls ./config.sh --unattended --url "${REPO_URL}" --token "${token}" ... to register the runner.
  6. Sets trap cleanup EXIT INT TERM to remove runner registration on shutdown.
  7. Runs ./run.sh to start the runner loop.

- cleanup()
  - Attempts to obtain a fresh registration token and unregister the runner via ./config.sh remove --unattended --token "${token}".
  - This helps keep repository/organization clean after container stops.

Debugging and hardening tips:
- Keep log() writing to stderr so tokens returned from functions remain clean on stdout.
- Mask tokens in logs; never print full GITHUB_PAT or registration tokens to persistent logs.
- If you get whitespace/control-char errors, inspect raw responses with safe masked hex prints (first/last bytes) — do not expose full token.
- For GitHub Enterprise, ensure api base is constructed as https://HOST/api/v3.
- Use ephemeral tokens where possible (internal service that vends registration tokens).
- Run container with a read-only filesystem where possible and mount only the necessary directories.

---

# 📁 Copy Files & Folders from WSL to Windows (Local Path)

## 🔹 Understanding Path Differences

| Windows Path | WSL Path |
|--------------|----------|
| C:\Users\Name | /mnt/c/Users/Name |
| \ (backslash) | / (forward slash) |

⚠️ Never mix Windows and Linux path formats in the same command.

---

## 🔹 1️⃣ Find Your Current Folder Path in WSL

```bash
pwd
```

Example output:
```
/home/arijitjana/github-actions-runner
```

---

## 🔹 2️⃣ Copy a File from WSL to Windows

### Syntax
```bash
cp source_file destination_path
```

### Example
```bash
cp /home/arijitjana/github-actions-runner/entrypoint.sh \
/mnt/c/Users/arijit.jana/Downloads/Git_Runner/
```

---

## 🔹 3️⃣ Copy a Folder from WSL to Windows

Use `-r` for directories:

```bash
cp -r /home/arijitjana/project_folder \
/mnt/c/Users/arijit.jana/Downloads/
```

---

## 🔹 4️⃣ If Destination Folder Doesn't Exist

Create it first:

```bash
mkdir -p /mnt/c/Users/arijit.jana/Downloads/Git_Runner
```

Then copy.

---

## 🔹 5️⃣ Alternative Methods

### Open Current WSL Folder in Windows Explorer
```bash
explorer.exe .
```

### Access WSL from Windows
In File Explorer address bar:
```
\\wsl$
```

---

## 🔹 6️⃣ Recommended for Large Folders

```bash
rsync -av /home/arijitjana/project_folder \
/mnt/c/Users/arijit.jana/Downloads/
```

---

## ✅ Quick Rules

- Windows C drive in WSL → `/mnt/c/`
- Use `/` not `\`
- Use `-r` only for folders
- Use `pwd` to check your path

---

# 🐳 Copy Docker Image from WSL to Windows (Local Machine)

## 📌 Important Concept

Docker images are **not normal files**.  
You must first export them as a `.tar` file using `docker save`.

---

## 🔹 Step 1: Check Available Docker Images

```bash
docker images
```

Example output:

```
REPOSITORY    TAG       IMAGE ID       SIZE
my-app        latest    abcd1234       500MB
```

---

## 🔹 Step 2: Save Docker Image as TAR File

### Syntax
```bash
docker save -o output_file.tar image_name:tag
```

### Example
```bash
docker save -o my-app.tar my-app:latest
```

This creates:
```
my-app.tar
```

Verify:
```bash
ls
```

---

## 🔹 Step 3: Copy TAR File to Windows

Windows `C:` drive inside WSL is mounted at:

```
/mnt/c/
```

### Copy Command
```bash
cp my-app.tar /mnt/c/Users/your-username/Downloads/
```

---

## 🔹 🚀 Direct Save to Windows (Skip Copy Step)

You can save directly to Windows path:

```bash
docker save -o /mnt/c/Users/your-username/Downloads/my-app.tar my-app:latest
```

---

## 🔹 Step 4: Load Docker Image on Another Machine

```bash
docker load -i my-app.tar
```

Verify:
```bash
docker images
```

---

## 🔹 Optional: Share via Docker Hub

Login:
```bash
docker login
```

Tag image:
```bash
docker tag my-app yourdockerhubusername/my-app
```

Push image:
```bash
docker push yourdockerhubusername/my-app
```

---

## ✅ Quick Summary

| Task | Command |
|------|----------|
| View images | `docker images` |
| Save image | `docker save -o file.tar image:tag` |
| Copy to Windows | `cp file.tar /mnt/c/...` |
| Load image | `docker load -i file.tar` |

---

## 🧠 Key Reminder

| Windows Path | WSL Format |
|--------------|------------|
| C:\Users\Name | /mnt/c/Users/Name |
| \ (backslash) | / (forward slash) |

Never mix Windows and Linux path formats.

---

## Contributing

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## References

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Self-hosted Runners Documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
- [Docker Documentation](https://docs.docker.com/)
