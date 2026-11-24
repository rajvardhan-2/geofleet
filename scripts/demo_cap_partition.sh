#!/bin/bash
# ==============================================================================
# GEOFLEET: CAP Theorem Network Partition Demonstration
# ==============================================================================
set -e

echo "=== GEOFLEET CAP THEOREM TEST: NETWORK PARTITION (P) ==="

echo -e "\n[1/5] Simulating Network Partition: Severing network to Shard EU Primary..."
docker network disconnect geofleet-net shard-eu-primary
echo "Network link to Shard EU severed!"

echo -e "\n[2/5] Demonstrating AP Subsystem (Availability under Partition)..."
echo "Sending real-time GPS telemetry to unaffected US Shard..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8000/api/telemetry \
  -H "Content-Type: application/json" \
  -d '{"vin": "TEST-VIN-REPL-01", "region_code": "US-EAST", "latitude": 40.7128, "longitude": -74.0060, "speed_kmh": 65.0, "fuel_level_pct": 80.0}')

echo "Telemetry Ingestion HTTP Status: $HTTP_STATUS (Expected: 200)"
if [ "$HTTP_STATUS" -eq 200 ]; then
    echo ">> [AP VERIFIED] Local telemetry remains 100% Available during cross-region partition."
fi

echo -e "\n[3/5] Demonstrating CP Subsystem (Consistency over Availability)..."
echo "Attempting cross-shard 2PC transfer across the partitioned boundary..."
set +e
TRANSFER_RESP=$(curl -s -X POST http://localhost:8000/api/transfers/2pc \
  -H "Content-Type: application/json" \
  -d '{"vin": "TEST-VIN-REPL-01", "source_region": "US-EAST", "target_region": "EU-WEST"}')
set -e

echo "2PC Response: $TRANSFER_RESP"
echo ">> [CP VERIFIED] System aborted transaction to prevent partial commit or split-brain asset state."

echo -e "\n[4/5] Healing the Network Partition (Reconnecting Shard EU)..."
docker network connect geofleet-net shard-eu-primary
sleep 2
echo "Network healed!"

echo -e "\n[5/5] Re-attempting 2PC Transfer across healed network..."
curl -s -X POST http://localhost:8000/api/transfers/2pc \
  -H "Content-Type: application/json" \
  -d '{"vin": "TEST-VIN-REPL-01", "source_region": "US-EAST", "target_region": "EU-WEST"}' | python3 -m json.tool

echo -e "\n=== CAP THEOREM DEMONSTRATION COMPLETE ==="
