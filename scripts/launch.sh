#!/usr/bin/env bash
set -euo pipefail

# --- Expected Variables ---

export DEBUG
export CLI
export LOCALHOST
export LOG_PATH
export DEPLOY_DIR
export ENV_FILE_PATH
export LAUNCH_TRIGGER_PATH
export SCRIPTS_DIR
export SETUP_DIR
export RESET

# --- Bootstrap Logging ---

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/_logging.sh"

# --- Functions ---

wait_for_launch_signal() {
  if [[ -n "${LAUNCH_TRIGGER_PATH:-}" ]]; then
    until [ -s "$LAUNCH_TRIGGER_PATH" ]; do sleep 2; done
    rm -f "$LAUNCH_TRIGGER_PATH"
  else
    until [ -s "$ENV_FILE_PATH" ]; do sleep 2; done
  fi

  status "Configuration saved." "config_saved"
}

is_arm64() {
  local arch
  arch="$(uname -m)"
  [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]
}

write_local_compose_override() {
  cat > docker-compose.local.yml <<'EOF'
services:
  wikibase:
    image: wikibase/wikibase:latest
    pull_policy: never
  wikibase-jobrunner:
    image: wikibase/wikibase:latest
    pull_policy: never
  elasticsearch:
    image: wikibase/elasticsearch:latest
    pull_policy: never
  wdqs:
    image: wikibase/wdqs:latest
    pull_policy: never
  wdqs-updater:
    image: wikibase/wdqs:latest
    pull_policy: never
  wdqs-frontend:
    image: wikibase/wdqs-frontend:latest
    pull_policy: never
  quickstatements:
    image: wikibase/quickstatements:latest
    pull_policy: never
EOF
}

prepare_arm64_local_images() {
  if ! is_arm64; then
    return 0
  fi

  local pipeline_dir
  local pipeline_dir_quoted
  pipeline_dir="$(cd .. && pwd)"
  printf -v pipeline_dir_quoted '%q' "$pipeline_dir"

  if [ ! -x "$pipeline_dir/nx" ]; then
    status "ARM64 detected, but $pipeline_dir/nx is not executable; cannot build local images." "arm64_local_build_unavailable"
    return 1
  fi

  status "ARM64 detected; building local Wikibase Suite images..." "arm64_local_build_started"
  run "cd $pipeline_dir_quoted && ./nx build"

  status "Using local Wikibase Suite images from docker-compose.local.yml." "arm64_local_override_written"
  write_local_compose_override
}

launch_deploy() {
  pushd "$DEPLOY_DIR" >/dev/null || return 1

  prepare_arm64_local_images

  local compose_opts=()
  local compose_up_opts=(-d)

  if [ -f "docker-compose.local.yml" ]; then
    compose_opts+=(-f docker-compose.yml -f docker-compose.local.yml)
  fi

  if ! $DEBUG ; then
    compose_up_opts+=(--quiet-pull);
  fi

  if $RESET; then
    status "Removing config/LocalSettings.php (RESET=true)" "reset_config_removed"
    run "rm -f config/LocalSettings.php"

    status "Taking down any existing wbs-deploy services and data (RESET=true)" "reset_services_removed"
    run "docker compose ${compose_opts[*]} down --volumes"
  fi

  status "Pulling Docker images..." "images_pull_started"
  run "docker compose ${compose_opts[*]} pull"

  status "Starting Docker Compose services. Generally takes 2–6 minutes..." "services_waiting"
  run "docker compose ${compose_opts[*]} up ${compose_up_opts[*]}"
  status "Docker Compose services reported ready." "services_ready"

  popd >/dev/null || return 1
}

# NOTE: final_message intentionally uses echo+tee for a clean human banner on stdout.
# The block is also appended to the log via tee, but WITHOUT timestamps/levels.
final_message() {
  {
    echo
    echo "✅ Setup is Complete!"
    echo
    if [[ -f "$ENV_FILE_PATH" ]]; then
      # shellcheck disable=SC1090
      source "$ENV_FILE_PATH"

      if [[ -n "${WIKIBASE_PUBLIC_HOST:-}" ]]; then
        echo "Your Wikibase Suite services can be found at:"
        echo
        echo "MediaWiki/Wikibase:"
        echo "https://$WIKIBASE_PUBLIC_HOST"
        echo
        echo "Query Service:"
        echo "https://${WDQS_PUBLIC_HOST:-query.$WIKIBASE_PUBLIC_HOST}"
        echo
        echo "QuickStatements:"
        echo "https://$WIKIBASE_PUBLIC_HOST/tools/quickstatements"
        echo
      else
        echo "⚠️ Could not determine WIKIBASE_PUBLIC_HOST from .env"
      fi

      echo
      echo "Your current configuration is saved at:"
      echo "  $ENV_FILE_PATH"
      echo
      echo "It includes the saved passwords and other setup values."
      echo "Keep it secure."
      echo
    else
      echo "⚠️ .env file not found at $ENV_FILE_PATH"
      echo
    fi
  } | tee -a "$LOG_PATH"
}

# --- Execution ---

wait_for_launch_signal
launch_deploy
status "Setup is complete." "setup_complete"
final_message

if $CLI && [[ -t 0 ]] && [[ -f "$ENV_FILE_PATH" ]]; then
  printf "Show the current saved configuration now, including passwords? [y/N]: "
  read -r show_config
  case "${show_config:-n}" in
    y|Y)
      echo
      echo "Saved configuration (.env):"
      echo
      sed 's/^/  /' "$ENV_FILE_PATH"
      echo
      ;;
  esac
fi
