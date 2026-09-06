#!/bin/sh
set -eu
cd /volume1/homes/nasadmin/sonos-cd-player
if [ "$(id -u)" != 0 ]; then
  echo 'Run this script with sudo.' >&2
  exit 1
fi
backup="sonos-cd-player-before-changer-$(date +%Y%m%d-%H%M%S)"
docker inspect sonos-cd-player > "${backup}.json"
docker build -t sonos-cd-player:changer .
mkdir -p data
docker stop sonos-cd-player
docker rename sonos-cd-player "$backup"
if ! docker run -d --name sonos-cd-player --network host --restart unless-stopped -v "$PWD/data:/data" sonos-cd-player:changer; then
  docker rename "$backup" sonos-cd-player
  docker start sonos-cd-player
  exit 1
fi
attempt=0
until curl -fsS http://localhost:8000/discs; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 20 ]; then
    docker logs --tail 50 sonos-cd-player
    docker rm -f sonos-cd-player
    docker rename "$backup" sonos-cd-player
    docker start sonos-cd-player
    exit 1
  fi
  sleep 1
done
echo "Changer deployed; previous container retained as $backup"
