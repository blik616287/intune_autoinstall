#!/bin/bash
# Script for Ubuntu Autoinstallation with LUKS Encryption in VirtualBox
# Based on Dustin Specker's approach: https://dustinspecker.com/posts/ubuntu-autoinstallation-virtualbox/

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
  early-commands:
    - echo 'Autoinstall in progress...'
  late-commands:
    # Configure sudo access for user
    - echo '${USERN} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${USERN}
    - chmod 440 /target/etc/sudoers.d/${USERN}

    # Configure SSH with X11 forwarding
    - sed -i 's/#X11Forwarding no/X11Forwarding yes/' /target/etc/ssh/sshd_config
    - sed -i 's/#X11DisplayOffset 10/X11DisplayOffset 10/' /target/etc/ssh/sshd_config
    - sed -i 's/#X11UseLocalhost yes/X11UseLocalhost yes/' /target/etc/ssh/sshd_config
    - curtin in-target --target=/target -- bash -c "systemctl restart ssh"
    
    # Ensure user exists in the installed system
    - curtin in-target --target=/target -- bash -c "getent passwd ${USERN} > /dev/null || useradd -m -s /bin/bash ${USERN}"
    - curtin in-target --target=/target -- bash -c "echo '${USERN}:${PASSWORD}' | chpasswd"

    # Ensure VNC dependancies are present
    - curtin in-target --target=/target -- bash -c "mkdir -p /home/${USERN}/.vnc"
    - curtin in-target --target=/target -- bash -c "x11vnc -storepasswd ${PASSWORD} /home/${USERN}/.vnc/passwd"
    - curtin in-target --target=/target -- bash -c "chmod 600 /home/${USERN}/.vnc/passwd"
    - curtin in-target --target=/target -- bash -c "chown ${USERN}:${USERN} /home/${USERN}/.vnc/passwd"

    
    # Create a script to run as the user after installation
    - |
      cat > /target/usr/local/bin/setup-vnc.sh << 'SETUPSCRIPT'
      #!/bin/bash
      set -e

      # Update packages
      sudo apt update

      # Create a directory for VNC
      mkdir -p /home/${USERN}/.vnc

      # Set a VNC password (with better command structure)
      x11vnc -storepasswd ${PASSWORD} /home/${USERN}/.vnc/passwd

      # Make sure the password file has proper permissions
      chmod 600 /home/${USERN}/.vnc/passwd
      chown ${USERN}:${USERN} /home/${USERN}/.vnc/passwd

      # Create an improved Openbox session script
      cat > /home/${USERN}/.vnc/xstartup << 'EOF'
      #!/bin/bash
      # Unset session manager and D-Bus to prevent issues
      unset SESSION_MANAGER
      unset DBUS_SESSION_BUS_ADDRESS
      # Launch a terminal to confirm X server is working
      xterm &
      # Start the window manager with proper logging
      exec openbox-session
      EOF

      # Make the startup script executable
      chmod +x /home/${USERN}/.vnc/xstartup

      # Create a systemd service file for Xvfb with improved parameters
      cat > /tmp/xvfb.service << 'EOF'
      [Unit]
      Description=X Virtual Frame Buffer
      After=network.target

      [Service]
      User=ubuntu
      ExecStartPre=/bin/sleep 2
      ExecStart=/usr/bin/Xvfb :1 -screen 0 1280x720x24 -ac -extension GLX
      Restart=on-failure
      RestartSec=2

      [Install]
      WantedBy=multi-user.target
      EOF

      # Create a systemd service file for x11vnc with better parameters
      cat > /tmp/x11vnc.service << 'EOF'
      [Unit]
      Description=X11 VNC Server
      After=xvfb.service
      Requires=xvfb.service

      [Service]
      User=ubuntu
      Environment=DISPLAY=:1
      ExecStartPre=/bin/sleep 3
      ExecStart=/usr/bin/x11vnc -display :1 -rfbauth /home/${USERN}/.vnc/passwd -forever -shared -noxdamage -noxrecord -noxfixes -desktop "Virtual Desktop" -localhost -o /home/${USERN}/.vnc/x11vnc.log
      Restart=on-failure
      RestartSec=2

      [Install]
      WantedBy=multi-user.target
      EOF

      # Create a systemd service file for openbox
      cat > /tmp/openbox.service << 'EOF'
      [Unit]
      Description=Openbox Window Manager
      After=xvfb.service
      Requires=xvfb.service

      [Service]
      User=ubuntu
      Environment=DISPLAY=:1
      Environment=HOME=/home/${USERN}
      ExecStartPre=/bin/sleep 4
      ExecStart=/bin/bash /home/${USERN}/.vnc/xstartup
      Restart=on-failure
      RestartSec=2

      [Install]
      WantedBy=multi-user.target
      EOF

      # Create a systemd service file for novnc
      cat > /tmp/novnc.service << 'EOF'
      [Unit]
      Description=NoVNC WebSocket Proxy
      After=x11vnc.service
      Requires=x11vnc.service

      [Service]
      User=ubuntu
      ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5900
      Restart=on-failure
      RestartSec=2

      [Install]
      WantedBy=multi-user.target
      EOF

      # Install the service files
      sudo mv /tmp/xvfb.service /etc/systemd/system/
      sudo mv /tmp/x11vnc.service /etc/systemd/system/
      sudo mv /tmp/openbox.service /etc/systemd/system/
      sudo mv /tmp/novnc.service /etc/systemd/system/

      # Make sure services are stopped before restarting them
      sudo systemctl stop novnc.service || true
      sudo systemctl stop x11vnc.service || true
      sudo systemctl stop openbox.service || true
      sudo systemctl stop xvfb.service || true

      # Reload and restart the services
      sudo systemctl daemon-reload
      sudo systemctl enable xvfb.service
      sudo systemctl enable openbox.service
      sudo systemctl enable x11vnc.service
      sudo systemctl enable novnc.service
      sudo systemctl start xvfb.service
      sudo systemctl start openbox.service
      sudo systemctl start x11vnc.service
      sudo systemctl start novnc.service
      SETUPSCRIPT

    # Make the script executable
    - chmod +x /target/usr/local/bin/setup-vnc.sh

    # Create a script for dynamic hostname and additional software installation
    - |
      cat > /target/usr/local/bin/setup-software.sh << 'SOFTWARESCRIPT'
      #!/bin/bash
      set -e

      DEBIAN_FRONTEND=noninteractive
      sudo apt update

      # Get the uuid from dmidecode with retries
      MAX_UUID_RETRIES=3
      UUID_RETRY_COUNT=0
      uuid="Not Settable"

      while [ $UUID_RETRY_COUNT -lt $MAX_UUID_RETRIES ] && [ "$uuid" = "Not Settable" ]; do
          echo "Attempting to retrieve system UUID (attempt $((UUID_RETRY_COUNT+1))/$MAX_UUID_RETRIES)"
          uuid=$(sudo dmidecode -s system-uuid)

          if [ "$uuid" != "Not Settable" ] && [ -n "$uuid" ]; then
              echo "Successfully retrieved system UUID: $uuid"
              break
          else
              UUID_RETRY_COUNT=$((UUID_RETRY_COUNT+1))
              echo "UUID not available yet, retrying in 5 seconds..."
              sleep 5
          fi
      done

      # Check if uuid was successfully retrieved or is still "Not Settable"
      if [ "$uuid" = "Not Settable" ] || [ -z "$uuid" ]; then
          echo "System UUID not available after $MAX_UUID_RETRIES attempts. Using random identifier."
          # Generate a random string for the hostname suffix
          random_suffix=$$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 12 | head -n 1)
          last_9_digits=$${random_suffix: -9}
      else
          # Extract the last 9 characters of the serial number
          last_9_digits="${uuid: -9}"
      fi

      # Create the new hostname by prefixing 'OXQLNX-' with the last 9 digits
      new_hostname="OXQLNX-${last_9_digits}"

      # Set the new hostname
      sudo hostnamectl set-hostname "$new_hostname"

      # Update /etc/hosts to reflect the new hostname
      sudo sed -i "s/$(hostname)/$new_hostname/g" /etc/hosts

      # Install Curl
      sudo apt update
      sudo apt install curl wget gpg -y

      # Remove conflicting Microsoft Edge repository file
      sudo rm -f /etc/apt/sources.list.d/microsoft-edge-stable.list || true

      # Install Microsoft Edge Browser and Intune
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/microsoft.gpg
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge/ stable main" | sudo tee /etc/apt/sources.list.d/microsoft-edge.list > /dev/null
      sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/$(lsb_release -rs)/prod $(lsb_release -cs) main" >> /etc/apt/sources.list.d/microsoft-ubuntu-$(lsb_release -cs)-prod.list'
      sudo apt update
      sudo apt install microsoft-edge-stable -y
      sudo apt install intune-portal -y

      # Install 1Password:
      sudo mkdir -p /usr/share/keyrings
      curl -sS https://downloads.1password.com/linux/keys/1password.asc | sudo tee /usr/share/keyrings/1password-archive-keyring.asc > /dev/null
      sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/1password-archive-keyring.gpg /usr/share/keyrings/1password-archive-keyring.asc
      echo "deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main" | sudo tee /etc/apt/sources.list.d/1password.list
      sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/
      curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol
      sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
      curl -sS https://downloads.1password.com/linux/keys/1password.asc | sudo tee /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.asc > /dev/null
      sudo gpg --batch --yes --dearmor -o /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.asc
      sudo apt update
      sudo apt -y install 1password-cli

      # Install VS Code
      sudo mkdir -p /etc/apt/keyrings
      curl -sS https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/keyrings/microsoft.asc > /dev/null
      sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg /etc/apt/keyrings/microsoft.asc
      echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
      sudo apt install apt-transport-https -y
      sudo apt update && sudo apt install code -y

      # Create Openbox menu with application shortcuts
      mkdir -p /home/${USERN}/.config/openbox
      cat > /home/${USERN}/.config/openbox/menu.xml << 'MENUXML'
      <?xml version="1.0" encoding="UTF-8"?>
      <openbox_menu xmlns="http://openbox.org/3.4/menu">
      <menu id="root-menu" label="Openbox 3">
        <item label="Terminal">
          <action name="Execute"><command>xterm</command></action>
        </item>
        <item label="Microsoft Edge">
          <action name="Execute"><command>microsoft-edge-stable</command></action>
        </item>
        <item label="Visual Studio Code">
          <action name="Execute"><command>code</command></action>
        </item>
        <item label="Intune Portal">
          <action name="Execute"><command>intune-portal</command></action>
        </item>
        <separator />
        <menu id="client-list-menu" />
        <separator />
        <item label="Reconfigure">
          <action name="Reconfigure" />
        </item>
        <item label="Restart">
          <action name="Restart" />
        </item>
        <separator />
        <item label="Exit">
          <action name="Exit" />
        </item>
      </menu>
      </openbox_menu>
      MENUXML

      # Set proper ownership for Openbox config
      chown -R ${USERN}:${USERN} /home/${USERN}/.config

      # Restart Openbox to apply the new menu
      if systemctl is-active --quiet openbox.service; then
        sudo systemctl restart openbox.service
      fi

      # Reboot for hostname changes to take effect
      sudo reboot
      SOFTWARESCRIPT

    # Make the script executable
    - chmod +x /target/usr/local/bin/setup-software.sh

    # Create a systemd service to run the VNC script on first boot
    - |
      cat > /target/etc/systemd/system/run-vnc-setup.service << 'EOF'
      [Unit]
      Description=Run VNC setup script on first boot
      After=network.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/setup-vnc.sh
      User=ubuntu
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
      EOF

    # Create a systemd service to run the software setup script on first boot
    - |
      cat > /target/etc/systemd/system/run-software-setup.service << 'EOF'
      [Unit]
      Description=Run software setup script on first boot
      After=network.target run-vnc-setup.service
      Requires=run-vnc-setup.service

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/setup-software.sh
      User=ubuntu
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
      EOF

    # Create README file
    - |
      cat > /target/home/${USERN}/README.txt << 'README'
      SETUP INFORMATION
      =================

      1. noVNC for Browser Access
         Access the Openbox desktop environment in your web browser:
         - Find the IP address of this VM with: ip addr show
         - Open a web browser and navigate to: http://VM-IP-ADDRESS:6080/vnc.html
         - Default VNC password: yourpassword

      2. X11 Forwarding
         Run graphical applications over SSH:
         - Use: ssh -X username@VM-IP-ADDRESS
         - Then start any X11 application

      3. VNC Service Management
         If you need to restart VNC services:
         - sudo systemctl restart xvfb.service
         - sudo systemctl restart openbox.service
         - sudo systemctl restart x11vnc.service
         - sudo systemctl restart novnc.service

      4. Installed Software
         - Microsoft Edge
         - Microsoft Intune
         - 1Password CLI
         - Visual Studio Code

      TROUBLESHOOTING
      ==============

      If you have any issues with noVNC, check service status with:
      systemctl status novnc
      systemctl status xvfb
      systemctl status x11vnc
      systemctl status openbox

      To restart all services:
      sudo systemctl restart xvfb openbox x11vnc novnc
      README
    - chown 1000:1000 /target/home/${USERN}/README.txt

    # Create a script to display connection information to the console
    - |
      cat > /target/usr/local/bin/display-connection-info.sh << 'CONNECTIONINFO'
      #!/bin/bash

      # Make sure we're outputting to the console
      exec > /dev/tty1 2>&1

      # Clear the screen
      clear

      # Display a nice header
      echo "=============================================================="
      echo "           UBUNTU VNC SERVER SETUP COMPLETE                   "
      echo "=============================================================="
      echo ""

      # Get the IP address
      IP_ADDRESS=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)

      # Display the VNC URL
      echo "VNC ACCESS URL: http://${IP_ADDRESS}:6080/vnc.html"
      echo ""
      echo "=============================================================="
      echo "README INFORMATION:"
      echo "=============================================================="
      echo ""

      # Display the README file
      cat /home/ubuntu/README.txt

      # Keep the information on screen
      echo ""
      echo "=============================================================="
      echo "Press Enter to continue to login prompt..."
      echo "=============================================================="

      # Wait for a keypress (optional)
      read

      # Clear the screen and return to login prompt
      clear
      CONNECTIONINFO

    # Make the script executable
    - chmod +x /target/usr/local/bin/display-connection-info.sh

    # Create a service to run the connection info display after all setup is complete
    - |
      cat > /target/etc/systemd/system/display-connection-info.service << 'EOF'
      [Unit]
      Description=Display connection information on console
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/display-connection-info.sh
      RemainAfterExit=no

      [Install]
      WantedBy=multi-user.target
      EOF

    # Enable the services
    - curtin in-target --target=/target -- systemctl enable run-vnc-setup.service
    - curtin in-target --target=/target -- systemctl enable run-software-setup.service
    - curtin in-target --target=/target -- systemctl enable display-connection-info.service

  user-data:
    disable_root: true
EOF

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
