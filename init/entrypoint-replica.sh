#!/bin/sh
set -e

echo "=== GeoFleet Standby Bootstrap Starting ==="
echo "Target Primary Host: $PRIMARY_HOST"

# 1. Wait until primary is healthy and ready to accept connections
until pg_isready -h "$PRIMARY_HOST" -p 5432 -U postgres; do
  echo "Waiting for Primary ($PRIMARY_HOST) to be ready..."
  sleep 2
done

echo "Primary is ready. Cloning data directory via pg_basebackup..."

# 2. Clear data directory and pull base backup with streaming replication flag (-R)
rm -rf "$PGDATA"/*
export PGPASSWORD=replicapass
pg_basebackup -h "$PRIMARY_HOST" -p 5432 -U replicator -D "$PGDATA" -Fp -Xs -P -R

chmod 0700 "$PGDATA"

echo "=== Base backup complete. Starting PostgreSQL Standby in Hot Standby mode ==="
exec docker-entrypoint.sh postgres -c max_prepared_transactions=50 -c hot_standby=on
