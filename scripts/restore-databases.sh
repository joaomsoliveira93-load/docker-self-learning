#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

set -a
source .env
set +a

MYSQL_CONTAINER="dev-mysql"
MONGO_CONTAINER="dev-mongo"

MYSQL_BACKUP_DIR="backups/mysql"
MONGO_BACKUP_DIR="backups/mongo"

echo "What do you want to restore?"
echo "  1) MySQL only"
echo "  2) MongoDB only"
echo "  3) Both MySQL and MongoDB"
echo ""

read -rp "Choose an option [1/2/3]: " RESTORE_OPTION

case "$RESTORE_OPTION" in
  1)
    RESTORE_MYSQL=true
    RESTORE_MONGO=false
    RESTORE_LABEL="MySQL"
    ;;
  2)
    RESTORE_MYSQL=false
    RESTORE_MONGO=true
    RESTORE_LABEL="MongoDB"
    ;;
  3)
    RESTORE_MYSQL=true
    RESTORE_MONGO=true
    RESTORE_LABEL="MySQL and MongoDB"
    ;;
  *)
    echo "Invalid option: $RESTORE_OPTION"
    exit 1
    ;;
esac

echo ""
echo "Available backup dates:"
echo ""

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
fi | sort -u

echo ""
read -rp "Enter the backup date to restore, for example YYYY-MM-DD: " RESTORE_DATE

shopt -s nullglob

MYSQL_MATCHES=()
MONGO_MATCHES=()

if [ "$RESTORE_MYSQL" = true ]; then
  MYSQL_MATCHES=("$MYSQL_BACKUP_DIR"/"${RESTORE_DATE}"_"${MYSQL_DATABASE}".sql.gz)

  if [ "${#MYSQL_MATCHES[@]}" -eq 0 ]; then
    echo "No MySQL backup found for date: $RESTORE_DATE"
    exit 1
  fi

  if [ "${#MYSQL_MATCHES[@]}" -gt 1 ]; then
    echo "More than one MySQL backup found for date: $RESTORE_DATE"
    printf '  %s\n' "${MYSQL_MATCHES[@]}"
    exit 1
  fi

  MYSQL_BACKUP_FILE="${MYSQL_MATCHES[0]}"
fi

if [ "$RESTORE_MONGO" = true ]; then
  MONGO_MATCHES=("$MONGO_BACKUP_DIR"/"${RESTORE_DATE}"_"${MONGO_DATABASE}".archive.gz)

  if [ "${#MONGO_MATCHES[@]}" -eq 0 ]; then
    echo "No MongoDB backup found for date: $RESTORE_DATE"
    exit 1
  fi

  if [ "${#MONGO_MATCHES[@]}" -gt 1 ]; then
    echo "More than one MongoDB backup found for date: $RESTORE_DATE"
    printf '  %s\n' "${MONGO_MATCHES[@]}"
    exit 1
  fi

  MONGO_BACKUP_FILE="${MONGO_MATCHES[0]}"
fi

shopt -u nullglob

echo ""
echo "You are about to restore: $RESTORE_LABEL"

if [ "$RESTORE_MYSQL" = true ]; then
  echo "  MySQL:   $MYSQL_BACKUP_FILE"
fi

if [ "$RESTORE_MONGO" = true ]; then
  echo "  MongoDB: $MONGO_BACKUP_FILE"
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
  echo "Copying MySQL backup into container..."
  docker cp "$MYSQL_BACKUP_FILE" "$MYSQL_CONTAINER:/tmp/mysql-restore.sql.gz"

  echo "Restoring MySQL database..."
  docker exec \
    -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
    -i "$MYSQL_CONTAINER" \
    sh -c "gzip -dc /tmp/mysql-restore.sql.gz | mysql -uroot"

  docker exec "$MYSQL_CONTAINER" rm -f /tmp/mysql-restore.sql.gz

  echo "MySQL restore completed."
fi

if [ "$RESTORE_MONGO" = true ]; then
  echo ""
  echo "Restoring MongoDB database..."

  if docker exec "$MONGO_CONTAINER" sh -c "command -v mongorestore >/dev/null 2>&1"; then
    echo "Copying MongoDB backup into container..."
    docker cp "$MONGO_BACKUP_FILE" "$MONGO_CONTAINER:/tmp/mongo-restore.archive.gz"

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

    MONGO_BACKUP_FILENAME="$(basename "$MONGO_BACKUP_FILE")"

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
        --archive="/backup/${MONGO_BACKUP_FILENAME}" \
        --gzip \
        --drop
  fi

  echo "MongoDB restore completed."
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