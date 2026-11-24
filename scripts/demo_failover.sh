#!/bin/bash
# ==============================================================================
# GEOFLEET: Fault Tolerance & Controlled Failover Demonstration
# ==============================================================================
set -e

echo "=== GEOFLEET CHAOS TEST: PRIMARY CRASH & STANDBY PROMOTION ==="

echo -e "\n[1/4] Checking initial status of Shard US..."
docker exec shard-us-primary psql -U postgres -d geofleet -c "SELECT 'PRIMARY (5431)' as node, pg_is_in_recovery() as in_recovery;"
docker exec shard-us-replica psql -U postgres -d geofleet -c "SELECT 'REPLICA (5435)' as node, pg_is_in_recovery() as in_recovery;"

echo -e "\n[2/4] Simulating hard crash of Primary node (docker stop shard-us-primary)..."
docker stop shard-us-primary

echo -e "\n[3/4] Promoting Standby Replica to new Primary..."
docker exec shard-us-replica pg_ctl promote -D /var/lib/postgresql/data
sleep 2

echo -e "\n[4/4] Verifying Promoted Standby is now accepting Read-Write traffic..."
docker exec shard-us-replica psql -U postgres -d geofleet -c "
INSERT INTO vehicles (vin, license_plate, region_code, model, status)
VALUES ('FAILOVER-VIN-01', 'FAIL-01', 'US-EAST', 'Failover Verified Semi', 'ACTIVE');
SELECT vin, license_plate, status, pg_is_in_recovery() as in_recovery FROM vehicles WHERE vin = 'FAILOVER-VIN-01';
"

echo -e "\n=== FAULT TOLERANCE DEMONSTRATION SUCCESSFUL ==="
echo "Standby took over write workload with zero split-brain!"
