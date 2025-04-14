#!/bin/bash

# Fix script for GNOME Shell on Xvfb issues
# This script addresses the "this._userProxy.Display is null" error and related issues

# Exit on error
set -e

# Must be run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

# Get actual username from environment variable or prompt user
if [ -z "$USERN" ]; then
    echo -n "Enter the username that runs the Xvfb/GNOME session: "
    read USERN
fi

echo "Applying fixes for user: $USERN"

# Create backup directory
BACKUP_DIR="/root/service_backups_$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "Created backup directory: $BACKUP_DIR"

# Backup existing service files
for service in xvfb.service gnome-session-xvfb.service x11vnc.service novnc.service; do
    if [ -f "/etc/systemd/system/$service" ]; then
        cp "/etc/systemd/system/$service" "$BACKUP_DIR/"
        echo "Backed up $service"
    fi
done

# Fix Xvfb service
cat > /etc/systemd/system/xvfb.service << EOF
[Unit]
Description=X Virtual Frame Buffer Service
After=network.target

[Service]
ExecStart=/usr/bin/Xvfb :1 -screen 0 1920x1080x24 -ac +extension GLX +render -noreset -extension DPMS
User=$USERN
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
echo "Updated xvfb.service with DPMS extension"

# Fix GNOME session service with proper user (ubuntu)
cat > /etc/systemd/system/gnome-session-xvfb.service << EOF
[Unit]
Description=GNOME Session on Xvfb
After=xvfb.service
Requires=xvfb.service

[Service]
Type=simple
User=$USERN
Environment=DISPLAY=:1
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=XDG_SESSION_TYPE=x11
Environment=GNOME_SHELL_SESSION_MODE=ubuntu
Environment=HOME=/home/$USERN
Environment=PULSE_SERVER=unix:/run/user/1000/pulse/native
Environment=XAUTHORITY=/home/$USERN/.Xauthority
Environment=NO_AT_BRIDGE=1
# Explicitly set XDG_SESSION_ID
Environment=XDG_SESSION_ID=1

# Simplified startup sequence to address failures
ExecStartPre=/bin/sh -c "sudo mkdir -p /run/user/1000 || true"
ExecStartPre=/bin/sh -c "sudo chown $USERN:$USERN /run/user/1000 || true"
ExecStartPre=/bin/sh -c "sudo chmod 700 /run/user/1000 || true"
ExecStartPre=/bin/sh -c "sudo mkdir -p /run/user/1000/pulse || true"
ExecStartPre=/bin/sh -c "sudo chown $USERN:$USERN /run/user/1000/pulse || true"
ExecStartPre=/bin/sh -c "sudo touch /home/$USERN/.Xauthority || true"
ExecStartPre=/bin/sh -c "sudo chown $USERN:$USERN /home/$USERN/.Xauthority || true"
ExecStartPre=/bin/sh -c "sudo loginctl enable-linger $USERN || true"
# Start a D-Bus session if not already running
ExecStartPre=/bin/sh -c "[ -S /run/user/1000/bus ] || dbus-daemon --session --address=unix:path=/run/user/1000/bus --fork || true"

ExecStart=/usr/bin/gnome-session --session=ubuntu
Restart=on-failure
RestartSec=5
PAMName=login

[Install]
WantedBy=multi-user.target
EOF
echo "Updated gnome-session-xvfb.service with proper environment and session management"

# Create PAM service drop-in
mkdir -p /etc/systemd/system/gnome-session-xvfb.service.d/
cat > /etc/systemd/system/gnome-session-xvfb.service.d/pam.conf << EOF
[Service]
PAMName=login
EOF
echo "Created PAM service drop-in"

# Fix x11vnc service
cat > /etc/systemd/system/x11vnc.service << EOF
[Unit]
Description=x11vnc service for Xvfb desktop session
After=xvfb.service gnome-session-xvfb.service
Requires=xvfb.service

[Service]
Type=simple
User=$USERN
Environment=DISPLAY=:1
Environment=XAUTHORITY=/home/$USERN/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/x11vnc -display :1 -forever -loop -noxdamage -repeat -rfbauth /etc/x11vnc.passwd -rfbport 5900 -shared -o /var/log/x11vnc.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
echo "Updated x11vnc.service with proper environment variables"

# Fix NoVNC service (if it exists)
if [ -f "/etc/systemd/system/novnc.service" ]; then
    cat > /etc/systemd/system/novnc.service << EOF
[Unit]
Description=NoVNC WebSocket Proxy
After=x11vnc.service
Requires=x11vnc.service

[Service]
User=$USERN
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5900
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    echo "Updated novnc.service"
fi

# Create VNC password if it doesn't exist
if [ ! -f "/etc/x11vnc.passwd" ]; then
    echo -n "Create VNC password (leave blank to skip): "
    read -s VNC_PASS
    echo
    
    if [ ! -z "$VNC_PASS" ]; then
        x11vnc -storepasswd "$VNC_PASS" /etc/x11vnc.passwd
        chmod 600 /etc/x11vnc.passwd
        echo "Created VNC password file"
    fi
fi

# Create .Xauthority file if it doesn't exist
if [ ! -f "/home/$USERN/.Xauthority" ]; then
    touch "/home/$USERN/.Xauthority"
    chown "$USERN:$USERN" "/home/$USERN/.Xauthority"
    echo "Created .Xauthority file"
fi

# Ensure proper permissions in /run/user/1000
if [ ! -d /run/user/1000 ]; then
    mkdir -p /run/user/1000
    chown "$USERN:$USERN" /run/user/1000
    chmod 700 /run/user/1000
fi

# Enable lingering for the user (helps with user session management)
loginctl enable-linger "$USERN"

# Reload and restart services
systemctl daemon-reload
echo "Systemd daemon reloaded"

echo "Stopping all services first..."
systemctl stop novnc.service 2>/dev/null || true
systemctl stop x11vnc.service 2>/dev/null || true
systemctl stop gnome-session-xvfb.service 2>/dev/null || true
systemctl stop xvfb.service 2>/dev/null || true

echo "Waiting for services to fully stop..."
sleep 5

echo "Starting services in the correct order..."
systemctl start xvfb.service
echo "Xvfb service started"

sleep 3
systemctl start gnome-session-xvfb.service
echo "GNOME session service started"

sleep 5
systemctl start x11vnc.service
echo "x11vnc service started"

if [ -f "/etc/systemd/system/novnc.service" ]; then
    systemctl start novnc.service
    echo "NoVNC service started"
fi

# Show status
echo -e "\nService status:"
systemctl status xvfb.service --no-pager | head -n 3
systemctl status gnome-session-xvfb.service --no-pager | head -n 3
systemctl status x11vnc.service --no-pager | head -n 3
if systemctl is-active novnc.service &>/dev/null; then
    systemctl status novnc.service --no-pager | head -n 3
fi

echo -e "\nFix completed. You can access the desktop via VNC at port 5900 or NoVNC at port 6080."
echo "If issues persist, check the logs with: journalctl -xe"
