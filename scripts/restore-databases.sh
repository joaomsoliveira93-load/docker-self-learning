#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

set -a
source .env
set +a

MYSQL_BACKUP_DIR="backups/mysql"
MONGO_BACKUP_DIR="backups/mongo"

RESTORE_MYSQL=true
RESTORE_MONGO=true
RESTORE_LABEL="MySQL and MongoDB"

echo ""
echo "Available backup dates:"
echo ""

{
  if [ "$RESTORE_MYSQL" = true ]; then
    for file in "$MYSQL_BACKUP_DIR"/*_"$MYSQL_DATABASE".sql.gz; do
      [ -e "$file" ] || continue
      basename "$file" | cut -d "_" -f 1
    done
  fi

  if [ "$RESTORE_MONGO" = true ]; then
    for file in "$MONGO_BACKUP_DIR"/*_"$MONGO_DATABASE".archive.gz; do
      [ -e "$file" ] || continue
      basename "$file" | cut -d "_" -f 1
    done
  fi
} | sort -u

echo ""
read -rp "Enter the backup date to restore, for example YYYY-MM-DD: " RESTORE_DATE

shopt -s nullglob

MYSQL_DATA_FILE=""
MYSQL_FILES_FILE=""
MONGO_DATA_FILE=""
MONGO_FILES_FILE=""

if [ "$RESTORE_MYSQL" = true ]; then
  MYSQL_DATA_MATCHES=("$MYSQL_BACKUP_DIR"/"${RESTORE_DATE}"_"${MYSQL_DATABASE}".sql.gz)
  MYSQL_FILES_MATCHES=("$MYSQL_BACKUP_DIR"/"${RESTORE_DATE}"_"${MYSQL_DATABASE}".files.tar.gz)

  if [ "${#MYSQL_DATA_MATCHES[@]}" -eq 0 ]; then
    echo "No MySQL logical backup found for date: $RESTORE_DATE"
    exit 1
  fi
  if [ "${#MYSQL_FILES_MATCHES[@]}" -eq 0 ]; then
    echo "No MySQL file-level backup found for date: $RESTORE_DATE"
    exit 1
  fi

  MYSQL_DATA_FILE="${MYSQL_DATA_MATCHES[0]}"
  MYSQL_FILES_FILE="${MYSQL_FILES_MATCHES[0]}"
fi

if [ "$RESTORE_MONGO" = true ]; then
  MONGO_DATA_MATCHES=("$MONGO_BACKUP_DIR"/"${RESTORE_DATE}"_"${MONGO_DATABASE}".archive.gz)
  MONGO_FILES_MATCHES=("$MONGO_BACKUP_DIR"/"${RESTORE_DATE}"_"${MONGO_DATABASE}".files.tar.gz)

  if [ "${#MONGO_DATA_MATCHES[@]}" -eq 0 ]; then
    echo "No MongoDB logical backup found for date: $RESTORE_DATE"
    exit 1
  fi
  if [ "${#MONGO_FILES_MATCHES[@]}" -eq 0 ]; then
    echo "No MongoDB file-level backup found for date: $RESTORE_DATE"
    exit 1
  fi

  MONGO_DATA_FILE="${MONGO_DATA_MATCHES[0]}"
  MONGO_FILES_FILE="${MONGO_FILES_MATCHES[0]}"
fi

shopt -u nullglob

echo ""
echo "You are about to restore: $RESTORE_LABEL (logical + file-level)"

if [ "$RESTORE_MYSQL" = true ]; then
  echo "  MySQL logical:      $MYSQL_DATA_FILE"
  echo "  MySQL file-level:   $MYSQL_FILES_FILE"
fi

if [ "$RESTORE_MONGO" = true ]; then
  echo "  MongoDB logical:    $MONGO_DATA_FILE"
  echo "  MongoDB file-level: $MONGO_FILES_FILE"
fi

echo ""
read -rp "This can overwrite existing data. Continue? [yes/no] or [y/n]: " CONFIRM

if [[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]]; then
  echo "Restore cancelled."
  exit 0
fi

echo ""
echo "Starting containers..."
docker compose up -d


if [ "$RESTORE_MYSQL" = true ]; then
  echo ""
  echo "Restoring MySQL file-level backup..."
  docker compose stop mysql

  MYSQL_VOLUME=$(docker inspect "$MYSQL_CONTAINER" \
    --format '{{ range .Mounts }}{{ if eq .Destination "/var/lib/mysql" }}{{ .Name }}{{ end }}{{ end }}')

  docker run --rm \
    -v "${MYSQL_VOLUME}:/data" \
    -v "$(pwd)/${MYSQL_BACKUP_DIR}:/backup" \
    alpine sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xzf '/backup/$(basename "$MYSQL_FILES_FILE")' -C /data"

  docker compose start mysql
  echo "MySQL file-level restore completed."
fi

if [ "$RESTORE_MONGO" = true ]; then
  echo ""
  echo "Restoring MongoDB file-level backup..."
  docker compose stop mongo

  MONGO_VOLUME=$(docker inspect "$MONGO_CONTAINER" \
    --format '{{ range .Mounts }}{{ if eq .Destination "/data/db" }}{{ .Name }}{{ end }}{{ end }}')

  docker run --rm \
    -v "${MONGO_VOLUME}:/data" \
    -v "$(pwd)/${MONGO_BACKUP_DIR}:/backup" \
    alpine sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xzf '/backup/$(basename "$MONGO_FILES_FILE")' -C /data"

  docker compose start mongo
  echo "MongoDB file-level restore completed."
fi


if [ "$RESTORE_MYSQL" = true ]; then
  echo ""
  echo "Waiting for MySQL..."
  until docker exec "$MYSQL_CONTAINER" mysqladmin ping \
    -h 127.0.0.1 \
    -uroot \
    -p"$MYSQL_ROOT_PASSWORD" \
    --silent; do
    sleep 2
  done
fi

if [ "$RESTORE_MONGO" = true ]; then
  echo "Waiting for MongoDB..."
  until docker exec "$MONGO_CONTAINER" mongosh \
    --quiet \
    -u "$MONGO_ROOT_USERNAME" \
    -p "$MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --eval "db.adminCommand('ping').ok" >/dev/null; do
    sleep 2
  done
fi

if [ "$RESTORE_MYSQL" = true ]; then
  echo ""
  echo "Restoring MySQL logical backup..."
  docker cp "$MYSQL_DATA_FILE" "$MYSQL_CONTAINER:/tmp/mysql-restore.sql.gz"

  docker exec \
    -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
    -i "$MYSQL_CONTAINER" \
    sh -c "gzip -dc /tmp/mysql-restore.sql.gz | mysql -uroot"

  docker exec "$MYSQL_CONTAINER" rm -f /tmp/mysql-restore.sql.gz
  echo "MySQL logical restore completed."
fi

if [ "$RESTORE_MONGO" = true ]; then
  echo ""
  echo "Restoring MongoDB logical backup..."

  if docker exec "$MONGO_CONTAINER" sh -c "command -v mongorestore >/dev/null 2>&1"; then
    docker cp "$MONGO_DATA_FILE" "$MONGO_CONTAINER:/tmp/mongo-restore.archive.gz"

    docker exec "$MONGO_CONTAINER" mongorestore \
      --host 127.0.0.1 \
      --port 27017 \
      -u "$MONGO_ROOT_USERNAME" \
      -p "$MONGO_ROOT_PASSWORD" \
      --authenticationDatabase admin \
      --archive=/tmp/mongo-restore.archive.gz \
      --gzip \
      --drop

    docker exec "$MONGO_CONTAINER" rm -f /tmp/mongo-restore.archive.gz
  else
    echo "mongorestore not found inside MongoDB container."
    echo "Using temporary MongoDB database tools container..."

    MONGO_DATA_FILENAME="$(basename "$MONGO_DATA_FILE")"

    docker run --rm \
      --network "container:${MONGO_CONTAINER}" \
      -v "$(pwd)/${MONGO_BACKUP_DIR}:/backup" \
      mongodb/mongodb-database-tools \
      mongorestore \
        --host 127.0.0.1 \
        --port 27017 \
        -u "$MONGO_ROOT_USERNAME" \
        -p "$MONGO_ROOT_PASSWORD" \
        --authenticationDatabase admin \
        --archive="/backup/${MONGO_DATA_FILENAME}" \
        --gzip \
        --drop
  fi

  echo "MongoDB logical restore completed."
fi

echo ""
echo "Restore completed successfully."
echo ""
echo "Restored backup date:"
echo "  $RESTORE_DATE"

if [ "$RESTORE_MYSQL" = true ]; then
  echo ""
  echo "MySQL database:"
  echo "  $MYSQL_DATABASE"
fi

if [ "$RESTORE_MONGO" = true ]; then
  echo ""
  echo "MongoDB database:"
  echo "  $MONGO_DATABASE"
fi