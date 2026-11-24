import uuid
import json
import time
from psycopg2.extras import execute_values
from app.db_router import DatabaseRouter

class TwoPhaseCommitCoordinator:
    """
    Two-Phase Commit (2PC) Transaction Coordinator.
    Supports Single-Vehicle and Batch Multi-Vehicle Atomic Transfers.
    Maintains a live audit log of recent transfers for the dashboard.
    """

    RECENT_TRANSFERS = []

    @staticmethod
    def transfer_vehicle(
        vin: str,
        source_region: str,
        target_region: str,
        simulate_crash_after_prepare: bool = False
    ):
        return TwoPhaseCommitCoordinator.batch_transfer(
            count=1,
            source_region=source_region,
            target_region=target_region,
            simulate_crash_after_prepare=simulate_crash_after_prepare,
            specific_vin=vin
        )

    @staticmethod
    def batch_transfer(
        count: int,
        source_region: str,
        target_region: str,
        simulate_crash_after_prepare: bool = False,
        specific_vin: str = None
    ):
        if source_region.upper() == target_region.upper():
            return {"status": "error", "message": "Source and target regions must differ"}

        tx_id = f"tx_{uuid.uuid4().hex[:8]}"
        gid_src = f"{tx_id}_src"
        gid_tgt = f"{tx_id}_tgt"

        conn_src = None
        conn_tgt = None
        prepared_src = False
        prepared_tgt = False

        try:
            # 1. Connect to both shard primaries in autocommit mode
            conn_src = DatabaseRouter.get_connection(source_region, read_only=False)
            conn_src.autocommit = True
            conn_tgt = DatabaseRouter.get_connection(target_region, read_only=False)
            conn_tgt.autocommit = True

            cur_src = conn_src.cursor()
            cur_tgt = conn_tgt.cursor()

            # Begin explicit transaction blocks
            cur_src.execute("BEGIN;")
            cur_tgt.execute("BEGIN;")

            # 2. Select and acquire exclusive row locks on vehicles
            if specific_vin:
                cur_src.execute("SELECT * FROM vehicles WHERE vin = %s FOR UPDATE;", (specific_vin,))
            else:
                cur_src.execute("""
                    SELECT * FROM vehicles 
                    WHERE status = 'ACTIVE' 
                    ORDER BY total_odometer_km ASC 
                    LIMIT %s FOR UPDATE;
                """, (count,))

            vehicles = cur_src.fetchall()
            if not vehicles:
                raise Exception(f"No active vehicles available to transfer in {source_region}")

            actual_count = len(vehicles)
            vehicle_ids = [v["vehicle_id"] for v in vehicles]
            vins = [v["vin"] for v in vehicles]

            # =================================================================
            # PHASE 1: PREPARE (Voting Phase)
            # =================================================================

            # Step 1A: On Source Shard, mark as TRANSFERRING
            cur_src.execute("""
                UPDATE vehicles 
                SET status = 'TRANSFERRING', updated_at = NOW() 
                WHERE vehicle_id = ANY(%s::uuid[]);
            """, (vehicle_ids,))

            cur_src.execute("""
                INSERT INTO cross_shard_transfers (vehicle_id, from_region, to_region, phase, tx_gid, vehicle_snapshot)
                VALUES (%s, %s, %s, 'PREPARED', %s, %s);
            """, (
                vehicles[0]["vehicle_id"],
                source_region,
                target_region,
                gid_src,
                json.dumps({"batch_size": actual_count, "vins": vins[:3]})
            ))

            # Step 1B: On Target Shard, insert all vehicles as ACTIVE
            target_records = [
                (
                    v["vehicle_id"],
                    v["vin"],
                    v["license_plate"],
                    target_region.upper(),
                    v["model"],
                    v["total_odometer_km"],
                    'ACTIVE'
                )
                for v in vehicles
            ]

            execute_values(
                cur_tgt,
                """
                INSERT INTO vehicles (vehicle_id, vin, license_plate, region_code, model, total_odometer_km, status)
                VALUES %s
                ON CONFLICT (vin) DO UPDATE SET 
                    status = 'ACTIVE', 
                    region_code = EXCLUDED.region_code,
                    total_odometer_km = EXCLUDED.total_odometer_km,
                    updated_at = NOW();
                """,
                target_records
            )

            cur_tgt.execute("""
                INSERT INTO cross_shard_transfers (vehicle_id, from_region, to_region, phase, tx_gid, vehicle_snapshot)
                VALUES (%s, %s, %s, 'PREPARED', %s, %s);
            """, (
                vehicles[0]["vehicle_id"],
                source_region,
                target_region,
                gid_tgt,
                json.dumps({"batch_size": actual_count, "vins": vins[:3]})
            ))

            # Step 1C: Both participants vote YES by preparing to WAL
            cur_src.execute(f"PREPARE TRANSACTION '{gid_src}';")
            prepared_src = True

            cur_tgt.execute(f"PREPARE TRANSACTION '{gid_tgt}';")
            prepared_tgt = True

            # Chaos Hook: In-Doubt
            if simulate_crash_after_prepare:
                conn_src.close()
                conn_tgt.close()
                return {
                    "status": "in-doubt",
                    "message": f"Simulated coordinator crash! Batch of {actual_count} vehicles prepared to WAL.",
                    "phase": "PREPARED",
                    "batch_size": actual_count,
                    "gid_src": gid_src,
                    "gid_tgt": gid_tgt
                }

            # =================================================================
            # PHASE 2: COMMIT (Decision Phase)
            # =================================================================
            cur_src.execute(f"COMMIT PREPARED '{gid_src}';")
            cur_tgt.execute(f"COMMIT PREPARED '{gid_tgt}';")

            # Mark decommissioned on source shard
            cur_src.execute("""
                UPDATE vehicles 
                SET status = 'DECOMMISSIONED', updated_at = NOW() 
                WHERE vehicle_id = ANY(%s::uuid[]);
            """, (vehicle_ids,))

            # Append to in-memory audit log for live dashboard streaming
            record = {
                "timestamp": time.strftime("%H:%M:%S"),
                "source": source_region.upper(),
                "target": target_region.upper(),
                "count": actual_count,
                "gid": gid_src,
                "status": "COMMITTED"
            }
            TwoPhaseCommitCoordinator.RECENT_TRANSFERS.append(record)
            if len(TwoPhaseCommitCoordinator.RECENT_TRANSFERS) > 15:
                TwoPhaseCommitCoordinator.RECENT_TRANSFERS.pop(0)

            return {
                "status": "committed",
                "message": f"Successfully transferred {actual_count} vehicles from {source_region} to {target_region}",
                "transferred_count": actual_count,
                "transaction_id": tx_id,
                "gid_src": gid_src,
                "gid_tgt": gid_tgt
            }

        except Exception as e:
            # Atomic Rollback Phase
            if conn_src:
                try:
                    if prepared_src:
                        cur_src.execute(f"ROLLBACK PREPARED '{gid_src}';")
                    else:
                        cur_src.execute("ROLLBACK;")
                except Exception:
                    pass

            if conn_tgt:
                try:
                    if prepared_tgt:
                        cur_tgt.execute(f"ROLLBACK PREPARED '{gid_tgt}';")
                    else:
                        cur_tgt.execute("ROLLBACK;")
                except Exception:
                    pass

            return {
                "status": "aborted",
                "error": str(e),
                "message": "Batch transfer rolled back atomically across all shards."
            }

        finally:
            if conn_src and not conn_src.closed:
                conn_src.close()
            if conn_tgt and not conn_tgt.closed:
                conn_tgt.close()

    @staticmethod
    def resolve_in_doubt(gid_src: str, gid_tgt: str, action: str = "commit"):
        results = {}
        action = action.upper()
        if action not in ("COMMIT", "ROLLBACK"):
            return {"status": "error", "message": "Action must be COMMIT or ROLLBACK"}

        try:
            conn_src = DatabaseRouter.get_connection("US-EAST", read_only=False)
            conn_src.autocommit = True
            cur_src = conn_src.cursor()
            cur_src.execute(f"{action} PREPARED '{gid_src}';")
            conn_src.close()
            results["shard_src"] = f"Successfully executed {action} PREPARED '{gid_src}'"
        except Exception as e:
            results["shard_src"] = f"Error: {str(e)}"

        try:
            conn_tgt = DatabaseRouter.get_connection("EU-WEST", read_only=False)
            conn_tgt.autocommit = True
            cur_tgt = conn_tgt.cursor()
            cur_tgt.execute(f"{action} PREPARED '{gid_tgt}';")
            conn_tgt.close()
            results["shard_tgt"] = f"Successfully executed {action} PREPARED '{gid_tgt}'"
        except Exception as e:
            results["shard_tgt"] = f"Error: {str(e)}"

        return {"status": "resolved", "action": action, "details": results}
