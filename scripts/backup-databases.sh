#!/usr/bin/env bash
set -euo pipefail

set -a
source .env
set +a

MYSQL_CONTAINER="dev-mysql"
MONGO_CONTAINER="dev-mongo"

BACKUP_DATE="$(date +"%Y-%m-%d")"

MYSQL_BACKUP_DIR="backups/mysql"
MONGO_BACKUP_DIR="backups/mongo"

MYSQL_BACKUP_FILE="${MYSQL_BACKUP_DIR}/${BACKUP_DATE}_${MYSQL_DATABASE}.sql.gz"
MONGO_BACKUP_FILE="${MONGO_BACKUP_DIR}/${BACKUP_DATE}_${MONGO_DATABASE}.archive.gz"

mkdir -p "$MYSQL_BACKUP_DIR"
mkdir -p "$MONGO_BACKUP_DIR"

echo "Starting containers..."
docker compose up -d

echo "Waiting for MySQL..."
until docker exec "$MYSQL_CONTAINER" mysqladmin ping \
  -h 127.0.0.1 \
  -uroot \
  -p"$MYSQL_ROOT_PASSWORD" \
  --silent; do
  sleep 2
done

echo "Waiting for MongoDB..."
until docker exec "$MONGO_CONTAINER" mongosh \
  --quiet \
  -u "$MONGO_ROOT_USERNAME" \
  -p "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  --eval "db.adminCommand('ping').ok" >/dev/null; do
  sleep 2
done

echo "Creating MySQL backup..."
docker exec "$MYSQL_CONTAINER" mysqldump \
  -uroot \
  -p"$MYSQL_ROOT_PASSWORD" \
  --single-transaction \
  --routines \
  --triggers \
  --events \
  --databases "$MYSQL_DATABASE" \
  | gzip > "$MYSQL_BACKUP_FILE"

echo "Creating MongoDB backup..."

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
    > "$MONGO_BACKUP_FILE"
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
      > "$MONGO_BACKUP_FILE"
fi

echo ""
echo "Backup completed successfully."
echo ""
echo "MySQL backup:"
echo "  $MYSQL_BACKUP_FILE"
echo ""
echo "MongoDB backup:"
echo "  $MONGO_BACKUP_FILE"