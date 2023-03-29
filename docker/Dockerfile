ARG CUDA_VERSION=11.8.0
ARG UBUNTU_VERSION=22.04

FROM nvidia/cuda:${CUDA_VERSION}-base-ubuntu${UBUNTU_VERSION}

ARG USERNAME="coder"
ARG USER_UID=1000
ARG USER_GID=${USER_UID}
ARG CONDA_DIR=/opt/conda

# Copy conda from the miniconda image and make it available to all login shells.
COPY --from=continuumio/miniconda3:latest /opt/conda/ ${CONDA_DIR}/
RUN ln -s "$CONDA_DIR/etc/profile.d/conda.sh" /etc/profile.d/conda.sh

# Install OS utilities.
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get -y install --no-install-recommends \
        curl \
        ca-certificates \
        git \
        htop \
        openssh-client \
        rsync \
        sudo \
        unzip \
        vim \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user.
RUN groupadd --gid "$USER_GID" "$USERNAME" \
    && useradd -s /bin/bash --uid "$USER_UID" --gid "$USERNAME" -m "$USERNAME" \
    && echo "$USERNAME ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME" \
    && chmod 0440 "/etc/sudoers.d/$USERNAME"

USER ${USERNAME}
# Activate conda in non-login shells for this user.
RUN echo ". /etc/profile.d/conda.sh" >> ~/.bashrc
WORKDIR /home/${USERNAME}
CMD [ "bash" ]
