#!/bin/bash
# ==============================================================================
# GEOFLEET: Sever Network to Shard EU (Indefinite Network Partition)
# ==============================================================================
set -e

echo "========================================================================"
echo "          [CAP THEOREM TEST] SEVERING NETWORK TO SHARD EU               "
echo "========================================================================"

docker network disconnect geofleet-net shard-eu-primary 2>/dev/null || true

echo -e "\n>> [PARTITION ACTIVE] Shard EU Primary is now isolated from the network!"
echo ">> The network will remain partitioned INDEFINITELY until you run:"
echo "   ./scripts/partition_heal.sh"
echo ""
echo "WHAT TO SHOW YOUR PROFESSOR RIGHT NOW:"
echo "1. Open http://localhost:8000/dashboard"
echo "   • Watch Shard US continue ingesting pings (AP Verified!)"
echo "   • Shard EU will show OFFLINE or replication stopped"
echo ""
echo "2. Test AP Subsystem (Send US GPS Ping -> Expected 200 OK):"
echo "   curl -s -X POST http://localhost:8000/api/telemetry \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"vin\":\"US-VIN-0001\",\"region_code\":\"US-EAST\",\"latitude\":40.71,\"longitude\":-74.00,\"speed_kmh\":65,\"fuel_level_pct\":80}'"
echo ""
echo "3. Test CP Subsystem (Attempt Cross-Shard Transfer -> Expected 503 Aborted):"
echo "   curl -s -X POST http://localhost:8000/api/transfers/batch-2pc \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"count\":10,\"source_region\":\"US-EAST\",\"target_region\":\"EU-WEST\"}' | python3 -m json.tool"
echo "========================================================================"
