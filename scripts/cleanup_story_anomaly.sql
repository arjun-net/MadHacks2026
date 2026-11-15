-- OPTIONAL CLEANUP: Run in the Lakebase PostgreSQL editor only when done.
-- Matches only the two synthetic fixture buildings and device ID prefix.
DELETE FROM public.location_events
WHERE building IN ('__DEMO__ Story Lab', '__DEMO__ Normal Hall')
  AND device_id LIKE 'demo-story-20261114-%';
