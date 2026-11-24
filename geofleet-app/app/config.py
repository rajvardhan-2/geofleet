import os

class DBConfig:
    # Shard 1: US-East
    HOST_US_PRIMARY = os.getenv("HOST_US_PRIMARY", "shard-us-primary")
    PORT_US_PRIMARY = int(os.getenv("PORT_US_PRIMARY", "5432"))

    HOST_US_REPLICA = os.getenv("HOST_US_REPLICA", "shard-us-replica")
    PORT_US_REPLICA = int(os.getenv("PORT_US_REPLICA", "5432"))

    # Shard 2: EU-West
    HOST_EU_PRIMARY = os.getenv("HOST_EU_PRIMARY", "shard-eu-primary")
    PORT_EU_PRIMARY = int(os.getenv("PORT_EU_PRIMARY", "5432"))

    HOST_EU_REPLICA = os.getenv("HOST_EU_REPLICA", "shard-eu-replica")
    PORT_EU_REPLICA = int(os.getenv("PORT_EU_REPLICA", "5432"))

    # Credentials
    USER = os.getenv("DB_USER", "postgres")
    PASSWORD = os.getenv("DB_PASSWORD", "rootpassword")
    DB_NAME = os.getenv("DB_NAME", "geofleet")

def get_connection_string(host: str, port: int) -> str:
    return (
        f"host={host} "
        f"port={port} "
        f"dbname={DBConfig.DB_NAME} "
        f"user={DBConfig.USER} "
        f"password={DBConfig.PASSWORD} "
        f"connect_timeout=3"
    )
