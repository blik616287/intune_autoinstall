#!/bin/bash

set -e

# Static variables
export TIMEZONE="UTC"

# Configuration variables
export VM_NAME="${VM_NAME:-ubuntu-encrypted2}"
export FILE_URL="${FILE_URL:-https://releases.ubuntu.com/jammy/ubuntu-22.04.5-live-server-amd64.iso}"
export CHECKSUMS="${CHECKSUMS:-https://releases.ubuntu.com/jammy/SHA256SUMS}"
export VM_MEMORY="${VM_MEMORY:-4096}"
export VM_CPUS="${VM_CPUS:-2}"
export VM_DISK_SIZE="${VM_DISK_SIZE:-25000}"
export USERN="${USERN:-ubuntu}"
export PASSWORD="${PASSWORD:-ubuntu}"
export VM_NAME="${VM_NAME:-ubuntu-encrypted2}"
export TOUCHLESS="${TOUCHLESS:-true}"

# Setup file renders
unset file_data
declare -A file_data

# Function to process files in static and templates directories
process_directories() {
  for dir in "static" "templates"; do
    if [ -d "$dir" ]; then
      mapfile -t files < <(find "$dir" -type f)
      for file in "${files[@]}"; do
        filename=$(basename "$file")
        if [ "$dir" = "templates" ]; then
          b64_content=$(envsubst < "$file" | bzip2 -c | base64 -w 0)
        else
          b64_content=$(bzip2 -c "$file" | base64 -w 0)
        fi
        file_data["$filename"]="$b64_content"
        echo "Adding $filename to file_data array" >&2
      done
    else
      echo "Warning: $dir directory not found." >&2
    fi
  done
  echo "Array contents after processing:" >&2
  for key in "${!file_data[@]}"; do
    echo "  $key is present" >&2
  done
  serialized=""
  for key in "${!file_data[@]}"; do
    serialized+="$key:::::${file_data[$key]};;;;;"
  done
  export SERIALIZED_FILE_DATA="$serialized"
  echo "Serialized data exported as SERIALIZED_FILE_DATA" >&2
  return 0
}

# Helper function to retrieve data
get_file_data() {
  local filename="$1"
  local serialized="$SERIALIZED_FILE_DATA"
  echo "Looking for '$filename' in serialized data" >&2
  local pattern="$filename:::::([^;;;;;]*)"
  if [[ "$serialized" =~ $pattern ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  else
    echo "Error: File '$filename' not found in the processed data." >&2
    return 1
  fi
}
export -f get_file_data

# Helper function to decode b64 data
decode_file_data() {
  local filename="$1"
  local b64_content=$(get_file_data "$filename")
  if [ $? -ne 0 ]; then
    return 1
  fi
  echo "$b64_content" | base64 -d | bunzip2
  return $?
}

# Validations
process_directories
#get_file_data novnc.service
#decode_file_data novnc.service

# Check if we need to download the ISO
ISO_NAME=$(basename "$FILE_URL")
if [ -f "${ISO_NAME}" ]; then
    echo "File ${ISO_NAME} already exists. Skipping download."
else
    echo "File ${ISO_NAME} does not exist. Downloading..."
    wget -O "${ISO_NAME}" "${FILE_URL}"
    echo "Download complete."
fi
ISO_PATH="$(pwd)/${ISO_NAME}"
echo "Using Ubuntu ISO: ${ISO_PATH}"

# Calculate SHA256 checksum of the ISO file
echo "Calculating SHA256 checksum for $ISO_NAME..."
CHECKSUM_OUTPUT_FILE="$ISO_NAME.sha256"
wget -q "$CHECKSUMS" -O "$CHECKSUM_OUTPUT_FILE"
if [ $? -ne 0 ]; then
    echo "Error: Failed to download SHA256SUMS file."
    exit 1
fi
ISO_CHECKSUM=$(sha256sum "$ISO_NAME" | cut -d' ' -f1)
EXPECTED_CHECKSUM=$(grep "$ISO_NAME" "$CHECKSUM_OUTPUT_FILE" | cut -d' ' -f1)
if [ -z "$EXPECTED_CHECKSUM" ]; then
    echo "Warning: No matching entry for '$ISO_NAME' found in SHA256SUMS file."
    echo "Available ISO files in SHA256SUMS:"
    cat "$CHECKSUM_FILE" | awk '{print $2}'
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "Local ISO checksum: ${ISO_CHECKSUM}"
echo "Expected ISO checksum: ${EXPECTED_CHECKSUM}"
if [ ! "$ISO_CHECKSUM" = "$EXPECTED_CHECKSUM" ]; then
    echo "Checksum failed"
    exit 1
fi
echo "Checksum succeeded"

# Check if VirtualBox Extension Pack is installed
if VBoxManage list extpacks | grep -q "Oracle VM VirtualBox Extension Pack"; then
    echo "VirtualBox Extension Pack is already installed."
else
    echo "VirtualBox Extension Pack is not installed. Installing..."
    vbox_version=$(VBoxManage --version | cut -d 'r' -f 1)
    major_version=$(echo "${vbox_version}" | cut -d '.' -f 1)
    minor_version=$(echo "${vbox_version}" | cut -d '.' -f 2)
    echo "Downloading Extension Pack for VirtualBox ${major_version}.${minor_version}..."
    curl -O "https://download.virtualbox.org/virtualbox/${major_version}.${minor_version}/Oracle_VM_VirtualBox_Extension_Pack-${vbox_version}.vbox-extpack"
    echo "Installing Extension Pack..."
    sudo VBoxManage extpack install --replace "Oracle_VM_VirtualBox_Extension_Pack-${vbox_version}.vbox-extpack"
    rm "Oracle_VM_VirtualBox_Extension_Pack-${vbox_version}.vbox-extpack"
    echo "VirtualBox Extension Pack installation complete."
fi

# Check for required tools
if ! command -v cloud-localds &> /dev/null; then
    echo "cloud-localds not found. Installing cloud-image-utils..."
    sudo apt-get update && sudo apt-get install -y cloud-image-utils
fi

# Create a temporary directory for our configuration files
TEMP_DIR="${PWD}/tmp"
rm -rf "${TEMP_DIR}" || true
mkdir -p "${TEMP_DIR}"
echo "Working directory: ${TEMP_DIR}"

# Function to clean up on exit
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

# Create autoinstall user-data file with LUKS encryption configuration
cat > "${TEMP_DIR}/user-data" << EOF
#cloud-config
write_files:
- encoding: b64
  content: $(get_file_data novnc.service)
  owner: root:root
  path: /tmp/novnc.service.bz2
  permissions: '0644'
- encoding: b64
  content: $(get_file_data x11vnc.service)
  owner: root:root
  path: /tmp/x11vnc.service.bz2
  permissions: '0644'
- encoding: b64
  content: $(get_file_data gnome-session-xvfb.service)
  owner: root:root
  path: /tmp/gnome-session-xvfb.service.bz2
  permissions: '0644'
- encoding: b64
  content: $(get_file_data xvfb.service)
  owner: root:root
  path: /tmp/xvfb.service.bz2
  permissions: '0644'
- encoding: b64
  content: $(get_file_data setup_software.sh)
  owner: root:root
  path: /tmp/setup_software.sh.bz2
  permissions: '0755'
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${VM_NAME}
    username: ${USERN}
    password: $(echo ${PASSWORD} | openssl passwd -6 -stdin)
  ssh:
    install-server: true
    allow-pw: true
  network:
    network:
      version: 2
      ethernets:
        enp0s3:
          dhcp4: true
  storage:
    layout:
      name: lvm
      match:
        size: largest
      encrypted: true
      password: "${PASSWORD}"
  packages:
    - openssh-server
    - cryptsetup
    - lvm2
    - build-essential
    - dkms
    - linux-headers-generic
    - bzip2
    - ubuntu-gnome-desktop
    - x11vnc
    - novnc
    - websockify
    - xvfb
  early-commands:
    - echo 'Autoinstall in progress...'
  late-commands:
    # Copy static content to target
    - mkdir -p /target/tmp
    - cp /tmp/*.bz2 /target/tmp/

    # Ensure user exists in the installed system
    - curtin in-target --target=/target -- bash -c "getent passwd ${USERN} > /dev/null || useradd -m -s /bin/bash ${USERN}"
    - curtin in-target --target=/target -- bash -c "echo \"${USERN}:${PASSWORD}\" | chpasswd"
    - curtin in-target --target=/target -- bash -c "echo \"${USERN} ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/${USERN}"
    - curtin in-target --target=/target -- bash -c "chmod 440 /etc/sudoers.d/${USERN}"

    # Configure SSH with X11 forwarding
    - curtin in-target --target=/target -- bash -c "sed -i 's/#X11Forwarding no/X11Forwarding yes/' /etc/ssh/sshd_config"
    - curtin in-target --target=/target -- bash -c "sed -i 's/#X11DisplayOffset 10/X11DisplayOffset 10/' /etc/ssh/sshd_config"
    - curtin in-target --target=/target -- bash -c "sed -i 's/#X11UseLocalhost yes/X11UseLocalhost yes/' /etc/ssh/sshd_config"

    # Ensure VNC dependancies are present
    - curtin in-target --target=/target -- bash -c "mkdir -p /etc/x11vnc"
    - curtin in-target --target=/target -- bash -c "x11vnc -storepasswd \"${PASSWORD}\" /etc/x11vnc.passwd"
    - curtin in-target --target=/target -- bash -c "chmod 640 /etc/x11vnc.passwd"
    - curtin in-target --target=/target -- bash -c "chown root:${USERN} /etc/x11vnc.passwd"
    - curtin in-target --target=/target -- bash -c "touch /var/log/x11vnc.log"
    - curtin in-target --target=/target -- bash -c "chmod 660 /var/log/x11vnc.log"
    - curtin in-target --target=/target -- bash -c "chown root:${USERN} /var/log/x11vnc.log"

    # Setup service files for VNC support
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/x11vnc.service.bz2 > /etc/systemd/system/x11vnc.service"
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/novnc.service.bz2 > /etc/systemd/system/novnc.service"
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/gnome-session-xvfb.service.bz2 > /etc/systemd/system/gnome-session-xvfb.service"
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/xvfb.service.bz2 > /etc/systemd/system/xvfb.service"

    # Base VNC services
    - curtin in-target --target=/target -- systemctl stop novnc.service || true
    - curtin in-target --target=/target -- systemctl stop x11vnc.service || true
    - curtin in-target --target=/target -- systemctl daemon-reload
    - curtin in-target --target=/target -- systemctl enable xvfb.service
    - curtin in-target --target=/target -- systemctl enable gnome-session-xvfb.service
    - curtin in-target --target=/target -- systemctl enable x11vnc.service
    - curtin in-target --target=/target -- systemctl enable novnc.service

    # Install software
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/setup_software.sh.bz2 > /usr/local/bin/setup-software.sh"
    - curtin in-target --target=/target -- bash -c "chmod 755 /usr/local/bin/setup-software.sh"

  user-data:
    disable_root: true
    runcmd:
      # Install MDM software
      - su -c "/usr/local/bin/setup-software.sh" ubuntu

      # Run VBoxGuestAdditions
      - mkdir -p /mnt/cdrom
      - mount /dev/sr2 /mnt/cdrom
      - cd /mnt/cdrom && ./VBoxLinuxAdditions.run

      # Set nomodeset boot parameter for framebuffer fix on tty console
      - grep -q nomodeset /etc/default/grub || sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="nomodeset"/' /etc/default/grub
      - update-grub

      # Reboot
      - reboot
EOF
#cloud-init schema -c "${TEMP_DIR}/user-data" --annotate

# Create an empty meta-data file (required for cloud-init)
touch "${TEMP_DIR}/meta-data"

# Create cloud-init ISO for autoinstallation
echo "Creating autoinstall seed ISO..."
cloud-localds "${TEMP_DIR}/seed.iso" "${TEMP_DIR}/user-data" "${TEMP_DIR}/meta-data"

# Check if VM already exists
if VBoxManage list vms | grep -q "\"${VM_NAME}\""; then
    echo "Warning: VM '${VM_NAME}' already exists. Removing it..."
    VBoxManage unregistervm "${VM_NAME}" --delete
fi

# Create the VM
echo "Creating VM: ${VM_NAME}"
VBoxManage createvm --name "${VM_NAME}" --ostype "Ubuntu_64" --register

# Set VM properties
echo "Configuring VM..."
VBoxManage modifyvm "${VM_NAME}" --memory "${VM_MEMORY}" --cpus "${VM_CPUS}"
VBoxManage modifyvm "${VM_NAME}" --graphicscontroller vboxsvga --vram 16

# Set network to NAT
echo "Setting network adapter to NAT..."
VBoxManage modifyvm "${VM_NAME}" --nic1 nat

# Set vm to UTC
VBoxManage modifyvm "${VM_NAME}" --rtcuseutc on

# Create and attach virtual disk
echo "Creating virtual disk..."
VM_DISK="$(VBoxManage list systemproperties | grep "Default machine folder" | cut -d':' -f2 | xargs)/${VM_NAME}/${VM_NAME}.vdi"
VBoxManage createmedium disk --filename "${VM_DISK}" --size "${VM_DISK_SIZE}"

# Attach storage controllers
VBoxManage storagectl "${VM_NAME}" --name "SATA Controller" --add sata --controller IntelAHCI
VBoxManage storageattach "${VM_NAME}" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "${VM_DISK}"

# Attach the Ubuntu ISO and the seed ISO to the VM
VBoxManage storagectl "${VM_NAME}" --name "IDE Controller" --add ide
VBoxManage storageattach "${VM_NAME}" --storagectl "IDE Controller" --port 0 --device 0 --type dvddrive --medium "${ISO_PATH}"
VBoxManage storageattach "${VM_NAME}" --storagectl "IDE Controller" --port 1 --device 0 --type dvddrive --medium "${TEMP_DIR}/seed.iso"
VBoxManage storageattach "${VM_NAME}" --storagectl "IDE Controller" --port 1 --device 1 --type dvddrive --medium /usr/share/virtualbox/VBoxGuestAdditions.iso

# Set boot order: DVD first, then hard disk
VBoxManage modifyvm "${VM_NAME}" --boot1 dvd --boot2 disk --boot3 none --boot4 none
VBoxManage setextradata "${VM_NAME}" "BootArgs" "autoinstall ds=nocloud;s=/cdrom/ debug=1 ipv6.disable=1"

# Enable the USB controller with USB 3.0 (xHCI) support
echo "Enabling USB 3.0 controller..."
VBoxManage modifyvm "${VM_NAME}" --usbxhci on

# Setup shared folder
echo "Enabling shared folder"
VBoxManage sharedfolder add "${VM_NAME}" --name "host_root" --hostpath / --automount

# Configure NAT port forwarding for SSH and VNC
echo "Setting up NAT port forwarding..."
VBoxManage modifyvm "${VM_NAME}" --natpf1 "ssh,tcp,,2222,,22"
VBoxManage modifyvm "${VM_NAME}" --natpf1 "vnc,tcp,,6080,,6080"

# Start the installation
echo "Installation started:" | tee install_info.txt
echo "---------------------------------------------------------------" | tee -a install_info.txt
echo "VM Name: ${VM_NAME}" | tee -a install_info.txt
echo "Username: ${USERN}" | tee -a install_info.txt
echo "Password: ${PASSWORD} (also used for disk encryption)" | tee -a install_info.txt

# Interactive installation
if [ "$TOUCHLESS" = false ]; then
  # Start the VM
  echo "Starting VM: ${VM_NAME}"
  VBoxManage startvm "${VM_NAME}"
  trap - EXIT
  exit 0
fi

# Touchless installation
echo "Starting VM: ${VM_NAME}"
VBoxManage startvm "${VM_NAME}" --type=headless

# Continue with the automated touchless setup
echo "Touchless setup mode selected"
echo "Sleeping for 60s for grub boot timout"
sleep 60

# Function to check if VM is accessible
check_vm_accessible() {
  VBoxManage guestcontrol "${VM_NAME}" run --exe "/usr/sbin/ip" --username "${USERN}" --password "${PASSWORD}" -- -f inet addr show > /dev/null 2>&1
  return $?
}

# Main loop to wait until VM is accessible
while ! check_vm_accessible; do
  echo "VM not yet accessible, please wait..."
  VBoxManage controlvm "${VM_NAME}" keyboardputstring "${PASSWORD}" || true
  VBoxManage controlvm "${VM_NAME}" keyboardputscancode 1c 9c
  sleep 30
  VBoxManage controlvm "${VM_NAME}" keyboardputstring "yes" || true
  VBoxManage controlvm "${VM_NAME}" keyboardputscancode 1c 9c
  sleep 30
done
echo 'VM is now accessible!'

# Final reboot
echo "Sleeping 60s for final reboot"
sleep 60
VBoxManage controlvm "${VM_NAME}" keyboardputstring "${PASSWORD}" || true
VBoxManage controlvm "${VM_NAME}" keyboardputscancode 1c 9c || true

echo "---------------------------------------------------------------" | tee -a install_info.txt
echo "Installation is complete, you can access:" | tee -a install_info.txt
echo "1. The Gnome desktop is accessible via noVNC: http://localhost:6080/vnc.html" | tee -a install_info.txt
echo "2. X11 applications via SSH with X11 forwarding: ssh -X -p 2222 ${USERN}@localhost" | tee -a install_info.txt
echo "   (You'll need an X server running on your local machine for option 2)" | tee -a install_info.txt
echo "3. Installed software will include Microsoft Edge, Intune Portal, 1Password, and VS Code" | tee -a install_info.txt
