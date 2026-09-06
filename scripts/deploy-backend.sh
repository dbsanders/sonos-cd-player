#!/bin/sh
# Stage the version in this checkout, then rebuild on the NAS.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
nas_host=${1:-nasadmin@192.168.1.100}
stage_dir=$(mktemp -d)
trap 'rm -rf "$stage_dir"' EXIT HUP INT TERM
cp "$repo_dir/backend/app.py" "$repo_dir/backend/changer.py" "$repo_dir/backend/Dockerfile" "$repo_dir/backend/requirements.txt" "$stage_dir/"
cp "$repo_dir/scripts/restart-container.sh" "$stage_dir/deploy-changer.sh"
# Preserve the existing deployment directory and /data bind mount.
COPYFILE_DISABLE=1 tar -C "$stage_dir" -cf - . | ssh "$nas_host" 'cd /volume1/homes/nasadmin/sonos-cd-player && tar -xf -'
ssh -t "$nas_host" 'sudo sh /volume1/homes/nasadmin/sonos-cd-player/deploy-changer.sh'
