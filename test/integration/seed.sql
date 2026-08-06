CREATE TABLE orgs (id bigserial PRIMARY KEY, name varchar(255) NOT NULL);
CREATE TABLE events (
  id bigserial, org_id bigint NOT NULL REFERENCES orgs(id),
  payload jsonb, day date NOT NULL,
  total bigint GENERATED ALWAYS AS (id * 2) STORED,
  seq int GENERATED ALWAYS AS IDENTITY,
  inserted_at timestamp DEFAULT clock_timestamp(),
  PRIMARY KEY (id, day)
) PARTITION BY RANGE (day);
CREATE TABLE events_p2026 PARTITION OF events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE INDEX events_p2026_partial ON events_p2026 (org_id) WHERE payload IS NOT NULL;
-- date::text (date_out) is STABLE, not IMMUTABLE (locale-dependent
-- formatting), so it cannot back an expression index; payload::text
-- (jsonb_out) is IMMUTABLE.
CREATE INDEX events_p2026_expr ON events_p2026 ((lower(payload::text)));
ALTER TABLE orgs ADD CONSTRAINT orgs_name_nn CHECK (name IS NOT NULL);
CREATE TABLE schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp);
INSERT INTO orgs (name) SELECT 'org-' || g FROM generate_series(1, 100) g;
INSERT INTO schema_migrations (version) VALUES (20250101000000);
ANALYZE;
-- flip an index invalid the honest way a failed CIC leaves it
UPDATE pg_index SET indisvalid = false
WHERE indexrelid = 'events_p2026_partial'::regclass;
