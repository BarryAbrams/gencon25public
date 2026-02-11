#!/bin/bash
set -e

echo "[INFO] Checking hardware..."

# if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
#     echo "[ERROR] This script is intended for Raspberry Pi devices only."
#     echo "        Detected: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'Unknown')"
#     exit 1
# fi

MODEL=$(tr -d '\0' < /proc/device-tree/model)
echo "[INFO] Detected model: $MODEL"

if echo "$MODEL" | grep -q "Raspberry Pi 5"; then
    OVERLAY="dtoverlay=hifiberry-dacplus,slave"
elif echo "$MODEL" | grep -q "Raspberry Pi 4"; then
    OVERLAY="dtoverlay=hifiberry-dacplus"
else
    echo "[ERROR] Unsupported Pi model: $MODEL"
    echo "        Only Raspberry Pi 4 and 5 are supported."
    exit 1
fi

set -e

# Load env vars (like GH_TOKEN) if available
[ -f ~/.env ] && source ~/.env

if [ -z "$GH_TOKEN" ]; then
    echo "[ERROR] GH_TOKEN is not set."
    exit 1
fi

# Save it to ~/.env for future sessions (only if not already there)
if ! grep -q "GH_TOKEN=" ~/.env 2>/dev/null; then
    echo "GH_TOKEN=$GH_TOKEN" > ~/.env
    chmod 600 ~/.env
fi

export GH_TOKEN=$GH_TOKEN
echo "[INFO] GH_TOKEN now available in this session $GH_TOKEN"

read -p "Enter hostname: " HOSTNAME

echo "[INFO] Setting hostname..."
sudo hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" | sudo tee /etc/hostname
sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts

# Ensure overlay is set (but not duplicated)
if ! grep -qF "$OVERLAY" /boot/firmware/config.txt; then
    echo "$OVERLAY" | sudo tee -a /boot/firmware/config.txt
fi

echo "[INFO] Updating /boot/firmware/config.txt..."
# Comment out dtparam=audio=on if present
sudo sed -i 's/^\s*\(dtparam=audio=on\)/# \1/' /boot/firmware/config.txt

CONFIG="/boot/firmware/config.txt"

# Ensure dtparam=spi=on is uncommented or added
if grep -q '^\s*#\s*dtparam=spi=on' "$CONFIG"; then
    sudo sed -i 's/^\s*#\s*dtparam=spi=on/dtparam=spi=on/' "$CONFIG"
elif ! grep -q '^\s*dtparam=spi=on' "$CONFIG"; then
    echo "dtparam=spi=on" | sudo tee -a "$CONFIG"
fi


### ---- Add overlay: mcp2515-can0 ---- ###
MCP_LINE="dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=25,spimaxfrequency=1000000"

# If commented out → uncomment
if grep -q "^\s*#\s*$MCP_LINE" "$CONFIG"; then
    sudo sed -i "s|^\s*#\s*$MCP_LINE|$MCP_LINE|" "$CONFIG"
# If not present at all → append
elif ! grep -q "^\s*$MCP_LINE" "$CONFIG"; then
    echo "$MCP_LINE" | sudo tee -a "$CONFIG"
fi


### ---- Add overlay: sc16is752-spi1 ---- ###
SC16_LINE="dtoverlay=sc16is752-spi1,int_pin=24"

# If commented → uncomment
if grep -q "^\s*#\s*$SC16_LINE" "$CONFIG"; then
    sudo sed -i "s|^\s*#\s*$SC16_LINE|$SC16_LINE|" "$CONFIG"
# If missing → append
elif ! grep -q "^\s*$SC16_LINE" "$CONFIG"; then
    echo "$SC16_LINE" | sudo tee -a "$CONFIG"
fi

echo "[INFO] Creating /boot/MEDIA..."
sudo mkdir -p /boot/MEDIA
sudo chmod 777 /boot/MEDIA

echo "[INFO] Installing GitHub CLI..."
(type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) \
&& sudo mkdir -p -m 755 /etc/apt/keyrings \
&& out=$(mktemp) && wget -nv -O $out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
&& sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg < $out > /dev/null \
&& sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
| sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
&& sudo apt update \
&& sudo apt install gh -y

sudo apt-get install python3-dev python3-rpi.gpio -y
sudo apt install mpv -y 

if [ -z "$GH_TOKEN" ]; then
    echo "[ERROR] GH_TOKEN environment variable is not set."
    exit 1
fi

echo "[INFO] Setting up GitHub CLI non-interactively..."
mkdir -p ~/.config/gh

cat > ~/.config/gh/hosts.yml <<EOF
github.com:
    oauth_token: $GH_TOKEN
    user: BarryAbrams
    git_protocol: https
EOF

rm -rf /home/pi/parcadia

echo "[INFO] Cloning repo..."
cd /home/pi
gh repo clone BarryAbrams/parcadia_architecture
mv parcadia_architecture /home/pi/parcadia
cd parcadia

echo "[INFO] Setting up Python environment..."
sudo apt install -y python3-venv
python3 -m venv .venv
source .venv/bin/activate
/home/pi/parcadia/.venv/bin/pip3 install --upgrade pip
/home/pi/parcadia/.venv/bin/pip3 install -r /home/pi/parcadia/holes/requirements.txt

echo "[INFO] Setting up systemd service..."
cat <<EOF | sudo tee /etc/systemd/system/parcadia.service
[Unit]
Description=Start parcadia script
After=network.target

[Service]
ExecStart=/home/pi/parcadia/.venv/bin/python3 /home/pi/parcadia/holes/app.py
WorkingDirectory=/home/pi/parcadia
Restart=always
User=pi
TimeoutStopSec=3
KillSignal=SIGKILL

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable parcadia.service
sudo systemctl start parcadia.service

echo "[INFO] Setup complete."

sudo reboot
