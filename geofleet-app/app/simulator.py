import threading
import time
import random
from psycopg2.extras import execute_values
from app.db_router import DatabaseRouter
from app.coordinator_2pc import TwoPhaseCommitCoordinator

class FleetTelemetrySimulator:
    """
    High-Throughput Fleet Telemetry Simulator & Autonomous 2PC Engine.
    1. Continuously streams GPS telemetry for 1,000 vehicles across both shards.
    2. Automatically triggers random 2PC cross-shard vehicle transfers every few seconds
       to demonstrate dynamic workload re-balancing and asset conservation invariants.
    """

    def __init__(self):
        self.running = False
        self.thread = None
        self.pings_generated = 0
        self.pings_per_sec = 0

    def start(self):
        if not self.running:
            self.running = True
            self.thread = threading.Thread(target=self._run_loop, daemon=True)
            self.thread.start()
            print("[Simulator] Autonomous 1,000 Vehicle Simulator & Random 2PC Engine STARTED")

    def stop(self):
        self.running = False
        print("[Simulator] Simulator STOPPED")

    def _run_loop(self):
        last_transfer_time = time.time()
        transfer_cooldown = random.uniform(5.0, 8.0)

        while self.running:
            cycle_start = time.time()
            cycle_pings = 0

            # -------------------------------------------------------------
            # 1. CONTINUOUS GPS TELEMETRY INGESTION (AP Subsystem)
            # -------------------------------------------------------------
            for region in ["US-EAST", "EU-WEST"]:
                try:
                    conn_read = DatabaseRouter.get_connection(region, read_only=True)
                    cur_read = conn_read.cursor()
                    cur_read.execute("SELECT vehicle_id FROM vehicles WHERE status = 'ACTIVE';")
                    active_vehicles = cur_read.fetchall()
                    conn_read.close()

                    if active_vehicles:
                        base_lat = 40.7128 if region == "US-EAST" else 50.1109
                        base_lon = -74.0060 if region == "US-EAST" else 8.6821

                        records = []
                        for v in active_vehicles:
                            lat = round(base_lat + random.uniform(-0.25, 0.25), 6)
                            lon = round(base_lon + random.uniform(-0.25, 0.25), 6)
                            speed = round(random.uniform(40.0, 115.0), 2)
                            fuel = round(random.uniform(25.0, 99.0), 1)
                            heading = round(random.uniform(0.0, 360.0), 2)
                            records.append((v["vehicle_id"], lat, lon, speed, fuel, heading))

                        conn_write = DatabaseRouter.get_connection(region, read_only=False)
                        conn_write.autocommit = True
                        cur_write = conn_write.cursor()

                        execute_values(
                            cur_write,
                            """
                            INSERT INTO telemetry_logs 
                            (vehicle_id, recorded_at, latitude, longitude, speed_kmh, fuel_level_pct, heading_deg)
                            VALUES %s;
                            """,
                            records,
                            template="(%s, NOW(), %s, %s, %s, %s, %s)"
                        )

                        conn_write.close()
                        cycle_pings += len(records)
                        self.pings_generated += len(records)

                except Exception as err:
                    print(f"[Simulator] Transient telemetry note on {region}: {err}")

            elapsed = max(time.time() - cycle_start, 0.001)
            self.pings_per_sec = int(cycle_pings / elapsed)

            # -------------------------------------------------------------
            # 2. AUTOMATIC RANDOM 2PC TRANSFERS (CP Subsystem)
            # -------------------------------------------------------------
            now = time.time()
            if now - last_transfer_time >= transfer_cooldown:
                try:
                    # Randomly choose transfer direction
                    direction = random.choice([("US-EAST", "EU-WEST"), ("EU-WEST", "US-EAST")])
                    src, tgt = direction
                    batch_size = random.randint(5, 15)

                    res = TwoPhaseCommitCoordinator.batch_transfer(
                        count=batch_size,
                        source_region=src,
                        target_region=tgt
                    )
                    if res.get("status") == "committed":
                        print(f"[Auto-2PC] Successfully transferred {res['transferred_count']} trucks from {src} to {tgt} atomically.")
                except Exception as e:
                    print(f"[Auto-2PC] Transfer note: {e}")

                last_transfer_time = time.time()
                transfer_cooldown = random.uniform(5.0, 8.0)

            time.sleep(2.0)
