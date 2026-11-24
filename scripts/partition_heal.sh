#!/bin/bash
# ==============================================================================
# GEOFLEET: Restore Network Link to Shard EU (Heal Network Partition)
# ==============================================================================
set -e

echo "========================================================================"
echo "          [CAP THEOREM TEST] HEALING NETWORK PARTITION                  "
echo "========================================================================"

docker network connect geofleet-net shard-eu-primary 2>/dev/null || true
sleep 1

echo -e "\n>> [PARTITION HEALED] Shard EU Primary is reconnected to the network!"
echo ">> Autonomous 2PC transfers and telemetry will resume automatically."
echo ""
echo "VERIFICATION:"
echo "1. Check the Dashboard (http://localhost:8000/dashboard):"
echo "   • Shard EU status will return to PRIMARY ONLINE"
echo "   • Autonomous 2PC transfers will resume scrolling in the feed"
echo ""
echo "2. Re-test Cross-Shard Transfer (Now returns 200 COMMITTED):"
echo "   curl -s -X POST http://localhost:8000/api/transfers/batch-2pc \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"count\":10,\"source_region\":\"US-EAST\",\"target_region\":\"EU-WEST\"}' | python3 -m json.tool"
echo "========================================================================"
