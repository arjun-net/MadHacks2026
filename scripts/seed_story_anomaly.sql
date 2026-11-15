-- OPTIONAL LIVE DATABRICKS DEMO SEED.
-- Execute in the LAKEBASE POSTGRESQL editor (NOT a Databricks SQL warehouse).
-- Writes only synthetic rows to public.location_events so the existing
-- Databricks story endpoint can read them through its Lakebase catalog.
-- Safe to rerun: each fixture device ID is inserted only if absent.
-- Requires the `building` column on public.location_events.
--
-- Both examples are Saturday Nov 14, 2026 at 14:30 America/Chicago:
--   __DEMO__ Story Lab:   42 devices vs Saturday avg 14 (+200%), week avg 20 (+110%).
--   __DEMO__ Normal Hall: 14 devices vs Saturday avg 14 (0%), week avg 14 (0%).
-- These are counts of synthetic reporting devices, NOT building occupancy.

WITH sample_days(local_day, spike_count) AS (
    VALUES
        (DATE '2026-10-17', 14),
        (DATE '2026-10-24', 14),
        (DATE '2026-10-31', 16),
        (DATE '2026-11-07', 12),
        (DATE '2026-11-09', 20),
        (DATE '2026-11-10', 20),
        (DATE '2026-11-11', 20),
        (DATE '2026-11-12', 20),
        (DATE '2026-11-13', 20),
        (DATE '2026-11-14', 42)
), scenarios(variant, building) AS (
    VALUES
        ('spike', '__DEMO__ Story Lab'),
        ('normal', '__DEMO__ Normal Hall')
), demo_days AS (
    SELECT d.local_day, s.variant, s.building,
           CASE WHEN s.variant = 'normal' THEN 14 ELSE d.spike_count END AS device_count
    FROM sample_days AS d CROSS JOIN scenarios AS s
)
INSERT INTO public.location_events (
    device_id, latitude, longitude, "time", building
)
SELECT
    'demo-story-20261114-' || d.variant || '-' ||
      to_char(d.local_day, 'YYYYMMDD') || '-' || g.num,
    43.0731,
    -89.4012,
    (d.local_day + TIME '14:30:00') AT TIME ZONE 'America/Chicago',
    d.building
FROM demo_days AS d
CROSS JOIN LATERAL generate_series(1, d.device_count) AS g(num)
WHERE NOT EXISTS (
    SELECT 1
    FROM public.location_events AS e
    WHERE e.device_id =
        'demo-story-20261114-' || d.variant || '-' ||
        to_char(d.local_day, 'YYYYMMDD') || '-' || g.num
      AND e.building = d.building
);

-- Optional verification after seeding:
SELECT building,
       ("time" AT TIME ZONE 'America/Chicago')::date AS campus_date,
       COUNT(DISTINCT device_id) AS reporting_devices
FROM public.location_events
WHERE building IN ('__DEMO__ Story Lab', '__DEMO__ Normal Hall')
  AND device_id LIKE 'demo-story-20261114-%'
GROUP BY 1, 2
ORDER BY 1, 2;
