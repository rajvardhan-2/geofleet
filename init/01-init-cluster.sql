-- ============================================================================
-- GEOFLEET: DISTRIBUTED DATABASE INITIALIZATION SCRIPT
-- Executed on each shard primary during first container startup.
-- ============================================================================

-- 1. Create dedicated physical streaming replication user
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH REPLICATION LOGIN ENCRYPTED PASSWORD 'replicapass';
    END IF;
END
$$;

-- 2. Enable UUID generation extension
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 3. REGIONAL DEPOTS TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS depots (
    depot_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    region_code     VARCHAR(20) NOT NULL,            -- e.g. 'US-EAST', 'EU-WEST'
    name            VARCHAR(100) NOT NULL,
    latitude        NUMERIC(9, 6) NOT NULL,
    longitude       NUMERIC(9, 6) NOT NULL,
    capacity        INTEGER NOT NULL DEFAULT 50,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_depots_region ON depots(region_code);

-- ============================================================================
-- 4. VEHICLES TABLE (Asset Registry)
-- ============================================================================
CREATE TABLE IF NOT EXISTS vehicles (
    vehicle_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vin                 VARCHAR(17) UNIQUE NOT NULL,
    license_plate       VARCHAR(15) NOT NULL,
    region_code         VARCHAR(20) NOT NULL,
    current_depot_id    UUID REFERENCES depots(depot_id) ON DELETE SET NULL,
    status              VARCHAR(25) NOT NULL DEFAULT 'ACTIVE' 
                        CHECK (status IN ('ACTIVE', 'IN_TRANSIT', 'MAINTENANCE', 'TRANSFERRING', 'DECOMMISSIONED')),
    model               VARCHAR(50) NOT NULL,
    total_odometer_km   NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    last_ping_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_vehicles_region ON vehicles(region_code);
CREATE INDEX IF NOT EXISTS idx_vehicles_status ON vehicles(status);
CREATE INDEX IF NOT EXISTS idx_vehicles_vin ON vehicles(vin);

-- ============================================================================
-- 5. TELEMETRY LOGS (Partitioned Time-Series)
-- ============================================================================
CREATE TABLE IF NOT EXISTS telemetry_logs (
    telemetry_id    UUID DEFAULT gen_random_uuid(),
    vehicle_id      UUID NOT NULL REFERENCES vehicles(vehicle_id) ON DELETE CASCADE,
    recorded_at     TIMESTAMPTZ NOT NULL,
    latitude        NUMERIC(9, 6) NOT NULL,
    longitude       NUMERIC(9, 6) NOT NULL,
    speed_kmh       NUMERIC(5, 2) NOT NULL DEFAULT 0.00,
    fuel_level_pct  NUMERIC(4, 1) NOT NULL CHECK (fuel_level_pct BETWEEN 0 AND 100),
    heading_deg     NUMERIC(5, 2) DEFAULT 0.00,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (telemetry_id, recorded_at)
) PARTITION BY RANGE (recorded_at);

-- Default demonstration partition
CREATE TABLE IF NOT EXISTS telemetry_logs_default PARTITION OF telemetry_logs DEFAULT;

CREATE INDEX IF NOT EXISTS idx_telemetry_vehicle_time ON telemetry_logs (vehicle_id, recorded_at DESC);

-- ============================================================================
-- 6. CROSS-SHARD TRANSFERS (2-Phase Commit State & Audit Table)
-- ============================================================================
CREATE TABLE IF NOT EXISTS cross_shard_transfers (
    transfer_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vehicle_id          UUID NOT NULL,
    from_region         VARCHAR(20) NOT NULL,
    to_region           VARCHAR(20) NOT NULL,
    phase               VARCHAR(20) NOT NULL 
                        CHECK (phase IN ('INITIATED', 'PREPARED', 'COMMITTED', 'ABORTED')),
    tx_gid              VARCHAR(128) NOT NULL,
    vehicle_snapshot    JSONB NOT NULL,
    initiated_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    resolved_at         TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_transfers_gid ON cross_shard_transfers(tx_gid);
CREATE INDEX IF NOT EXISTS idx_transfers_phase ON cross_shard_transfers(phase);

-- ============================================================================
-- 7. SHARD HEALTH AUDIT
-- ============================================================================
CREATE TABLE IF NOT EXISTS shard_heartbeats (
    node_name           VARCHAR(50) PRIMARY KEY,
    is_primary          BOOLEAN NOT NULL,
    last_heartbeat      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- 8. INITIAL SEED DATA
-- ============================================================================
-- Seed Depots
INSERT INTO depots (region_code, name, latitude, longitude, capacity) VALUES
('US-EAST', 'New York Central Hub', 40.712800, -74.006000, 100),
('US-EAST', 'Philadelphia Regional Depot', 39.952600, -75.165200, 60),
('EU-WEST', 'Frankfurt Logistics Center', 50.110900, 8.682100, 120),
('EU-WEST', 'Paris North Hub', 48.856600, 2.352200, 80)
ON CONFLICT DO NOTHING;

-- Seed 500 Sample Vehicles for US-East Shard
INSERT INTO vehicles (vin, license_plate, region_code, model, status, total_odometer_km)
SELECT 
    'US-VIN-' || LPAD(i::text, 4, '0'),
    'US-TRK-' || LPAD(i::text, 4, '0'),
    'US-EAST',
    CASE (i % 4)
        WHEN 0 THEN 'Freightliner Cascadia'
        WHEN 1 THEN 'Volvo VNL 860'
        WHEN 2 THEN 'Peterbilt 579'
        ELSE 'Kenworth T680'
    END,
    'ACTIVE',
    ROUND((10000 + (i * 12.5))::numeric, 2)
FROM generate_series(1, 500) AS i
ON CONFLICT (vin) DO NOTHING;

-- Seed 500 Sample Vehicles for EU-West Shard
INSERT INTO vehicles (vin, license_plate, region_code, model, status, total_odometer_km)
SELECT 
    'EU-VIN-' || LPAD(i::text, 4, '0'),
    'EU-TRK-' || LPAD(i::text, 4, '0'),
    'EU-WEST',
    CASE (i % 4)
        WHEN 0 THEN 'Scania R500'
        WHEN 1 THEN 'MAN TGX'
        WHEN 2 THEN 'Mercedes Actros'
        ELSE 'Volvo FH16'
    END,
    'ACTIVE',
    ROUND((15000 + (i * 15.2))::numeric, 2)
FROM generate_series(1, 500) AS i
ON CONFLICT (vin) DO NOTHING;
