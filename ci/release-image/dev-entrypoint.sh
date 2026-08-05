#!/bin/sh
set -eu

# Docker creates missing bind-mount sources as root.  Fix only the mount roots
# so code-server can create its own files without recursively touching projects.
for directory in \
  /workspace \
  /home/coder/.config \
  /home/coder/.local \
  /home/coder/.cache \
  /home/coder/.ssh
do
  mkdir -p "$directory"
  chown coder:coder "$directory"
done

for file in /home/coder/.gitconfig /home/coder/.git-credentials
do
  if [ -e "$file" ]; then
    chown coder:coder "$file"
  fi
done

exec runuser -u coder -- /usr/local/bin/code-server-entrypoint "$@"
