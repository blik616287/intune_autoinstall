SETUP INFORMATION
=================

1. noVNC for Browser Access
   Access the Openbox desktop environment in your web browser:
   - Find the IP address of this VM with: ip addr show
   - Open a web browser and navigate to: http://$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1):6080/vnc.html
   - Default VNC password: <FOOBAR>

2. X11 Forwarding
   Run graphical applications over SSH:
   - Use: ssh -X <FOOBAR>@$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
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
