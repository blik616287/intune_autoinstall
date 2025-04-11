#!/bin/bash

set -ex

DEBIAN_FRONTEND=noninteractive

# Setup temporary directory
mkdir -p ${HOME}/tmp_setup_software
cd ${HOME}/tmp_setup_software

# Get the uuid from dmidecode
uuid=$(sudo dmidecode -s system-uuid)

# Check if uuid was successfully retrieved
if [ -z "$uuid" ]; then
    echo "Failed to retrieve system-uuid."
    exit 1
fi

# Extract the last 9 digits of the serial number
last_9_digits="${uuid: -12}"

# Create the new hostname by prefixing 'OXQLNX-' with the last 9 digits
new_hostname="OXQLNX-${last_9_digits}"

# Set the new hostname
sudo hostnamectl set-hostname "$new_hostname"

# Update /etc/hosts to reflect the new hostname
sudo sed -i "s/$(hostname)/$new_hostname/g" /etc/hosts

# Install Curl
sudo apt update
sudo apt install curl wget gpg -y

# Install Microsoft Edge Browser
curl  -s https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
sudo install -o root -g root -m 644 microsoft.gpg /usr/share/keyrings/
sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/$(lsb_release -rs)/prod $(lsb_release -cs) main" >> /etc/apt/sources.list.d/microsoft-ubuntu-$(lsb_release -cs)-prod.list'
sudo apt update
sudo install -o root -g root -m 644 microsoft.gpg /etc/apt/trusted.gpg.d/
sudo sh -c 'echo "deb [arch=amd64] https://packages.microsoft.com/repos/edge stable main" > /etc/apt/sources.list.d/microsoft-edge-stable.list'
sudo rm microsoft.gpg
sudo apt update && sudo apt install microsoft-edge-stable -y

# Install Microsoft Intune app
sudo apt install intune-portal -y

# Install 1Password:
curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg && \
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
sudo tee /etc/apt/sources.list.d/1password.list && \
sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/ && \
curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | \
sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol && \
sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22 && \
curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
sudo gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg && \
sudo apt update && sudo apt install 1password-cli

# Install VS Code
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | \
    sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
rm -f packages.microsoft.gpg
sudo apt install apt-transport-https -y
sudo apt update && sudo apt install code -y
