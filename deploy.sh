#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 || -z ${1:-} || -z ${2:-} ]]; then
  echo "Usage: $0 IMAGE_URI IMAGE_TAG" >&2
  exit 2
fi

IMAGE_URI=$1
IMAGE_TAG=$2
# DEPLOY_PATH must match the VPS checkout path used by the workflow and Nginx include.
DEPLOY_PATH=${DEPLOY_PATH:-$(pwd -P)}
[[ $DEPLOY_PATH = /* ]] || { echo "DEPLOY_PATH must be an absolute path" >&2; exit 2; }
[[ $(pwd -P) == "$DEPLOY_PATH" ]] || {
  echo "Run this script from DEPLOY_PATH ($DEPLOY_PATH); current directory is $(pwd -P)" >&2
  exit 2
}
COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}
NGINX_ACTIVE_PORT_FILE=${NGINX_ACTIVE_PORT_FILE:-active-port.conf}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-60}
DRAIN_SECONDS=${DRAIN_SECONDS:-30}

[[ $IMAGE_URI =~ ^[a-zA-Z0-9._:/-]+$ ]] || { echo "Invalid image URI" >&2; exit 2; }
[[ $IMAGE_TAG =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "Invalid image tag" >&2; exit 2; }
[[ -f .env.production ]] || { echo "Missing .env.production" >&2; exit 1; }
if [[ ! -f $NGINX_ACTIVE_PORT_FILE ]]; then
  active_dir=$(dirname "$NGINX_ACTIVE_PORT_FILE")
  [[ -d $active_dir ]] || { echo "Missing active-port directory: $active_dir" >&2; exit 1; }
  initial_file=$(mktemp "$active_dir/.universal-active-port.XXXXXX")
  printf 'set $active_port 3001;\n' > "$initial_file"
  chmod 0644 "$initial_file"
  if ! mv -n "$initial_file" "$NGINX_ACTIVE_PORT_FILE"; then
    rm -f "$initial_file"
    echo "Could not create active-port file: $NGINX_ACTIVE_PORT_FILE" >&2
    exit 1
  fi
fi

active_port=$(sed -nE 's/^[[:space:]]*set[[:space:]]+\$active_port[[:space:]]+([0-9]+);[[:space:]]*$/\1/p' "$NGINX_ACTIVE_PORT_FILE" | tail -n1)
case "$active_port" in
  3001) active_service=app-blue; target_service=app-green; target_port=3002 ;;
  3002) active_service=app-green; target_service=app-blue; target_port=3001 ;;
  *) echo "Active port config must set active_port to 3001 or 3002" >&2; exit 1 ;;
esac

compose() {
  IMAGE_URI=$IMAGE_URI IMAGE_TAG=$IMAGE_TAG docker compose -f "$COMPOSE_FILE" "$@"
}

rollback_target() {
  [[ -n ${target_service:-} ]] || return 0
  compose stop "$target_service" >/dev/null 2>&1 || true
  compose rm -f "$target_service" >/dev/null 2>&1 || true
}

deployment_switched=0
active_port_changed=0
candidate=
backup=
cleanup_on_exit() {
  status=$?
  trap - EXIT
  if (( status != 0 && deployment_switched == 0 )); then
    if (( active_port_changed == 1 )) && [[ -n $backup && -f $backup ]]; then
      cp "$backup" "$NGINX_ACTIVE_PORT_FILE" || true
      sudo -n nginx -t && sudo -n systemctl reload nginx || true
    fi
    [[ -z $candidate ]] || rm -f "$candidate" || true
    [[ -z $backup ]] || rm -f "$backup" || true
    rollback_target
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT

echo "Starting $target_service on port $target_port with $IMAGE_URI:$IMAGE_TAG"
compose pull "$target_service"
compose up -d --no-deps --force-recreate "$target_service"

deadline=$((SECONDS + HEALTH_TIMEOUT))
until curl --fail --silent "http://127.0.0.1:${target_port}/health" >/dev/null; do
  if (( SECONDS >= deadline )); then
    echo "Health check failed for $target_service" >&2
    exit 1
  fi
  sleep 2
done

active_dir=$(dirname "$NGINX_ACTIVE_PORT_FILE")
candidate=$(mktemp "$active_dir/.universal-active-port.XXXXXX")
backup=$(mktemp "$active_dir/.universal-active-port.backup.XXXXXX")
cp "$NGINX_ACTIVE_PORT_FILE" "$backup"
printf 'set $active_port %s;\n' "$target_port" > "$candidate"
mv "$candidate" "$NGINX_ACTIVE_PORT_FILE"
candidate=
active_port_changed=1

if ! sudo -n nginx -t; then
  echo "Nginx config validation failed; keeping $active_service active" >&2
  exit 1
fi
if ! sudo -n systemctl reload nginx; then
  echo "Nginx reload failed; restored previous upstream config" >&2
  exit 1
fi
deployment_switched=1
rm -f "$backup"
backup=

echo "Traffic switched to $target_service; draining $active_service for ${DRAIN_SECONDS}s"
sleep "$DRAIN_SECONDS"
compose stop "$active_service" || true
compose rm -f "$active_service" || true

# Build labels scope pruning to this repository; running image remains protected by Docker.
project_label="https://github.com/${APP_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
if [[ $project_label != https://github.com/ ]]; then
  docker image prune -af --filter "label=org.opencontainers.image.source=${project_label}"
fi
echo "Deployment complete: $IMAGE_URI:$IMAGE_TAG"
