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
├── entrypoint.sh      # Runner registration and startup script
└── README.md          # This documentation
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
| `REPO_URL` | Yes | GitHub repository or organization URL |
| `GITHUB_PAT` | Yes | GitHub Personal Access Token |
| `LABELS` | No | Custom labels for runner (comma-separated) |
| `RUNNER_WORKDIR` | No | Custom work directory (default: `/tmp/_work`) |

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

- Never commit PATs or sensitive information
- Use GitHub Secrets for sensitive data
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

# Verify PAT permissions
# Ensure network connectivity
```

2. Runner disconnects:
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

# Stop old runners
docker stop <container-id>

# Start new version
docker run -d [... environment variables ...] github-actions-runner:1.0.1
```

## Contributing

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## References

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Self-hosted Runners Documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
- [Docker Documentation](https://docs.docker.com/)
