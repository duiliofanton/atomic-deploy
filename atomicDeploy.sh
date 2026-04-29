#!/bin/bash
set -Eeuo pipefail

# =========================================================
# CONFIGURATION
# =========================================================
# FORMAT:
# PROJECTS["name"]="repo_url|branch|php_bin|frontend_cmd|composer_mode|run_migrations|artisan_healthcheck"
#
# composer_mode: prod | dev
# run_migrations: yes | no
# frontend_cmd: build | dev | none
# artisan_healthcheck: e.g. "about" or "route:list"

declare -A PROJECTS
PROJECTS["atomic_deploy_example_laravel_13"]="git@github.com:DuilioFanton/atomic-deploy-project-example-laravel-13.git|master|/usr/bin/php|build|prod|yes|about"
# PROJECTS["project_1"]="git@github.com:org/project_1.git|main|/usr/bin/php8.4|build|prod|yes|about"
# PROJECTS["project_2"]="git@github.com:org/project_2.git|main|/usr/bin/php8.3|none|prod|no|route:list"

BASE_ROOT="${BASE_ROOT:-/var/www}"
APP_USER="${APP_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
# User used for git clone and frontend build steps (defaults to current user)
DEPLOY_USER="${DEPLOY_USER:-$(id -un)}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
LOCK_FILE="${LOCK_FILE:-/tmp/atomic_deploy.lock}"
AUTO_GENERATE_APP_KEY="${AUTO_GENERATE_APP_KEY:-no}"
SHARED_ENV_BOOTSTRAPPED="no"

# =========================================================
# DEPLOY LOCK
# =========================================================
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo "Another deploy is already running."
    exit 1
}

# =========================================================
# HELPER FUNCTIONS
# =========================================================
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

fail_with_error() {
    log_message "ERROR: $1"
    return 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail_with_error "Required command not found: $1"
}

run_as_root() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_as_user() {
    local target_user="$1"
    shift

    if [ "$(id -un)" = "$target_user" ]; then
        "$@"
    elif [ "$EUID" -eq 0 ]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "$target_user" -- "$@"
        elif command -v sudo >/dev/null 2>&1; then
            sudo -u "$target_user" "$@"
        else
            fail_with_error "Cannot switch to user '$target_user' without runuser/sudo"
        fi
    else
        sudo -u "$target_user" "$@"
    fi
}

run_as_app_user() {
    run_as_user "$APP_USER" "$@"
}

run_as_deploy_user() {
    run_as_user "$DEPLOY_USER" "$@"
}

run_artisan() {
    local php_bin="$1"
    local release_dir="$2"
    shift 2

    run_as_app_user "$php_bin" "$release_dir/artisan" "$@"
}

validate_php_binary() {
    local php_bin="$1"

    [ -x "$php_bin" ] || fail_with_error "Invalid or missing PHP binary: $php_bin"
}

validate_project_key() {
    local project_key="$1"

    [[ "$project_key" =~ ^[a-zA-Z0-9._-]+$ ]] || fail_with_error "Invalid project key: $project_key"
}

validate_project_config() {
    local project_key="$1"
    local config="$2"
    local -a parts=()

    IFS="|" read -r -a parts <<< "$config"

    [ "${#parts[@]}" -eq 7 ] || fail_with_error "Invalid config for '$project_key'. Expected: repo_url|branch|php_bin|frontend_cmd|composer_mode|run_migrations|artisan_healthcheck"

    local repo_url="${parts[0]}"
    local branch="${parts[1]}"
    local php_bin="${parts[2]}"
    local frontend_cmd="${parts[3]}"
    local composer_mode="${parts[4]}"
    local run_migrations="${parts[5]}"
    local artisan_healthcheck="${parts[6]}"

    [ -n "$repo_url" ] || fail_with_error "repo_url is empty for '$project_key'"
    [ -n "$branch" ] || fail_with_error "branch is empty for '$project_key'"
    [ -n "$php_bin" ] || fail_with_error "php_bin is empty for '$project_key'"
    [[ "$php_bin" = /* ]] || fail_with_error "php_bin must be an absolute path for '$project_key'"

    case "$frontend_cmd" in
        none|build|dev)
            ;;
        "")
            fail_with_error "frontend_cmd is empty for '$project_key'"
            ;;
        *)
            if [[ "$frontend_cmd" =~ [[:space:]] ]]; then
                fail_with_error "frontend_cmd must not contain spaces for '$project_key'"
            fi
            ;;
    esac

    case "$composer_mode" in
        prod|dev)
            ;;
        *)
            fail_with_error "Invalid composer_mode for '$project_key': $composer_mode (use prod or dev)"
            ;;
    esac

    case "$run_migrations" in
        yes|no)
            ;;
        *)
            fail_with_error "Invalid run_migrations for '$project_key': $run_migrations (use yes or no)"
            ;;
    esac

    [ -n "$artisan_healthcheck" ] || fail_with_error "artisan_healthcheck is empty for '$project_key'"
    if [[ "$artisan_healthcheck" =~ [[:space:]] ]]; then
        fail_with_error "artisan_healthcheck must not contain spaces for '$project_key'"
    fi
}

ensure_base_commands() {
    require_command git
    require_command composer
    require_command ln
    require_command rm
    require_command mkdir
    require_command chmod
    require_command chown
    require_command readlink
    require_command flock
    require_command grep
    require_command awk
    require_command cp
    require_command sort
    require_command id
    require_command getent
    require_command dirname
    require_command touch

    if [ "$EUID" -ne 0 ]; then
        require_command sudo
    fi

    if [ "$EUID" -eq 0 ] && { [ "$(id -un)" != "$APP_USER" ] || [ "$(id -un)" != "$DEPLOY_USER" ]; }; then
        if ! command -v runuser >/dev/null 2>&1 && ! command -v sudo >/dev/null 2>&1; then
            fail_with_error "Run as $APP_USER/$DEPLOY_USER or install runuser/sudo"
        fi
    fi

    id -u "$APP_USER" >/dev/null 2>&1 || fail_with_error "APP_USER does not exist: $APP_USER"
    id -u "$DEPLOY_USER" >/dev/null 2>&1 || fail_with_error "DEPLOY_USER does not exist: $DEPLOY_USER"
    getent group "$WEB_GROUP" >/dev/null 2>&1 || fail_with_error "WEB_GROUP does not exist: $WEB_GROUP"

    [[ "$KEEP_RELEASES" =~ ^[1-9][0-9]*$ ]] || fail_with_error "KEEP_RELEASES must be a positive integer"

    case "$AUTO_GENERATE_APP_KEY" in
        yes|no)
            ;;
        *)
            fail_with_error "Invalid AUTO_GENERATE_APP_KEY: $AUTO_GENERATE_APP_KEY (use yes or no)"
            ;;
    esac
}

ensure_project_structure() {
    local project_key="$1"
    local project_root="$BASE_ROOT/$project_key"
    local releases_dir="$project_root/releases"
    local shared_dir="$project_root/shared"

    log_message "Ensuring base project structure: $project_key"

    run_as_root mkdir -p "$releases_dir"
    run_as_root mkdir -p "$shared_dir/storage"
    run_as_root mkdir -p "$shared_dir/bootstrap/cache"

    run_as_root mkdir -p "$shared_dir/storage/app"
    run_as_root mkdir -p "$shared_dir/storage/framework/cache"
    run_as_root mkdir -p "$shared_dir/storage/framework/sessions"
    run_as_root mkdir -p "$shared_dir/storage/framework/views"
    run_as_root mkdir -p "$shared_dir/storage/logs"

    run_as_root chown "$APP_USER:$WEB_GROUP" "$project_root" "$shared_dir"
    run_as_root chown "$DEPLOY_USER:$WEB_GROUP" "$releases_dir"
    run_as_root chmod 2775 "$project_root" "$releases_dir" "$shared_dir"

    run_as_root chown -R "$APP_USER:$WEB_GROUP" "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    run_as_root chmod -R 775 "$shared_dir/storage" "$shared_dir/bootstrap/cache"
}

cleanup_old_releases() {
    local releases_dir="$1"
    local current_symlink="$2"
    local current_target=""
    local release_path
    local -a releases=()
    local -a sorted_releases=()
    local index

    if [ -L "$current_symlink" ] || [ -e "$current_symlink" ]; then
        current_target="$(readlink -f "$current_symlink" || true)"
    fi

    shopt -s nullglob
    for release_path in "$releases_dir"/*; do
        [ -d "$release_path" ] || continue
        releases+=("$release_path")
    done
    shopt -u nullglob

    [ "${#releases[@]}" -le "$KEEP_RELEASES" ] && return 0

    mapfile -t sorted_releases < <(printf '%s\n' "${releases[@]}" | sort -r)

    for ((index = KEEP_RELEASES; index < ${#sorted_releases[@]}; index++)); do
        if [ -n "$current_target" ] && [ "${sorted_releases[$index]}" = "$current_target" ]; then
            continue
        fi
        run_as_root rm -rf "${sorted_releases[$index]}"
    done
}

check_repository_access() {
    local repo_url="$1"

    run_as_deploy_user git ls-remote "$repo_url" >/dev/null 2>&1 || fail_with_error "Cannot access repository: $repo_url"
}

install_node_dependencies_and_build() {
    local release_dir="$1"
    local frontend_cmd="$2"

    if [ ! -f "$release_dir/package.json" ]; then
        log_message "No package.json found, skipping Node step"
        return 0
    fi

    if [ -f "$release_dir/yarn.lock" ]; then
        require_command yarn
        log_message "Installing Node dependencies with Yarn"
        run_as_deploy_user yarn --cwd "$release_dir" install --frozen-lockfile

        if [ "$frontend_cmd" != "none" ]; then
            log_message "Running frontend build: yarn run $frontend_cmd"
            run_as_deploy_user yarn --cwd "$release_dir" run "$frontend_cmd"
        fi
        return 0
    fi

    if [ -f "$release_dir/pnpm-lock.yaml" ]; then
        require_command pnpm
        log_message "Installing Node dependencies with pnpm"
        run_as_deploy_user pnpm --dir "$release_dir" install --frozen-lockfile

        if [ "$frontend_cmd" != "none" ]; then
            log_message "Running frontend build: pnpm run $frontend_cmd"
            run_as_deploy_user pnpm --dir "$release_dir" run "$frontend_cmd"
        fi
        return 0
    fi

    if [ -f "$release_dir/package-lock.json" ]; then
        require_command npm
        log_message "Installing Node dependencies with npm"
        run_as_deploy_user npm --prefix "$release_dir" ci

        if [ "$frontend_cmd" != "none" ]; then
            log_message "Running frontend build: npm run $frontend_cmd"
            run_as_deploy_user npm --prefix "$release_dir" run "$frontend_cmd"
        fi
        return 0
    fi

    fail_with_error "package.json found, but no lockfile found. Aborting for safety."
}

run_composer_install() {
    local php_bin="$1"
    local composer_mode="$2"
    local release_dir="$3"
    local composer_bin

    composer_bin="$(command -v composer)" || fail_with_error "Composer not found"

    if [ "$composer_mode" = "prod" ]; then
        run_as_app_user "$php_bin" "$composer_bin" install \
            --working-dir="$release_dir" \
            --no-dev \
            --prefer-dist \
            --optimize-autoloader \
            --no-interaction \
            --no-progress
    else
        run_as_app_user "$php_bin" "$composer_bin" install \
            --working-dir="$release_dir" \
            --prefer-dist \
            --no-interaction \
            --no-progress
    fi
}

prepare_composer_vendor_for_frontend() {
    local php_bin="$1"
    local composer_mode="$2"
    local release_dir="$3"
    local frontend_cmd="$4"
    local composer_bin

    [ "$frontend_cmd" != "none" ] || return 0
    [ -f "$release_dir/package.json" ] || return 0
    [ -f "$release_dir/composer.json" ] || return 0

    composer_bin="$(command -v composer)" || fail_with_error "Composer not found"

    log_message "Preparing Composer vendor directory for frontend build"

    if [ "$composer_mode" = "prod" ]; then
        run_as_deploy_user "$php_bin" "$composer_bin" install \
            --working-dir="$release_dir" \
            --no-dev \
            --prefer-dist \
            --no-autoloader \
            --no-scripts \
            --no-interaction \
            --no-progress
    else
        run_as_deploy_user "$php_bin" "$composer_bin" install \
            --working-dir="$release_dir" \
            --prefer-dist \
            --no-autoloader \
            --no-scripts \
            --no-interaction \
            --no-progress
    fi
}

run_release_health_check() {
    local php_bin="$1"
    local release_dir="$2"
    local artisan_cmd="$3"

    log_message "Running release health check: php artisan $artisan_cmd"
    run_artisan "$php_bin" "$release_dir" "$artisan_cmd" >/dev/null 2>&1 || fail_with_error "Health check failed for release"
}

ensure_shared_env_from_example() {
    local shared_dir="$1"
    local release_dir="$2"

    SHARED_ENV_BOOTSTRAPPED="no"

    if [ ! -f "$shared_dir/.env" ]; then
        log_message "Creating shared .env from .env.example"

        if [ -f "$release_dir/.env.example" ]; then
            run_as_root cp "$release_dir/.env.example" "$shared_dir/.env"
            run_as_root chown "$APP_USER:$WEB_GROUP" "$shared_dir/.env"
            run_as_root chmod 640 "$shared_dir/.env"
            SHARED_ENV_BOOTSTRAPPED="yes"

            log_message "Created file: $shared_dir/.env"
            log_message "WARNING: review environment variables before production use"
        else
            fail_with_error ".env.example not found in repository"
        fi
    fi
}

link_shared_env_file() {
    local release_dir="$1"
    local shared_dir="$2"

    [ -f "$shared_dir/.env" ] || fail_with_error "Shared .env file not found"

    if [ -e "$release_dir/.env" ] || [ -L "$release_dir/.env" ]; then
        run_as_deploy_user rm -rf "$release_dir/.env"
    fi

    run_as_deploy_user ln -s "$shared_dir/.env" "$release_dir/.env"
}

prepare_release_env_for_frontend_build() {
    local release_dir="$1"
    local shared_dir="$2"
    local frontend_cmd="$3"

    [ -f "$shared_dir/.env" ] || fail_with_error "Shared .env file not found"

    if [ "$frontend_cmd" = "none" ] || [ ! -f "$release_dir/package.json" ]; then
        link_shared_env_file "$release_dir" "$shared_dir"
        return 0
    fi

    log_message "Creating temporary .env for frontend build"

    if [ -e "$release_dir/.env" ] || [ -L "$release_dir/.env" ]; then
        run_as_deploy_user rm -rf "$release_dir/.env"
    fi

    run_as_root cp "$shared_dir/.env" "$release_dir/.env"
    run_as_root chown "$DEPLOY_USER:$WEB_GROUP" "$release_dir/.env"
    run_as_root chmod 640 "$release_dir/.env"
}

ensure_app_key() {
    local php_bin="$1"
    local release_dir="$2"
    local shared_dir="$3"

    if run_as_app_user grep -Eq '^APP_KEY=.+$' "$shared_dir/.env"; then
        return 0
    fi

    if [ "$AUTO_GENERATE_APP_KEY" = "yes" ]; then
        log_message "APP_KEY is missing. Auto-generating it (AUTO_GENERATE_APP_KEY=yes)..."
        run_artisan "$php_bin" "$release_dir" key:generate --force
        return 0
    fi

    if [ "$SHARED_ENV_BOOTSTRAPPED" = "yes" ]; then
        log_message "APP_KEY is missing in a newly created shared .env. Auto-generating for first deploy..."
        run_artisan "$php_bin" "$release_dir" key:generate --force
        return 0
    fi

    fail_with_error "APP_KEY missing in $shared_dir/.env. Set it manually or use AUTO_GENERATE_APP_KEY=yes"
}

read_env_value() {
    local env_file="$1"
    local key="$2"

    run_as_app_user awk -F= -v k="$key" '
        $0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ {
            next
        }
        index($0, k "=") == 1 {
            value = substr($0, length(k) + 2)
            sq = sprintf("%c", 39)
            if ((substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") || (substr(value, 1, 1) == sq && substr(value, length(value), 1) == sq)) {
                value = substr(value, 2, length(value) - 2)
            }
            print value
            found = 1
            exit 0
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$env_file"
}

ensure_sqlite_database_if_needed() {
    local release_dir="$1"
    local shared_dir="$2"
    local env_file="$release_dir/.env"
    local db_connection=""
    local db_database=""
    local db_path=""
    local db_dir=""
    local shared_db_path=""
    local shared_db_dir=""

    db_connection="$(read_env_value "$env_file" "DB_CONNECTION" || true)"
    [ "$db_connection" = "sqlite" ] || return 0

    db_database="$(read_env_value "$env_file" "DB_DATABASE" || true)"
    if [ -z "$db_database" ] || [ "$db_database" = "null" ]; then
        db_database="database/database.sqlite"
    fi

    if [[ "$db_database" = /* ]]; then
        db_path="$db_database"
    else
        db_path="$release_dir/$db_database"
        shared_db_path="$shared_dir/$db_database"
    fi

    if [ -n "$shared_db_path" ]; then
        shared_db_dir="$(dirname "$shared_db_path")"
        run_as_app_user mkdir -p "$shared_db_dir"
        if [ ! -f "$shared_db_path" ]; then
            run_as_app_user touch "$shared_db_path"
            log_message "Created shared SQLite database file for sqlite environment: $shared_db_path"
        fi

        db_dir="$(dirname "$db_path")"
        run_as_app_user mkdir -p "$db_dir"
        if [ -e "$db_path" ] || [ -L "$db_path" ]; then
            run_as_app_user rm -f "$db_path"
        fi
        run_as_app_user ln -s "$shared_db_path" "$db_path"
        return 0
    fi

    db_dir="$(dirname "$db_path")"
    run_as_app_user mkdir -p "$db_dir"
    if [ ! -f "$db_path" ]; then
        run_as_app_user touch "$db_path"
        log_message "Created SQLite database file for sqlite environment: $db_path"
    fi
}

deploy_project() {
    local project_key="$1"
    local config="$2"
    local repo_url
    local branch
    local php_bin
    local frontend_cmd
    local composer_mode
    local run_migrations
    local artisan_healthcheck

    validate_project_key "$project_key"
    validate_project_config "$project_key" "$config"

    IFS="|" read -r repo_url branch php_bin frontend_cmd composer_mode run_migrations artisan_healthcheck <<< "$config"

    local project_root="$BASE_ROOT/$project_key"
    local releases_dir="$project_root/releases"
    local shared_dir="$project_root/shared"
    local current_symlink="$project_root/current"
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local release_dir="$releases_dir/$timestamp"
    local previous_release=""
    local current_switched="no"

    log_message "========================================================="
    log_message "Starting deploy for project: $project_key"
    log_message "Repository: $repo_url"
    log_message "Branch: $branch"
    log_message "New release: $release_dir"

    validate_php_binary "$php_bin"
    check_repository_access "$repo_url"
    ensure_project_structure "$project_key"

    if [ -L "$current_symlink" ] || [ -e "$current_symlink" ]; then
        previous_release="$(readlink -f "$current_symlink" || true)"
        if [ -n "$previous_release" ]; then
            log_message "Current release: $previous_release"
        fi
    fi

    rollback_on_error() {
        local rollback_error=0

        trap - ERR
        log_message "Failure detected during deploy of $project_key"

        if [ "$current_switched" = "yes" ]; then
            if [ -n "$previous_release" ] && [ -d "$previous_release" ]; then
                run_as_root ln -sfn "$previous_release" "$current_symlink" || rollback_error=1
                log_message "Restored current symlink to: $previous_release"
            else
                run_as_root rm -f "$current_symlink" || rollback_error=1
                log_message "Removed current symlink (no previous release found)"
            fi
        fi

        if [ -d "$release_dir" ]; then
            run_as_root rm -rf "$release_dir" || rollback_error=1
            log_message "Removed failed release: $release_dir"
        fi

        if [ "$rollback_error" -ne 0 ]; then
            log_message "WARNING: rollback completed with errors. Check manually: $current_symlink"
        else
            log_message "Rollback completed successfully"
        fi
    }

    trap rollback_on_error ERR

    log_message "Cloning repository"
    run_as_deploy_user git clone --branch "$branch" --single-branch --depth 1 "$repo_url" "$release_dir"

    local current_branch
    current_branch="$(run_as_deploy_user git -C "$release_dir" rev-parse --abbrev-ref HEAD)"
    [ "$current_branch" = "$branch" ] || fail_with_error "Cloned wrong branch. Expected: $branch | Got: $current_branch"

    SHARED_ENV_BOOTSTRAPPED="no"
    ensure_shared_env_from_example "$shared_dir" "$release_dir"

    log_message "Configuring shared links"
    run_as_deploy_user rm -rf "$release_dir/storage"
    run_as_deploy_user ln -s "$shared_dir/storage" "$release_dir/storage"

    run_as_deploy_user mkdir -p "$release_dir/bootstrap"
    run_as_deploy_user rm -rf "$release_dir/bootstrap/cache"
    run_as_deploy_user ln -s "$shared_dir/bootstrap/cache" "$release_dir/bootstrap/cache"

    prepare_release_env_for_frontend_build "$release_dir" "$shared_dir" "$frontend_cmd"

    log_message "Applying initial permissions"
    run_as_root chown -R "$APP_USER:$WEB_GROUP" "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    run_as_root chown "$APP_USER:$WEB_GROUP" "$shared_dir/.env"
    run_as_root chmod -R 775 "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    run_as_root chmod 640 "$shared_dir/.env"

    prepare_composer_vendor_for_frontend "$php_bin" "$composer_mode" "$release_dir" "$frontend_cmd"

    log_message "Installing/building frontend when applicable"
    install_node_dependencies_and_build "$release_dir" "$frontend_cmd"

    log_message "Linking shared .env into release"
    link_shared_env_file "$release_dir" "$shared_dir"

    run_as_root chown -R "$APP_USER:$WEB_GROUP" "$release_dir"

    log_message "Installing PHP dependencies"
    run_composer_install "$php_bin" "$composer_mode" "$release_dir"

    ensure_app_key "$php_bin" "$release_dir" "$shared_dir"
    ensure_sqlite_database_if_needed "$release_dir" "$shared_dir"

    if [ "$run_migrations" = "yes" ]; then
        log_message "Running database migrations"
        run_artisan "$php_bin" "$release_dir" migrate --force
    else
        log_message "Database migrations are disabled for this project"
    fi

    log_message "Clearing Laravel caches"
    run_artisan "$php_bin" "$release_dir" optimize:clear

    log_message "Regenerating services manifest"
    run_artisan "$php_bin" "$release_dir" package:discover

    log_message "Warming Laravel caches"
    run_artisan "$php_bin" "$release_dir" config:cache
    run_artisan "$php_bin" "$release_dir" route:cache || true
    run_artisan "$php_bin" "$release_dir" view:cache || true
    run_artisan "$php_bin" "$release_dir" event:cache || true
    run_artisan "$php_bin" "$release_dir" storage:link || true

    run_release_health_check "$php_bin" "$release_dir" "$artisan_healthcheck"

    log_message "Switching current symlink"
    run_as_root ln -sfn "$release_dir" "$current_symlink"
    current_switched="yes"

    log_message "Restarting queues"
    run_artisan "$php_bin" "$release_dir" queue:restart || true

    log_message "Applying final permissions"
    run_as_root chown -R "$APP_USER:$WEB_GROUP" "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    run_as_root chmod -R 775 "$shared_dir/storage" "$shared_dir/bootstrap/cache"

    log_message "Cleaning old releases"
    cleanup_old_releases "$releases_dir" "$current_symlink"

    trap - ERR

    log_message "Deploy completed successfully for $project_key"
    log_message "Current -> $(readlink -f "$current_symlink")"
}

# =========================================================
# EXECUTION
# =========================================================
ensure_base_commands

[ "${#PROJECTS[@]}" -gt 0 ] || fail_with_error "No projects configured in the PROJECTS array"

log_message "Starting deploy process"

for project_key in "${!PROJECTS[@]}"; do
    deploy_project "$project_key" "${PROJECTS[$project_key]}"
done

log_message "Deploy process completed successfully"
