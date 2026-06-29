#!/usr/bin/env bash
set -euo pipefail

set -a
source .env
set +a

BACKUP_DATE="$(date +"%Y-%m-%d")"

MYSQL_BACKUP_DIR="backups/mysql"
MONGO_BACKUP_DIR="backups/mongo"

MYSQL_DATA_BACKUP="${MYSQL_BACKUP_DIR}/${BACKUP_DATE}_${MYSQL_DATABASE}.sql.gz"
MONGO_DATA_BACKUP="${MONGO_BACKUP_DIR}/${BACKUP_DATE}_${MONGO_DATABASE}.archive.gz"

mkdir -p "$MYSQL_BACKUP_DIR"
mkdir -p "$MONGO_BACKUP_DIR"

BACKUP_MYSQL=true
BACKUP_MONGO=true

echo "Starting containers..."
docker compose up -d

if [ "$BACKUP_MYSQL" = true ]; then
  echo "Waiting for MySQL..."
  until docker exec "$MYSQL_CONTAINER" mysqladmin ping \
    -h 127.0.0.1 \
    -uroot \
    -p"$MYSQL_ROOT_PASSWORD" \
    --silent; do
    sleep 2
  done
fi

if [ "$BACKUP_MONGO" = true ]; then
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

if [ "$BACKUP_MYSQL" = true ]; then
  echo "Creating MySQL logical backup..."
  docker exec "$MYSQL_CONTAINER" mysqldump \
    -uroot \
    -p"$MYSQL_ROOT_PASSWORD" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --databases "$MYSQL_DATABASE" \
    | gzip > "$MYSQL_DATA_BACKUP"
fi

if [ "$BACKUP_MONGO" = true ]; then
  echo "Creating MongoDB logical backup..."

  if docker exec "$MONGO_CONTAINER" sh -c "command -v mongodump >/dev/null 2>&1"; then
    docker exec "$MONGO_CONTAINER" mongodump \
      --host 127.0.0.1 \
      --port 27017 \
      -u "$MONGO_ROOT_USERNAME" \
      -p "$MONGO_ROOT_PASSWORD" \
      --authenticationDatabase admin \
      --db "$MONGO_DATABASE" \
      --archive \
      --gzip \
      > "$MONGO_DATA_BACKUP"
  else
    echo "mongodump not found inside MongoDB container."
    echo "Using temporary MongoDB database tools container..."

    docker run --rm \
      --network "container:${MONGO_CONTAINER}" \
      mongodb/mongodb-database-tools \
      mongodump \
        --host 127.0.0.1 \
        --port 27017 \
        -u "$MONGO_ROOT_USERNAME" \
        -p "$MONGO_ROOT_PASSWORD" \
        --authenticationDatabase admin \
        --db "$MONGO_DATABASE" \
        --archive \
        --gzip \
        > "$MONGO_DATA_BACKUP"
  fi
fi

if [ "$BACKUP_MYSQL" = true ]; then
  echo ""
  echo "Creating MySQL file-level backup..."
  docker compose stop mysql
  MYSQL_VOLUME=$(docker inspect "$MYSQL_CONTAINER" \
    --format '{{ range .Mounts }}{{ if eq .Destination "/var/lib/mysql" }}{{ .Name }}{{ end }}{{ end }}')
  MYSQL_FILES_BACKUP="${MYSQL_BACKUP_DIR}/${BACKUP_DATE}_${MYSQL_DATABASE}.files.tar.gz"
  docker run --rm \
    -v "${MYSQL_VOLUME}:/data:ro" \
    -v "$(pwd)/${MYSQL_BACKUP_DIR}:/backup" \
    alpine tar czf "/backup/${BACKUP_DATE}_${MYSQL_DATABASE}.files.tar.gz" -C /data .
  docker compose start mysql
fi

if [ "$BACKUP_MONGO" = true ]; then
  echo "Creating MongoDB file-level backup..."
  docker compose stop mongo
  MONGO_VOLUME=$(docker inspect "$MONGO_CONTAINER" \
    --format '{{ range .Mounts }}{{ if eq .Destination "/data/db" }}{{ .Name }}{{ end }}{{ end }}')
  MONGO_FILES_BACKUP="${MONGO_BACKUP_DIR}/${BACKUP_DATE}_${MONGO_DATABASE}.files.tar.gz"
  docker run --rm \
    -v "${MONGO_VOLUME}:/data:ro" \
    -v "$(pwd)/${MONGO_BACKUP_DIR}:/backup" \
    alpine tar czf "/backup/${BACKUP_DATE}_${MONGO_DATABASE}.files.tar.gz" -C /data .
  docker compose start mongo
fi

echo ""
echo "Backup completed successfully."

if [ "$BACKUP_MYSQL" = true ]; then
  echo ""
  echo "MySQL logical backup:"
  echo "  $MYSQL_DATA_BACKUP"
  echo ""
  echo "MySQL file-level backup:"
  echo "  $MYSQL_FILES_BACKUP"
fi

if [ "$BACKUP_MONGO" = true ]; then
  echo ""
  echo "MongoDB logical backup:"
  echo "  $MONGO_DATA_BACKUP"
  echo ""
  echo "MongoDB file-level backup:"
  echo "  $MONGO_FILES_BACKUP"
fi