import psycopg2
from psycopg2.extras import RealDictCursor
from app.config import DBConfig, get_connection_string

class DatabaseRouter:
    """
    Intelligent Data Router:
    1. Horizontal Geographic Sharding: Routes requests based on region_code.
    2. Read/Write Connection Splitting:
       - Writes route to regional Primary (ports 5431 / 5433).
       - Reads route to regional Read Standby (ports 5435 / 5434).
    """

    @staticmethod
    def get_connection(region: str, read_only: bool = False):
        region = region.upper().strip()

        if region in ("US-EAST", "US", "AMERICAS"):
            target_region = "US-EAST"
            host = DBConfig.HOST_US_REPLICA if read_only else DBConfig.HOST_US_PRIMARY
            port = DBConfig.PORT_US_REPLICA if read_only else DBConfig.PORT_US_PRIMARY
        elif region in ("EU-WEST", "EU", "EUROPE"):
            target_region = "EU-WEST"
            host = DBConfig.HOST_EU_REPLICA if read_only else DBConfig.HOST_EU_PRIMARY
            port = DBConfig.PORT_EU_REPLICA if read_only else DBConfig.PORT_EU_PRIMARY
        else:
            raise ValueError(f"Unknown geographic shard region: '{region}'")

        try:
            conn = psycopg2.connect(
                get_connection_string(host, port),
                cursor_factory=RealDictCursor
            )
            conn.autocommit = False
            return conn
        except psycopg2.OperationalError as e:
            # If the primary failed and standby was promoted, attempt connection to standby for write fallback
            if not read_only:
                fallback_host = DBConfig.HOST_US_REPLICA if target_region == "US-EAST" else DBConfig.HOST_EU_REPLICA
                fallback_port = DBConfig.PORT_US_REPLICA if target_region == "US-EAST" else DBConfig.PORT_EU_REPLICA
                try:
                    conn = psycopg2.connect(
                        get_connection_string(fallback_host, fallback_port),
                        cursor_factory=RealDictCursor
                    )
                    # Check if promoted
                    cur = conn.cursor()
                    cur.execute("SELECT pg_is_in_recovery();")
                    in_recovery = cur.fetchone()["pg_is_in_recovery"]
                    conn.rollback()

                    if not in_recovery:
                        conn.autocommit = False
                        return conn
                except Exception:
                    pass
            raise e
