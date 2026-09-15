#!/bin/sh
# Run from the Mac checkout. SSH/sudo ask for the Pi passwords interactively.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pi_host=${1:-bret@riverside-nas.local}
stage_dir=$(mktemp -d)
trap 'rm -rf "$stage_dir"' EXIT HUP INT TERM
cp "$repo_dir/backend/app.py" "$repo_dir/backend/changer.py" \
   "$repo_dir/backend/Dockerfile" "$repo_dir/backend/requirements.txt" \
   "$repo_dir/backend/riverside.env.example" "$stage_dir/"
cp "$repo_dir/scripts/start-pi-container.sh" "$stage_dir/"
# Copy only application files. Existing runtime configuration and data stay put.
COPYFILE_DISABLE=1 tar --no-xattrs -C "$stage_dir" -cf - . | \
    ssh "$pi_host" 'mkdir -p sonos-cd-player && tar -xf - -C sonos-cd-player'
ssh -t "$pi_host" 'sudo sh "$HOME/sonos-cd-player/start-pi-container.sh"'
