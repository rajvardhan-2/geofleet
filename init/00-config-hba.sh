#!/bin/sh
set -e
echo "Configuring pg_hba.conf for replication..."
echo "host replication all all trust" >> "$PGDATA/pg_hba.conf"
echo "host all all all trust" >> "$PGDATA/pg_hba.conf"
