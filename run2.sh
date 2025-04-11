#!/bin/bash

set -e

# Static variables
TIMEZONE="UTC"

# Configuration variables
VM_NAME="${VM_NAME:-Ubuntu-Encrypted}"
FILE_URL="${FILE_URL:-https://cofractal-ewr.mm.fcix.net/ubuntu-releases/24.04.2/ubuntu-24.04.2-live-server-amd64.iso}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-25000}"
USERN="${USERN:-ubuntu}"
PASSWORD="${PASSWORD:-ubuntu}"
HOSTN="${HOSTN:-ubuntu-encrypted}"

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
get_file_data novnc.service
decode_file_data novnc.service

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
    sudo VBoxManage extpack install --replace Oracle_VM_VirtualBox_Extension_Pack-${vbox_version}.vbox-extpack
    rm Oracle_VM_VirtualBox_Extension_Pack-${vbox_version}.vbox-extpack
    echo "VirtualBox Extension Pack installation complete."
fi

# Check for required tools
if ! command -v cloud-localds &> /dev/null; then
    echo "cloud-localds not found. Installing cloud-image-utils..."
    sudo apt-get update && sudo apt-get install -y cloud-image-utils
fi

# Create a temporary directory for our configuration files
TEMP_DIR=$(mktemp -d)
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
  content: $(get_file_data xvfb.service)
  owner: root:root
  path: /tmp/xvfb.service.bz2
  permissions: '0644'
- encoding: b64
  content: $(get_file_data openbox.service)
  owner: root:root
  path: /tmp/openbox.service.bz2
  permissions: '0644'
- encoding: b64
  content: $(get_file_data x11vnc.service)
  owner: root:root
  path: /tmp/x11vnc.service.bz2
  permissions: '0644'
- encoding: b64
  content: $(get_file_data run-software-setup.service)
  owner: root:root
  path: /tmp/run-software-setup.service.bz2
  permissions: '0644'
- encoding: b64
  content: $(get_file_data run-vnc-setup.service)
  owner: root:root
  path: /tmp/run-vnc-setup.service.bz2
  permissions: '0644'
- encoding: b64
  content: $(get_file_data setup_software.sh)
  owner: root:root
  path: /tmp/setup_software.sh.bz2
  permissions: '0755'
- encoding: b64
  content: $(get_file_data xstartup)
  owner: ${USERN}:${USERN}
  path: /tmp/xstartup.bz2
  permissions: '0755'
  defer: yes
- encoding: b64
  content: $(get_file_data menu.xml)
  owner: ${USERN}:${USERN}
  path: /tmp/menu.xml.bz2
  permissions: '0644'
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${HOSTN}
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
    - xvfb
    - x11vnc
    - openbox
    - novnc
    - websockify
    - xterm
    - build-essential
    - dkms
    - linux-headers-generic
    - bzip2
  early-commands:
    - echo 'Autoinstall in progress...'
  late-commands:
    # Configure sudo access for user
    - echo "${USERN} ALL=(ALL) NOPASSWD:ALL" > /target/etc/sudoers.d/${USERN}
    - chmod 440 /target/etc/sudoers.d/${USERN}

    # Configure SSH with X11 forwarding
    - sed -i 's/#X11Forwarding no/X11Forwarding yes/' /target/etc/ssh/sshd_config
    - sed -i 's/#X11DisplayOffset 10/X11DisplayOffset 10/' /target/etc/ssh/sshd_config
    - sed -i 's/#X11UseLocalhost yes/X11UseLocalhost yes/' /target/etc/ssh/sshd_config
    - curtin in-target --target=/target -- systemctl restart ssh

    # Ensure user exists in the installed system
    - curtin in-target --target=/target -- bash -c "getent passwd ${USERN} > /dev/null || useradd -m -s /bin/bash ${USERN}"
    - curtin in-target --target=/target -- bash -c "echo '${USERN}:${PASSWORD}' | chpasswd"

    # Eunsure bzip2 is present
    - curtin in-target --target=/target -- bash -c "apt update"
    - curtin in-target --target=/target -- bash -c "apt install -y bzip2"

    # Ensure VNC dependancies are present
    - curtin in-target --target=/target -- bash -c "mkdir -p /home/${USERN}/.vnc"
    - curtin in-target --target=/target -- bash -c "x11vnc -storepasswd ${PASSWORD} /home/${USERN}/.vnc/passwd"
    - curtin in-target --target=/target -- bash -c "chmod 600 /home/${USERN}/.vnc/passwd"
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/xstartup.bz2 > /home/${USERN}/.vnc/xstartup"
    - curtin in-target --target=/target -- bash -c "chown -R ${USERN}:${USERN} /home/${USERN}/.vnc"

    # Setup service files for VNC support
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/xvfb.service.bz2 > /etc/systemd/system/xvfb.service"
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/x11vnc.service.bz2 > /etc/systemd/system/x11vnc.service"
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/openbox.service.bz2 > /etc/systemd/system/openbox.service"
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/novnc.service.bz2 > /etc/systemd/system/novnc.service"

    # Base VNC services
    - curtin in-target --target=/target -- systemctl stop novnc.service || true
    - curtin in-target --target=/target -- systemctl stop x11vnc.service || true
    - curtin in-target --target=/target -- systemctl stop openbox.service || true
    - curtin in-target --target=/target -- systemctl stop xvfb.service || true
    - curtin in-target --target=/target -- systemctl daemon-reload
    - curtin in-target --target=/target -- systemctl enable novnc.service
    - curtin in-target --target=/target -- systemctl enable x11vnc.service
    - curtin in-target --target=/target -- systemctl enable openbox.service
    - curtin in-target --target=/target -- systemctl enable xvfb.service
    - curtin in-target --target=/target -- systemctl start novnc.service
    - curtin in-target --target=/target -- systemctl start x11vnc.service
    - curtin in-target --target=/target -- systemctl start openbox.service
    - curtin in-target --target=/target -- systemctl start xvfb.service

    # Install software
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/setup_software.sh.bz2 > /usr/local/bin/setup-software.sh"
    - curtin in-target --target=/target -- bash -c "chmod 755 /usr/local/bin/setup-software.sh"
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/run-software-setup.service.bz2 > /etc/systemd/system/run-software-setup.service"

    # Ensure Openbox menu dependancies are present
    - curtin in-target --target=/target -- bash -c "mkdir -p /home/${USERN}/.config/openbox"
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/menu.xml.bz2 > /home/${USERN}/.config/openbox/menu.xml"
    - curtin in-target --target=/target -- bash -c "chown -R ${USERN}:${USERN} /home/${USERN}/.config"
    - curtin in-target --target=/target -- systemctl restart openbox.service

    # User VNC service config
    - curtin in-target --target=/target -- bash -c "bunzip2 -c /tmp/run-vnc-setup.service.bz2 > /etc/systemd/system/run-vnc-setup.service"

    # Enable the user services
    - curtin in-target --target=/target -- systemctl daemon-reload
    - curtin in-target --target=/target -- systemctl stop run-vnc-setup.service || true
    - curtin in-target --target=/target -- systemctl enable run-vnc-setup.service
    - curtin in-target --target=/target -- systemctl start run-vnc-setup.service
    - curtin in-target --target=/target -- systemctl stop run-software-setup.service || true
    - curtin in-target --target=/target -- systemctl enable run-software-setup.service
    - curtin in-target --target=/target -- systemctl start run-software-setup.service

  user-data:
    disable_root: true
EOF
cloud-init schema -c "${TEMP_DIR}/user-data" --annotate

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

# Set network to bridged as per Dustin Specker's tutorial
echo "Setting network adapter to bridged mode for SSH access..."
VBoxManage modifyvm "${VM_NAME}" --nic1 bridged
# Get a list of available network adapters
ADAPTERS=$(VBoxManage list bridgedifs | grep "^Name:" | cut -d ':' -f 2 | sed 's/^[ \t]*//')
if [ -z "${ADAPTERS}" ]; then
    echo "No bridged network adapters found. Falling back to NAT."
    VBoxManage modifyvm "${VM_NAME}" --nic1 nat
else
    # Use the first adapter in the list or allow user to choose
    FIRST_ADAPTER=$(echo "${ADAPTERS}" | head -n 1)
    echo "Available network adapters:"
    echo "${ADAPTERS}" | nl
    echo "Using adapter: ${FIRST_ADAPTER}"
    VBoxManage modifyvm "${VM_NAME}" --bridgeadapter1 "${FIRST_ADAPTER}"
fi

VBoxManage modifyvm "${VM_NAME}" --rtcuseutc on

# Create and attach virtual disk
echo "Creating virtual disk..."
VM_DISK=$(VBoxManage list systemproperties | grep "Default machine folder" | cut -d':' -f2 | xargs)/${VM_NAME}/${VM_NAME}.vdi
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
VBoxManage setextradata "${VM_NAME}" "BootArgs" "autoinstall ds=nocloud;s=/cdrom/"

# Start the VM
echo "Starting VM: ${VM_NAME}"
VBoxManage startvm "${VM_NAME}"

echo "Installation started."
echo "---------------------------------------------------------------"
echo "VM Name: ${VM_NAME}"
echo "Username: ${USERN}"
echo "Password: ${PASSWORD} (also used for disk encryption)"
echo "Note: The VM will reboot after installation and you'll need to enter"
echo "      the encryption password. The installation will proceed automatically."
echo ""
echo "After installation is complete, you can access:"
echo "1. The Openbox desktop via noVNC: http://VM-IP-ADDRESS:6080/vnc.html"
echo "2. X11 applications via SSH with X11 forwarding: ssh -X ${USERN}@VM-IP-ADDRESS"
echo "   (You'll need an X server running on your local machine for option 2)"
echo "3. Installed software will include Microsoft Edge, Intune Portal, 1Password, and VS Code"
echo "---------------------------------------------------------------"

# Disable the trap to preserve the seed.iso
trap - EXIT
echo "IMPORTANT: Keep the seed.iso file at ${TEMP_DIR}/seed.iso until the installation is complete."
echo "You can remove it afterwards."
