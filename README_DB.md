# Location Events Database

This repository uses **Databricks Lakebase Postgres** to store timestamped geographic observations from multiple devices. This document describes the **database interface only**: how authorized contributors connect, insert records, and query existing records. It does not require a custom API or Python application.

> **Security:** This is a public-repository guide. It intentionally contains **no actual hostnames, usernames, passwords, tokens, or other credentials**. Obtain access details privately from a database administrator. Never commit secrets to the repository.

## Table schema

The database table is `public.location_events`.

| Column | PostgreSQL type | Description |
| --- | --- | --- |
| `id` | `BIGINT` | Automatically generated primary key. Do not set this when inserting. |
| `device_id` | `TEXT` | Nonempty identifier for the reporting device. |
| `latitude` | `DOUBLE PRECISION` | Latitude in decimal degrees, from -90 to 90. |
| `longitude` | `DOUBLE PRECISION` | Longitude in decimal degrees, from -180 to 180. |
| `time` | `TIMESTAMPTZ` | Time of the observation; defaults to the database's current timestamp when omitted. |

**Conventions**

- Use decimal degrees for coordinates, with **negative latitude** south of the equator and **negative longitude** west of Greenwich.
- Supply timestamps as ISO 8601 values with an explicit time zone, preferably UTC (`Z`), such as `2026-11-14T21:00:00Z`.
- Use a stable `device_id` for each device, such as `device_001`. Device IDs identify devices; they are **not** authentication credentials.
- Records are append-only in the examples below: multiple observations from the same device are expected.
- SQL examples quote `"time"` to unambiguously refer to the column.

## Connection requirements

You need an authorized PostgreSQL role and the following connection settings. Request the actual values privately from a project maintainer.

| Setting | Placeholder / value |
| --- | --- |
| PostgreSQL host | `<POSTGRES_HOST>` |
| Port | `5432` |
| Database | `<DATABASE_NAME>` |
| Username / role | `<POSTGRES_USER>` |
| Password | `<POSTGRES_PASSWORD>` (provided privately) |
| SSL/TLS | `sslmode=require` |

**Authentication:** Prefer a **native PostgreSQL password role** for long-lived integrations. Unlike Lakebase OAuth tokens, which expire after approximately one hour, native PostgreSQL passwords do not automatically expire. Passwords may still be changed or revoked, and clients must handle disconnections and reconnects. A Databricks `dapi...` personal access token is **not** a native PostgreSQL password.

### Connect using `psql`

Install the PostgreSQL command-line client (`psql`, version 14 or later). Replace the placeholders below with your own **non-secret** connection settings, then enter your PostgreSQL password when prompted:

```bash
psql "host=<POSTGRES_HOST> port=5432 dbname=<DATABASE_NAME> user=<POSTGRES_USER> sslmode=require"
```

Once connected, confirm the current database and user:

```sql
SELECT current_database(), current_user;
```

You can also connect with any PostgreSQL-compatible client such as pgAdmin or DBeaver using the same connection settings. Use TLS/SSL for every connection.

## Insert observations

### Insert one observation using the database timestamp

```sql
INSERT INTO public.location_events (device_id, latitude, longitude)
VALUES ('device_001', 43.0731, -89.4012)
RETURNING id, device_id, latitude, longitude, "time";
```

### Insert one observation with a specific timestamp

```sql
INSERT INTO public.location_events (device_id, latitude, longitude, "time")
VALUES ('device_001', 43.0731, -89.4012, '2026-11-14T21:00:00Z')
RETURNING id, "time";
```

### Insert multiple observations

```sql
INSERT INTO public.location_events (device_id, latitude, longitude, "time")
VALUES
    ('device_001', 43.0731, -89.4012, '2026-11-14T21:00:00Z'),
    ('device_001', 43.0735, -89.4018, '2026-11-14T21:01:00Z'),
    ('device_002', 43.0750, -89.4030, '2026-11-14T21:02:00Z');
```

If an external client supplies values programmatically, use **parameterized queries** provided by its PostgreSQL driver rather than interpolating device IDs or other values into SQL strings.

## Query observations

### Recent observations

```sql
SELECT id, device_id, latitude, longitude, "time"
FROM public.location_events
ORDER BY "time" DESC, id DESC
LIMIT 100;
```

### Observations from one device

```sql
SELECT id, device_id, latitude, longitude, "time"
FROM public.location_events
WHERE device_id = 'device_001'
ORDER BY "time" DESC, id DESC
LIMIT 100;
```

### Observations in a time range

This example includes the start time and excludes the end time.

```sql
SELECT id, device_id, latitude, longitude, "time"
FROM public.location_events
WHERE device_id = 'device_001'
  AND "time" >= '2026-11-14T21:00:00Z'
  AND "time" <  '2026-11-15T21:00:00Z'
ORDER BY "time" ASC, id ASC;
```

### Latest known observation for a device

```sql
SELECT id, device_id, latitude, longitude, "time"
FROM public.location_events
WHERE device_id = 'device_001'
ORDER BY "time" DESC, id DESC
LIMIT 1;
```

### Latest known observation for every device

```sql
SELECT DISTINCT ON (device_id)
    id, device_id, latitude, longitude, "time"
FROM public.location_events
ORDER BY device_id, "time" DESC, id DESC;
```

### Observations within geographic bounds

```sql
SELECT id, device_id, latitude, longitude, "time"
FROM public.location_events
WHERE latitude BETWEEN 43.0 AND 43.2
  AND longitude BETWEEN -89.5 AND -89.3
ORDER BY "time" DESC, id DESC;
```

This bounding-box example assumes the longitude range does **not** cross the ±180° meridian. More complex geospatial queries may require a different indexing strategy or spatial extension.

## Access permissions (database administrators only)

Create PostgreSQL roles through the Lakebase console and grant each role only the access it needs. For an existing role allowed to **read and insert** but not update or delete, the database owner can grant:

```sql
-- Replace the role name before executing this administrator-only example.
GRANT CONNECT ON DATABASE databricks_postgres TO location_writer;
GRANT USAGE ON SCHEMA public TO location_writer;
GRANT SELECT, INSERT ON TABLE public.location_events TO location_writer;
```

If your database has a different name, replace `databricks_postgres`. These commands **grant privileges**; they do not create the `location_writer` role or its password. Consider distinct read-only and writer roles for different consumers.

Do not put the owner role's credentials, native PostgreSQL passwords, Databricks tokens, or complete credential-bearing connection URLs in this repository, issues, screenshots, or logs. Use a secret manager or a locally ignored configuration file. **Never embed a shared database password in public browser code or distributable device firmware**; direct database credentials should be used only by trusted clients in controlled environments.

## Troubleshooting

| Error | Check |
| --- | --- |
| Authentication failed | Confirm the PostgreSQL role and its password (not a Databricks PAT). |
| Could not connect / timeout | Confirm the endpoint host, port `5432`, network rules, and that the compute endpoint is available. |
| SSL error | Set `sslmode=require`. |
| `relation "public.location_events" does not exist` | Verify the database and that the table has been created. |
| `permission denied` | Ask an administrator to review the role's database, schema, and table grants. |
| Time appears offset | Supply time-zone-aware timestamps and convert output to UTC in your client when needed. |

## Official references

- [Databricks Lakebase: Connect with psql](https://docs.databricks.com/aws/en/oltp/projects/connect-psql)
- [Databricks Lakebase: Connection strings](https://docs.databricks.com/aws/en/oltp/projects/connection-strings)
- [Databricks Lakebase: Authentication](https://docs.databricks.com/aws/en/oltp/projects/authentication)
- [Databricks Lakebase: Database permissions](https://docs.databricks.com/aws/en/oltp/projects/manage-roles-permissions)

> **Scope:** This document describes the assumed existing table and SQL interface; it does not deploy or create the database. Request schema changes or credentials through the project's maintainers.
