#!/bin/bash
set -e

echo "[INFO] Checking hardware..."

if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
    echo "[ERROR] This script is intended for Raspberry Pi devices only."
    echo "        Detected: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'Unknown')"
    exit 1
fi

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

TOKEN_VALUE=$GH_TOKEN
EXPORT_LINE="export GH_TOKEN=${TOKEN_VALUE}"

for FILE in ~/.bashrc ~/.profile; do
    if ! grep -Fxq "$EXPORT_LINE" "$FILE"; then
        echo "[INFO] Adding GH_TOKEN to $FILE"
        echo "$EXPORT_LINE" >> "$FILE"
    else
        echo "[INFO] GH_TOKEN already present in $FILE"
    fi
done

# Apply it immediately in current shell session
export GH_TOKEN=$TOKEN_VALUE
echo "[INFO] GH_TOKEN now available in this session $GH_TOKEN"

read -p "Enter hostname: " HOSTNAME

echo "[INFO] Setting hostname..."
sudo hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" | sudo tee /etc/hostname
sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts

echo "[INFO] Setting config.txt..."
echo "$OVERLAY" | sudo tee -a /boot/firmware/config.txt

echo "[INFO] Creating /boot/MEDIA..."
sudo mkdir -p /bootfs/MEDIA
sudo chmod 777 /bootfs/MEDIA

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

rm -rf /home/pi/gencon2025

echo "[INFO] Cloning repo..."
cd /home/pi
gh repo clone BarryAbrams/gencon2025
cd gencon2025

echo "[INFO] Setting up Python environment..."
sudo apt install -y python3-venv
python3 -m venv .venv
source .venv/bin/activate
/home/pi/gencon2025/.venv/bin/pip3 install --upgrade pip
/home/pi/gencon2025/.venv/bin/pip3 install -r /home/pi/gencon2025/requirements.txt

echo "[INFO] Setting up systemd service..."
SERVICE_NAME="pitunes"
cat <<EOF | sudo tee /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=Start $SERVICE_NAME script
After=network.target

[Service]
ExecStart=/home/pi/repo/.venv/bin/python /home/pi/repo/main.py
WorkingDirectory=/home/pi/repo
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}.service
sudo systemctl start ${SERVICE_NAME}.service

echo "[INFO] Setup complete."
