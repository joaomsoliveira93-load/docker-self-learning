#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ ! -f ".env" ]; then
  echo "Missing .env file"
  exit 1
fi

set -a
source .env
set +a

MYSQL_CONTAINER="dev-mysql"
MONGO_CONTAINER="dev-mongo"

MYSQL_RESTORE_FILE="scripts/initial_data/mysql.initial.sql"
MONGO_RESTORE_FILE="scripts/initial_data/mongo.initial.js"

echo "Starting MySQL and MongoDB containers..."
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

echo "Creating MySQL database and user..."
docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;

CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';

GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "Creating MongoDB database and user..."
docker exec -i "$MONGO_CONTAINER" mongosh \
  -u "$MONGO_ROOT_USERNAME" \
  -p "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin <<JS
db = db.getSiblingDB("${MONGO_DATABASE}");

if (!db.getUser("${MONGO_USER}")) {
  db.createUser({
    user: "${MONGO_USER}",
    pwd: "${MONGO_PASSWORD}",
    roles: [
      { role: "readWrite", db: "${MONGO_DATABASE}" }
    ]
  });
} else {
  db.updateUser("${MONGO_USER}", {
    pwd: "${MONGO_PASSWORD}",
    roles: [
      { role: "readWrite", db: "${MONGO_DATABASE}" }
    ]
  });
}

if (!db.getCollectionNames().includes("users")) {
  db.createCollection("users");
}
JS

echo "Checking restore files..."

if [ ! -f "$MYSQL_RESTORE_FILE" ]; then
  echo "Missing MySQL restore file:"
  echo "  $MYSQL_RESTORE_FILE"
  exit 1
fi

if [ ! -f "$MONGO_RESTORE_FILE" ]; then
  echo "Missing MongoDB restore file:"
  echo "  $MONGO_RESTORE_FILE"
  exit 1
fi

echo "Copying MySQL restore file into container..."
docker cp "$MYSQL_RESTORE_FILE" "$MYSQL_CONTAINER:/tmp/mysql.initial.sql"

echo "Restoring MySQL users table..."
docker exec \
  -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
  -i "$MYSQL_CONTAINER" \
  sh -c 'mysql -uroot "$1" < /tmp/mysql.initial.sql' sh "$MYSQL_DATABASE"

docker exec "$MYSQL_CONTAINER" rm -f /tmp/mysql.initial.sql

echo "Copying MongoDB restore file into container..."
docker cp "$MONGO_RESTORE_FILE" "$MONGO_CONTAINER:/tmp/mongo.initial.js"

echo "Restoring MongoDB users collection..."
docker exec -i "$MONGO_CONTAINER" mongosh \
  --host 127.0.0.1 \
  --port 27017 \
  -u "$MONGO_ROOT_USERNAME" \
  -p "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  "$MONGO_DATABASE" \
  /tmp/mongo.initial.js

docker exec "$MONGO_CONTAINER" rm -f /tmp/mongo.initial.js

echo ""
echo "Setup completed successfully."
echo ""
echo "MySQL:"
echo "  Host: localhost"
echo "  Port: 3306"
echo "  Database: $MYSQL_DATABASE"
echo "  User: $MYSQL_USER"
echo "  Table: users"

echo ""
echo "MongoDB:"
echo "  Host: localhost"
echo "  Port: 27017"
echo "  Database: $MONGO_DATABASE"
echo "  User: $MONGO_USER"
echo "  Collection: users"