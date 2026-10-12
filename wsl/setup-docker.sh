#!/usr/bin/env bash
# Run as root inside the WSL Ubuntu distro (user-setup.ps1 does this).
# Sets up the default Linux user, Docker Engine with GPU support, and uv. Safe to re-run.
#
# Exit code 2 means systemd was just enabled and WSL needs restarting (wsl --shutdown), then re-run.
set -euo pipefail

LINUX_USER="${1:?usage: setup-docker.sh <linux-user>}"

# --- Default user --------------------------------------------------------------------------
if ! id "$LINUX_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$LINUX_USER"
    passwd -d "$LINUX_USER" >/dev/null
fi
# Passwordless sudo inside WSL only. It gives no Windows admin rights.
echo "$LINUX_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$LINUX_USER"
chmod 0440 "/etc/sudoers.d/90-$LINUX_USER"

# --- /etc/wsl.conf: systemd (needed for the docker service) and default user ---------------
cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[user]
default=$LINUX_USER
EOF

if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
    echo "systemd enabled; WSL needs a restart."
    exit 2
fi

export DEBIAN_FRONTEND=noninteractive

# --- Docker Engine (docs.docker.com/engine/install/ubuntu) --------------------------------
if ! command -v docker >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$LINUX_USER"
systemctl enable --now docker

# --- NVIDIA container toolkit (GPU access in containers) -----------------------------------
# The GPU driver itself comes from Windows; never install a Linux NVIDIA driver in WSL.
if ! command -v nvidia-ctk >/dev/null 2>&1; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
fi
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# --- uv for the Linux user ----------------------------------------------------------------
# WSL's network can take a few seconds to come up after a restart, so retry the download. (Piping
# curl straight into sh hid a failed download; this way a failure stops the script.)
if ! sudo -u "$LINUX_USER" -H bash -lc 'command -v uv' >/dev/null 2>&1; then
    for attempt in 1 2 3 4 5; do
        if curl -LsSf https://astral.sh/uv/install.sh -o /tmp/uv-install.sh; then break; fi
        echo "Couldn't download the uv installer (attempt $attempt of 5); retrying in 5 seconds..."
        sleep 5
    done
    sudo -u "$LINUX_USER" -H sh /tmp/uv-install.sh
    rm -f /tmp/uv-install.sh
fi

# --- Check the GPU is visible to containers -----------------------------------------------
# WSL exposes the Windows NVIDIA driver's tools under /usr/lib/wsl/lib. If they're not there
# (no NVIDIA GPU or driver, e.g. in a test VM), skip the check rather than fail.
if [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi
else
    echo "No NVIDIA driver visible to WSL (fine in a VM); skipping the GPU check."
    docker run --rm hello-world
fi
