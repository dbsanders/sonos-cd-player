#!/bin/sh
set -eu
cd "$(dirname -- "$0")"
if [ "$(id -u)" != 0 ]; then
    echo 'Run this script with sudo.' >&2
    exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
    echo 'Install Docker first: apt update && apt install -y docker.io' >&2
    exit 1
fi
if [ "$(uname -m)" != aarch64 ]; then
    echo 'This Pi deployment expects Raspberry Pi OS Lite 64-bit (aarch64).' >&2
    exit 1
fi
systemctl enable --now docker
if [ ! -f riverside.env ]; then
    cp riverside.env.example riverside.env
fi
docker build -t sonos-cd-player:riverside .
mkdir -p data
backup=""
if docker container inspect sonos-cd-player >/dev/null 2>&1; then
    backup="sonos-cd-player-before-$(date +%Y%m%d-%H%M%S)"
    docker stop sonos-cd-player
    docker rename sonos-cd-player "$backup"
fi
restore_previous() {
    docker rm -f sonos-cd-player >/dev/null 2>&1 || true
    if [ -n "$backup" ]; then
        docker rename "$backup" sonos-cd-player
        docker start sonos-cd-player
    fi
}
if ! docker run -d --name sonos-cd-player --network host \
    --restart unless-stopped --env-file riverside.env \
    --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
    -v "$PWD/data:/data" sonos-cd-player:riverside; then
    restore_previous
    exit 1
fi
attempt=0
until docker exec sonos-cd-player python -c \
    'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8000/", timeout=3).read()' \
    >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
        docker logs --tail 50 sonos-cd-player
        restore_previous
        exit 1
    fi
    sleep 1
done
echo 'Backend ready on port 8000. Speakers are only grouped when you start music.'
if [ -n "$backup" ]; then
    echo "Previous container retained as $backup"
fi
