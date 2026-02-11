# Use Ubuntu 24.04 (latest LTS)
FROM ubuntu:24.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_USER=runner \
    RUNNER_HOME=/home/runner \
    RUNNER_WORKDIR=/tmp/_work

# Ensure HOME is set for the non-root user
ENV HOME=${RUNNER_HOME}

# Install system dependencies (no python/nodejs here; add in derived images)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    jq \
    sudo \
    tar \
    gzip \
    gnupg \
    lsb-release \
    apt-transport-https \
    zip \
    unzip \
    iputils-ping \
    docker.io \
    dnsutils \
    net-tools \
 && rm -rf /var/lib/apt/lists/*

# Install Azure CLI (as root)
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
 && az version

# Install dependencies for GitHub Actions runner
RUN apt-get update && apt-get install -y --no-install-recommends \
    libicu-dev \
    libssl3 \
    libkrb5-3 \
    zlib1g \
    libgcc-s1 \
    libstdc++6 \
 && rm -rf /var/lib/apt/lists/*

# Create non-root runner user and prepare workspace
RUN useradd -m -d ${RUNNER_HOME} -s /bin/bash ${RUNNER_USER} \
 && mkdir -p ${RUNNER_HOME}/actions-runner ${RUNNER_WORKDIR} \
 && chown -R ${RUNNER_USER}:${RUNNER_USER} ${RUNNER_HOME} ${RUNNER_WORKDIR} \
 && usermod -aG docker ${RUNNER_USER}

# Set working directory
WORKDIR ${RUNNER_HOME}/actions-runner

# Copy and setup entrypoint script
COPY --chown=${RUNNER_USER}:${RUNNER_USER} entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Switch to non-root user
USER ${RUNNER_USER}
ENV PATH="${RUNNER_HOME}/.local/bin:${PATH}"

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]