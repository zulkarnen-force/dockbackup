#!/usr/bin/env bash
set -euo pipefail

TZ=${TZ:-Asia/Jakarta}
export TZ

BACKUP_DIR=${BACKUP_DIR:-/backup}
LABEL_FILTER=${LABEL_FILTER:-backup.enable=true}
INTERVAL=${INTERVAL:-5m}
MAX_FILES=${MAX_FILES:-7}
BACKUP_FORMAT=${BACKUP_FORMAT:-compress}

# ── Backup method: local | rclone | both ─────────────────────────────
BACKUP_METHOD=${BACKUP_METHOD:-local}

# ── Rclone settings ──────────────────────────────────────────────────

# Provider 1
RCLONE_1_PROVIDER=${RCLONE_1_PROVIDER:-}       # r2 | mega | pcloud
RCLONE_1_NAME=${RCLONE_1_NAME:-remote1}
RCLONE_1_REMOTE_PATH=${RCLONE_1_REMOTE_PATH:-backup}
# R2 (Cloudflare S3)
RCLONE_1_ACCESS_KEY_ID=${RCLONE_1_ACCESS_KEY_ID:-}
RCLONE_1_SECRET_ACCESS_KEY=${RCLONE_1_SECRET_ACCESS_KEY:-}
RCLONE_1_ENDPOINT=${RCLONE_1_ENDPOINT:-}
RCLONE_1_ACL=${RCLONE_1_ACL:-private}
# Mega
RCLONE_1_USER=${RCLONE_1_USER:-}
RCLONE_1_PASS=${RCLONE_1_PASS:-}
# PCloud
RCLONE_1_HOSTNAME=${RCLONE_1_HOSTNAME:-api.pcloud.com}
RCLONE_1_TOKEN=${RCLONE_1_TOKEN:-}

# Provider 2
RCLONE_2_PROVIDER=${RCLONE_2_PROVIDER:-}       # r2 | mega | pcloud
RCLONE_2_NAME=${RCLONE_2_NAME:-remote2}
RCLONE_2_REMOTE_PATH=${RCLONE_2_REMOTE_PATH:-backup}
# R2 (Cloudflare S3)
RCLONE_2_ACCESS_KEY_ID=${RCLONE_2_ACCESS_KEY_ID:-}
RCLONE_2_SECRET_ACCESS_KEY=${RCLONE_2_SECRET_ACCESS_KEY:-}
RCLONE_2_ENDPOINT=${RCLONE_2_ENDPOINT:-}
RCLONE_2_ACL=${RCLONE_2_ACL:-private}
# Mega
RCLONE_2_USER=${RCLONE_2_USER:-}
RCLONE_2_PASS=${RCLONE_2_PASS:-}
# PCloud
RCLONE_2_HOSTNAME=${RCLONE_2_HOSTNAME:-api.pcloud.com}
RCLONE_2_TOKEN=${RCLONE_2_TOKEN:-}

RCLONE_CONF="/tmp/rclone.conf"
# ─────────────────────────────────────────────────────────────────────

mkdir -p "$BACKUP_DIR"

log() {
  level=$1
  shift
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
}

# ── Parse human-friendly interval (e.g. 60s, 5m, 1h) to seconds ──
parse_interval() {
  local input="$1"
  local num unit
  if [[ "$input" =~ ^([0-9]+)([smh]?)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      s|'') echo "$num" ;;   # seconds (or bare number)
      m)    echo $(( num * 60 )) ;;
      h)    echo $(( num * 3600 )) ;;
    esac
  else
    log ERROR "Invalid INTERVAL format: '$input' (use e.g. 60s, 5m, 1h)"
    exit 1
  fi
}

format_interval() {
  local secs="$1"
  if (( secs >= 3600 && secs % 3600 == 0 )); then
    echo "$((secs / 3600))h"
  elif (( secs >= 60 && secs % 60 == 0 )); then
    echo "$((secs / 60))m"
  else
    echo "${secs}s"
  fi
}

INTERVAL_SECS=$(parse_interval "$INTERVAL")
INTERVAL_DISPLAY=$(format_interval "$INTERVAL_SECS")

# ── Rclone config generator ─────────────────────────────────────────
generate_rclone_remote() {
  local slot="$1"  # 1 or 2

  local provider_var="RCLONE_${slot}_PROVIDER"
  local name_var="RCLONE_${slot}_NAME"
  local provider="${!provider_var}"
  local name="${!name_var}"

  [[ -z "$provider" ]] && return

  log INFO "Configuring rclone remote [$name] with provider: $provider"

  case "$provider" in
    r2)
      local ak_var="RCLONE_${slot}_ACCESS_KEY_ID"
      local sk_var="RCLONE_${slot}_SECRET_ACCESS_KEY"
      local ep_var="RCLONE_${slot}_ENDPOINT"
      local acl_var="RCLONE_${slot}_ACL"
      cat >> "$RCLONE_CONF" <<EOF

[$name]
type = s3
provider = Cloudflare
access_key_id = ${!ak_var}
secret_access_key = ${!sk_var}
endpoint = ${!ep_var}
acl = ${!acl_var}
EOF
      ;;
    mega)
      local user_var="RCLONE_${slot}_USER"
      local pass_var="RCLONE_${slot}_PASS"
      local obscured_pass
      obscured_pass=$(rclone obscure "${!pass_var}")
      cat >> "$RCLONE_CONF" <<EOF

[$name]
type = mega
user = ${!user_var}
pass = $obscured_pass
EOF
      ;;
    pcloud)
      local host_var="RCLONE_${slot}_HOSTNAME"
      local token_var="RCLONE_${slot}_TOKEN"
      local raw_token="${!token_var}"
      # If the token is not already JSON, wrap it
      if [[ "$raw_token" != \{* ]]; then
        raw_token="{\"access_token\":\"${raw_token}\",\"token_type\":\"bearer\",\"expiry\":\"0001-01-01T00:00:00Z\"}"
      fi
      cat >> "$RCLONE_CONF" <<EOF

[$name]
type = pcloud
hostname = ${!host_var}
token = $raw_token
EOF
      ;;
    *)
      log ERROR "Unknown rclone provider: $provider (slot $slot)"
      ;;
  esac
}

setup_rclone() {
  if [[ "$BACKUP_METHOD" == "local" ]]; then
    return
  fi

  : > "$RCLONE_CONF"   # truncate / create

  generate_rclone_remote 1
  generate_rclone_remote 2

  log INFO "Rclone config written to $RCLONE_CONF"
}

rclone_upload() {
  local source_file="$1"
  local container_name="$2"

  if [[ "$BACKUP_METHOD" == "local" ]]; then
    return
  fi

  for slot in 1 2; do
    local provider_var="RCLONE_${slot}_PROVIDER"
    local name_var="RCLONE_${slot}_NAME"
    local path_var="RCLONE_${slot}_REMOTE_PATH"
    local provider="${!provider_var}"
    local name="${!name_var}"
    local remote_path="${!path_var}"

    [[ -z "$provider" ]] && continue

    local dest="${name}:${remote_path}/${container_name}/"

    log INFO "Uploading to rclone remote [$name] -> $dest"

    if rclone copy "$source_file" "$dest" --config "$RCLONE_CONF" 2>&1; then
      log INFO "Upload to [$name] completed"
      rclone_cleanup "$dest" "$name"
    else
      log ERROR "Upload to [$name] failed"
    fi
  done
}

rclone_cleanup() {
  local remote_dir="$1"
  local name="$2"

  local files
  files=$(rclone lsf "$remote_dir" --config "$RCLONE_CONF" 2>/dev/null | sort)
  local total
  total=$(echo "$files" | grep -c . || true)

  if (( total > MAX_FILES )); then
    local remove_count=$((total - MAX_FILES))
    log INFO "Rclone retention [$name]: removing $remove_count old backup(s)"

    echo "$files" | head -n "$remove_count" | while read -r f; do
      log INFO "Rclone removing: ${remote_dir}${f}"
      rclone deletefile "${remote_dir}${f}" --config "$RCLONE_CONF" 2>&1 || true
    done
  fi
}
# ─────────────────────────────────────────────────────────────────────

print_docs() {
  log INFO "------------------------------------------------------------"
  log INFO "Docker Database Backup Agent"
  log INFO ""
  log INFO "Container discovery label:"
  log INFO "  $LABEL_FILTER"
  log INFO ""
  log INFO "Supported databases (auto-detected from container image):"
  log INFO "  PostgreSQL  -> postgres, bitnami/postgresql"
  log INFO "  MySQL/Maria -> mysql, mariadb, bitnami/mysql, bitnami/mariadb"
  log INFO "  MongoDB     -> mongo, bitnami/mongodb"
  log INFO ""
  log INFO "Required container environment variables:"
  log INFO "  PostgreSQL : POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD"
  log INFO "  MySQL/Maria: MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD"
  log INFO "               (or MARIADB_DATABASE, MARIADB_USER, MARIADB_PASSWORD)"
  log INFO "  MongoDB    : MONGO_INITDB_DATABASE (optional),"
  log INFO "               MONGO_INITDB_ROOT_USERNAME, MONGO_INITDB_ROOT_PASSWORD"
  log INFO ""
  log INFO "Backup format:"
  log INFO "  BACKUP_FORMAT=$BACKUP_FORMAT"
  log INFO "    PostgreSQL : plain -> .sql  | compress -> .dump"
  log INFO "    MySQL/Maria: plain -> .sql  | compress -> .sql.gz"
  log INFO "    MongoDB    : always -> .archive (mongodump --archive)"
  log INFO ""
  log INFO "Backup location:"
  log INFO "  $BACKUP_DIR/<container_name>/"
  log INFO ""
  log INFO "Retention:"
  log INFO "  MAX_FILES=$MAX_FILES"
  log INFO ""
  log INFO "Backup method: $BACKUP_METHOD"
  if [[ "$BACKUP_METHOD" == "rclone" || "$BACKUP_METHOD" == "both" ]]; then
    [[ -n "$RCLONE_1_PROVIDER" ]] && log INFO "  Provider 1: $RCLONE_1_PROVIDER ($RCLONE_1_NAME -> $RCLONE_1_REMOTE_PATH)"
    [[ -n "$RCLONE_2_PROVIDER" ]] && log INFO "  Provider 2: $RCLONE_2_PROVIDER ($RCLONE_2_NAME -> $RCLONE_2_REMOTE_PATH)"
  fi
  log INFO "------------------------------------------------------------"
}

# ── Post-backup: upload + retention based on BACKUP_METHOD ───────────
post_backup() {
  local outfile="$1"
  local container_dir="$2"
  local container_name="$3"

  if [[ "$BACKUP_METHOD" == "rclone" || "$BACKUP_METHOD" == "both" ]]; then
    rclone_upload "$outfile" "$container_name"
  fi

  if [[ "$BACKUP_METHOD" == "rclone" ]]; then
    # rclone-only: remove local file after upload
    log INFO "Removing local file (backup method: rclone only)"
    rm -f "$outfile"
  else
    # local or both: apply local retention
    cleanup_old_backups "$container_dir"
  fi
}

cleanup_old_backups() {
  folder=$1

  total=$(ls -1 "$folder"/* 2>/dev/null | wc -l || true)

  if (( total > MAX_FILES )); then
    remove_count=$((total - MAX_FILES))

    log INFO "Retention policy: removing $remove_count old backup(s)"

    ls -1t "$folder"/* | tail -n "$remove_count" | while read -r file; do
      log INFO "Removing old backup: $file"
      rm -f "$file"
    done
  fi
}

run_backup() {

  containers=$(docker ps --filter "label=$LABEL_FILTER" --format "{{.Names}}")

  if [ -z "$containers" ]; then
    log WARN "No containers found with label: $LABEL_FILTER"
    return
  fi

  for container in $containers; do

    log INFO "Processing container: $container"

    # ── Detect database type from image name ──────────────
    local image_name
    image_name=$(docker inspect "$container" | jq -r '.[0].Config.Image' | tr '[:upper:]' '[:lower:]')

    local db_type=""
    case "$image_name" in
      *postgres*)                db_type="postgres" ;;
      *mysql*)                   db_type="mysql"    ;;
      *mariadb*)                 db_type="mysql"    ;;
      *mongo*)                   db_type="mongo"    ;;
      *)
        log WARN "Unknown database image: $image_name — skipping container: $container"
        continue
        ;;
    esac

    log INFO "Detected database type: $db_type (image: $image_name)"

    case "$db_type" in
      postgres) backup_postgres "$container" ;;
      mysql)    backup_mysql    "$container" ;;
      mongo)    backup_mongo    "$container" ;;
    esac

  done
}

# ── PostgreSQL backup ────────────────────────────────────────────────
backup_postgres() {
  local container="$1"
  local env_json
  env_json=$(docker inspect "$container" | jq '.[0].Config.Env')

  local pg_db pg_user pg_pass
  pg_db=$(echo "$env_json"   | jq -r '.[] | select(startswith("POSTGRES_DB="))       | split("=")[1]')
  pg_user=$(echo "$env_json" | jq -r '.[] | select(startswith("POSTGRES_USER="))     | split("=")[1]')
  pg_pass=$(echo "$env_json" | jq -r '.[] | select(startswith("POSTGRES_PASSWORD=")) | split("=")[1]')

  if [[ -z "$pg_db" || -z "$pg_user" || -z "$pg_pass" ]]; then
    log ERROR "Missing POSTGRES_DB / POSTGRES_USER / POSTGRES_PASSWORD in container: $container"
    return
  fi

  local container_dir="$BACKUP_DIR/$container"
  mkdir -p "$container_dir"
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")

  local outfile dump_cmd
  if [[ "$BACKUP_FORMAT" == "plain" ]]; then
    outfile="$container_dir/${pg_db}_${timestamp}.sql"
    dump_cmd="pg_dump -U $pg_user $pg_db"
  else
    outfile="$container_dir/${pg_db}_${timestamp}.dump"
    dump_cmd="pg_dump -U $pg_user -Fc $pg_db"
  fi

  log INFO "Creating backup -> $outfile"

  docker exec \
    -e PGPASSWORD="$pg_pass" \
    "$container" \
    sh -c "$dump_cmd" \
    > "$outfile"

  log INFO "Backup completed"
  post_backup "$outfile" "$container_dir" "$container"
}

# ── MySQL / MariaDB backup ──────────────────────────────────────────
backup_mysql() {
  local container="$1"
  local env_json
  env_json=$(docker inspect "$container" | jq '.[0].Config.Env')

  # Support both MYSQL_* and MARIADB_* env vars
  local my_db my_user my_pass

  my_db=$(echo "$env_json"   | jq -r '.[] | select(startswith("MYSQL_DATABASE="))    | split("=")[1]')
  my_user=$(echo "$env_json" | jq -r '.[] | select(startswith("MYSQL_USER="))        | split("=")[1]')
  my_pass=$(echo "$env_json" | jq -r '.[] | select(startswith("MYSQL_PASSWORD="))    | split("=")[1]')

  # Fall back to MARIADB_* variants
  [[ -z "$my_db" ]]   && my_db=$(echo "$env_json"   | jq -r '.[] | select(startswith("MARIADB_DATABASE="))    | split("=")[1]')
  [[ -z "$my_user" ]] && my_user=$(echo "$env_json" | jq -r '.[] | select(startswith("MARIADB_USER="))        | split("=")[1]')
  [[ -z "$my_pass" ]] && my_pass=$(echo "$env_json" | jq -r '.[] | select(startswith("MARIADB_PASSWORD="))    | split("=")[1]')

  # Fall back to root password if user/pass not set
  if [[ -z "$my_user" || -z "$my_pass" ]]; then
    local root_pass
    root_pass=$(echo "$env_json" | jq -r '.[] | select(startswith("MYSQL_ROOT_PASSWORD="))   | split("=")[1]')
    [[ -z "$root_pass" ]] && root_pass=$(echo "$env_json" | jq -r '.[] | select(startswith("MARIADB_ROOT_PASSWORD=")) | split("=")[1]')
    if [[ -n "$root_pass" ]]; then
      my_user="root"
      my_pass="$root_pass"
    fi
  fi

  if [[ -z "$my_db" || -z "$my_user" || -z "$my_pass" ]]; then
    log ERROR "Missing MYSQL_DATABASE / MYSQL_USER / MYSQL_PASSWORD (or MARIADB_ variants) in container: $container"
    return
  fi

  local container_dir="$BACKUP_DIR/$container"
  mkdir -p "$container_dir"
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")

  local outfile
  if [[ "$BACKUP_FORMAT" == "plain" ]]; then
    outfile="$container_dir/${my_db}_${timestamp}.sql"

    log INFO "Creating backup -> $outfile"
    docker exec "$container" \
      sh -c "mysqldump -u '$my_user' -p'$my_pass' '$my_db'" \
      > "$outfile"
  else
    outfile="$container_dir/${my_db}_${timestamp}.sql.gz"

    log INFO "Creating backup -> $outfile"
    docker exec "$container" \
      sh -c "mysqldump -u '$my_user' -p'$my_pass' '$my_db' | gzip" \
      > "$outfile"
  fi

  log INFO "Backup completed"
  post_backup "$outfile" "$container_dir" "$container"
}

# ── MongoDB backup ───────────────────────────────────────────────────
backup_mongo() {
  local container="$1"
  local env_json
  env_json=$(docker inspect "$container" | jq '.[0].Config.Env')

  local mongo_db mongo_user mongo_pass
  mongo_db=$(echo "$env_json"   | jq -r '.[] | select(startswith("MONGO_INITDB_DATABASE="))       | split("=")[1]')
  mongo_user=$(echo "$env_json" | jq -r '.[] | select(startswith("MONGO_INITDB_ROOT_USERNAME="))  | split("=")[1]')
  mongo_pass=$(echo "$env_json" | jq -r '.[] | select(startswith("MONGO_INITDB_ROOT_PASSWORD="))  | split("=")[1]')

  # Bitnami variants
  [[ -z "$mongo_user" ]] && mongo_user=$(echo "$env_json" | jq -r '.[] | select(startswith("MONGODB_ROOT_USER="))     | split("=")[1]')
  [[ -z "$mongo_pass" ]] && mongo_pass=$(echo "$env_json" | jq -r '.[] | select(startswith("MONGODB_ROOT_PASSWORD=")) | split("=")[1]')
  [[ -z "$mongo_db" ]]   && mongo_db=$(echo "$env_json"   | jq -r '.[] | select(startswith("MONGODB_DATABASE="))      | split("=")[1]')

  if [[ -z "$mongo_user" || -z "$mongo_pass" ]]; then
    log ERROR "Missing MONGO_INITDB_ROOT_USERNAME / MONGO_INITDB_ROOT_PASSWORD (or MONGODB_ variants) in container: $container"
    return
  fi

  local container_dir="$BACKUP_DIR/$container"
  mkdir -p "$container_dir"
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")

  local db_label="${mongo_db:-all_databases}"
  local outfile="$container_dir/${db_label}_${timestamp}.archive"

  log INFO "Creating backup -> $outfile"

  local dump_cmd="mongodump --authenticationDatabase admin -u '$mongo_user' -p '$mongo_pass' --archive"
  if [[ -n "$mongo_db" ]]; then
    dump_cmd="mongodump --authenticationDatabase admin -u '$mongo_user' -p '$mongo_pass' --db '$mongo_db' --archive"
  fi

  docker exec "$container" \
    sh -c "$dump_cmd" \
    > "$outfile"

  log INFO "Backup completed"
  post_backup "$outfile" "$container_dir" "$container"
}

next_run_time() {
  next_ts=$(( $(date +%s) + INTERVAL_SECS ))
  date -d "@$next_ts" '+%Y-%m-%d %H:%M:%S %Z'
}

print_docs
setup_rclone
log INFO "Backup agent started"
log INFO "Backup interval: $INTERVAL_DISPLAY ($INTERVAL_SECS seconds)"

while true; do
  log INFO "Starting backup cycle"
  run_backup
  next_run=$(next_run_time)
  log INFO "Next backup scheduled at: $next_run"
  sleep "$INTERVAL_SECS"
done