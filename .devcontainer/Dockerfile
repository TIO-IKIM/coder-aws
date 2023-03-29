# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.245.2/containers/debian/.devcontainer/base.Dockerfile

# [Choice] Debian version (use bullseye on local arm64/Apple Silicon): bullseye, buster
ARG VARIANT="buster"
FROM mcr.microsoft.com/vscode/devcontainers/base:0-${VARIANT}

# ** [Optional] Uncomment this section to install additional packages. **
# RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
#	&& apt-get -y install --no-install-recommends <your-package-list-here>

# Download eksctl into /usr/local/bin/
RUN architecture="amd64" \
	&& if [ "$(uname -m)" = "aarch64" ]; then architecture="arm64"; fi \
	&& mkdir /tmp/eksctl \
	&& curl -sL "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_Linux_${architecture}.tar.gz" | tar xz -C /tmp/eksctl \
	&& mv /tmp/eksctl/eksctl /usr/local/bin/ \
	&& rm -Rf /tmp/eksctl

# Download cmctl into /usr/local/bin/
RUN architecture="amd64" \
	&& if [ "$(uname -m)" = "aarch64" ]; then architecture="arm64"; fi \
	&& mkdir /tmp/cmctl \
	&& curl -sL "https://github.com/cert-manager/cert-manager/releases/latest/download/cmctl-linux-${architecture}.tar.gz" | tar xz -C /tmp/cmctl \
	&& mv /tmp/cmctl/cmctl /usr/local/bin/ \
	&& rm -Rf /tmp/cmctl

# Copy Coder into /usr/local/bin/
COPY --from=ghcr.io/coder/coder:latest /opt/coder /usr/local/bin/coder
