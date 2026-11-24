#!/bin/bash
# ==============================================================================
# GEOFLEET: Full Failure & Recovery Lifecycle Demonstration
# 1. Primary crashes
# 2. Standby is promoted to New Primary (Stage 1)
# 3. Old Primary restarts and re-joins as New Standby (Stage 2)
# ==============================================================================
set -e

echo "======================================================================"
echo "      GEOFLEET CHAOS TEST: FULL PRIMARY CRASH & RECOVERY CYCLE        "
echo "======================================================================"

echo -e "\n[STEP 1] Checking current cluster roles..."
docker exec shard-us-primary psql -U postgres -d geofleet -c "SELECT 'OLD_PRIMARY (5431)' as role, pg_is_in_recovery() as in_recovery;"
docker exec shard-us-replica psql -U postgres -d geofleet -c "SELECT 'STANDBY (5435)' as role, pg_is_in_recovery() as in_recovery;"

echo -e "\n[STEP 2] Simulating hard crash of Primary (docker stop shard-us-primary)..."
docker stop shard-us-primary

echo -e "\n[STEP 3] Promoting Standby to become the NEW PRIMARY..."
docker exec shard-us-replica pg_ctl promote -D /var/lib/postgresql/data
sleep 2

echo -e "\n[STEP 4] Ingesting write into Promoted Primary to advance Timeline..."
docker exec shard-us-replica psql -U postgres -d geofleet -c "
INSERT INTO vehicles (vin, license_plate, region_code, model, status)
VALUES ('RESURRECT-01', 'NEW-PRIM-01', 'US-EAST', 'Timeline 2 Semi', 'ACTIVE');
SELECT vin, license_plate, status, pg_is_in_recovery() as in_recovery FROM vehicles WHERE vin = 'RESURRECT-01';
"

echo -e "\n[STEP 5] Resurrecting Old Primary and re-joining it as a STANDBY of the new primary..."
# Reconfigure old primary data dir to clone from shard-us-replica
docker start shard-us-primary
sleep 2

docker exec shard-us-primary sh -c '
  rm -rf /var/lib/postgresql/data/*
  PGPASSWORD=replicapass pg_basebackup -h shard-us-replica -p 5432 -U replicator -D /var/lib/postgresql/data -Fp -Xs -P -R
  chmod 0700 /var/lib/postgresql/data
  su-exec postgres pg_ctl -D /var/lib/postgresql/data start
'
sleep 3

echo -e "\n[STEP 6] Verifying role reversal and restored replication..."
docker exec shard-us-replica psql -U postgres -d geofleet -c "
SELECT 'PROMOTED_PRIMARY (5435)' as node, client_addr, state, sync_state 
FROM pg_stat_replication;
"
docker exec shard-us-primary psql -U postgres -d geofleet -c "
SELECT 'RESURRECTED_STANDBY (5431)' as node, pg_is_in_recovery() as in_recovery;
SELECT vin, license_plate, status FROM vehicles WHERE vin = 'RESURRECT-01';
"

echo -e "\n======================================================================"
echo "    FULL RECOVERY COMPLETE: Old Primary is now safely replicating!    "
echo "======================================================================"
