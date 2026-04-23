-- =============================================================
-- PGCIS Asset Registry - Supabase Schema
-- Run this once in the Supabase SQL Editor for your project
-- =============================================================

-- Main asset registry
CREATE TABLE IF NOT EXISTS public.asset_equipment (
    id              BIGSERIAL PRIMARY KEY,
    asset_id        TEXT UNIQUE NOT NULL
                        CHECK (asset_id ~ '^PGCIS-[0-9]{4}$'),  -- format enforced at DB level

    -- Identity
    asset_type      TEXT NOT NULL,                  -- Laptop, IR Camera, PQM, etc.
    category        TEXT,                           -- IT, test-equipment, tools, other
    make            TEXT,
    model           TEXT,
    serial_number   TEXT,
    description     TEXT,

    -- Purchase info
    purchase_date   DATE,
    purchase_price  NUMERIC(10,2),
    vendor          TEXT,

    -- Status
    condition       TEXT CHECK (condition IN ('new','good','fair','poor','damaged','retired')) DEFAULT 'good',

    -- Assignment
    assigned_to     TEXT,
    assigned_date   DATE,
    home_location   TEXT,

    -- Checkout tracking (for shared / field equipment)
    checkout_status TEXT CHECK (checkout_status IN ('available','checked-out','in-field','in-repair')) DEFAULT 'available',
    checked_out_to  TEXT,
    checkout_date   TIMESTAMPTZ,
    expected_return DATE,
    checkout_site   TEXT,
    last_checkout_notes TEXT,

    -- Last seen (updated on any scan)
    last_seen_location  TEXT,
    last_seen_date      TIMESTAMPTZ,
    last_seen_by        TEXT,

    -- Calibration (test equipment only)
    calibration_required    BOOLEAN DEFAULT FALSE,
    last_calibration_date   DATE,
    next_calibration_date   DATE,
    calibration_provider    TEXT,

    -- Meta
    notes       TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW(),
    created_by  TEXT,       -- set from JWT by trigger; not trusted from client
    updated_by  TEXT        -- set from JWT by trigger on every UPDATE
);

-- Apply asset_id format constraint on tables that already exist
-- (safe to run multiple times — drops and re-adds)
ALTER TABLE public.asset_equipment
    DROP CONSTRAINT IF EXISTS chk_asset_id_format;
ALTER TABLE public.asset_equipment
    ADD CONSTRAINT chk_asset_id_format
    CHECK (asset_id ~ '^PGCIS-[0-9]{4}$');

-- Text field length constraints — prevent runaway storage from any authenticated user.
-- These limits are generous for legitimate use; tighten if needed.
ALTER TABLE public.asset_equipment
    DROP CONSTRAINT IF EXISTS chk_make_len,
    DROP CONSTRAINT IF EXISTS chk_model_len,
    DROP CONSTRAINT IF EXISTS chk_serial_len,
    DROP CONSTRAINT IF EXISTS chk_desc_len,
    DROP CONSTRAINT IF EXISTS chk_vendor_len,
    DROP CONSTRAINT IF EXISTS chk_notes_len,
    DROP CONSTRAINT IF EXISTS chk_assigned_to_len,
    DROP CONSTRAINT IF EXISTS chk_checkout_site_len,
    DROP CONSTRAINT IF EXISTS chk_checked_out_to_len,
    DROP CONSTRAINT IF EXISTS chk_home_location_len,
    DROP CONSTRAINT IF EXISTS chk_cal_provider_len;

ALTER TABLE public.asset_equipment
    ADD CONSTRAINT chk_make_len          CHECK (char_length(make)              <= 100),
    ADD CONSTRAINT chk_model_len         CHECK (char_length(model)             <= 200),
    ADD CONSTRAINT chk_serial_len        CHECK (char_length(serial_number)     <= 100),
    ADD CONSTRAINT chk_desc_len          CHECK (char_length(description)       <= 500),
    ADD CONSTRAINT chk_vendor_len        CHECK (char_length(vendor)            <= 200),
    ADD CONSTRAINT chk_notes_len         CHECK (char_length(notes)             <= 5000),
    ADD CONSTRAINT chk_assigned_to_len   CHECK (char_length(assigned_to)       <= 200),
    ADD CONSTRAINT chk_home_location_len CHECK (char_length(home_location)     <= 200),
    ADD CONSTRAINT chk_checkout_site_len CHECK (char_length(checkout_site)     <= 200),
    ADD CONSTRAINT chk_checked_out_to_len CHECK (char_length(checked_out_to)   <= 200),
    ADD CONSTRAINT chk_cal_provider_len  CHECK (char_length(calibration_provider) <= 200);

-- Checkout history log
CREATE TABLE IF NOT EXISTS public.asset_checkout_log (
    id                  BIGSERIAL PRIMARY KEY,
    asset_id            TEXT REFERENCES public.asset_equipment(asset_id) ON DELETE CASCADE,
    checked_out_to      TEXT NOT NULL,          -- display name entered by user
    performed_by_email  TEXT,                   -- authenticated user's email (JWT-sourced from app)
    checkout_date       TIMESTAMPTZ NOT NULL,
    return_date         TIMESTAMPTZ,
    returned_by_email   TEXT,                   -- authenticated user's email on check-in
    checkout_site       TEXT,
    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Add JWT-backed email columns to existing deployments (safe to re-run)
ALTER TABLE public.asset_checkout_log
    ADD COLUMN IF NOT EXISTS performed_by_email TEXT,
    ADD COLUMN IF NOT EXISTS returned_by_email  TEXT;

-- ---------------------------------------------------------------
-- Auto-update updated_at and updated_by on every UPDATE.
-- updated_by is set from the JWT email so it cannot be forged
-- by the client. Falls back to 'unknown' for service-role ops.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_asset_updated_at()
RETURNS TRIGGER AS $$
DECLARE
    jwt_email TEXT;
BEGIN
    NEW.updated_at = NOW();
    jwt_email := auth.jwt() ->> 'email';
    IF jwt_email IS NOT NULL AND jwt_email != '' THEN
        NEW.updated_by := lower(jwt_email);
    ELSE
        NEW.updated_by := 'unknown';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_asset_equipment_updated_at ON public.asset_equipment;
CREATE TRIGGER trg_asset_equipment_updated_at
    BEFORE UPDATE ON public.asset_equipment
    FOR EACH ROW EXECUTE FUNCTION update_asset_updated_at();

-- Migrate existing rows: backfill updated_by from created_by as a best approximation.
-- Safe to run on a fresh deployment (updates 0 rows). On an existing deployment,
-- sets updated_by = created_by for rows that predate the trigger.
ALTER TABLE public.asset_equipment
    ADD COLUMN IF NOT EXISTS updated_by TEXT;
UPDATE public.asset_equipment
    SET updated_by = created_by
    WHERE updated_by IS NULL;

-- ---------------------------------------------------------------
-- Enforce created_by from JWT on INSERT
-- The client sends a value but this trigger overwrites it with the
-- authenticated user's email so the field cannot be forged.
-- Falls back to the client value only if auth.jwt() returns no email
-- (e.g. service-role operations), then to 'unknown'.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_created_by_from_jwt()
RETURNS TRIGGER AS $$
DECLARE
    jwt_email TEXT;
BEGIN
    jwt_email := auth.jwt() ->> 'email';
    IF jwt_email IS NOT NULL AND jwt_email != '' THEN
        NEW.created_by := lower(jwt_email);
    ELSIF NEW.created_by IS NULL OR NEW.created_by = '' THEN
        NEW.created_by := 'unknown';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_created_by ON public.asset_equipment;
CREATE TRIGGER trg_set_created_by
    BEFORE INSERT ON public.asset_equipment
    FOR EACH ROW EXECUTE FUNCTION set_created_by_from_jwt();

-- ---------------------------------------------------------------
-- Hardware identity lock
-- Once asset_type, make, and model are set on registration, they
-- cannot be changed by non-admins. Enforces the physical-tag-to-
-- hardware binding at the DB level, independent of the UI.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION lock_hardware_identity()
RETURNS TRIGGER AS $$
DECLARE
    caller_email TEXT;
BEGIN
    -- Admins (Tyler, Benton, Erik) can correct hardware identity fields.
    -- Keep this list in sync with ADMIN_EMAILS in index.html.
    caller_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    IF caller_email = ANY(ARRAY[
        'tylerd@pgcis.com',
        'benton@pgcis.com',
        'erik@pgcis.com'
    ]) THEN
        RETURN NEW;  -- Admin bypass: allow any field change
    END IF;

    -- Non-admins: hardware identity fields are locked once set
    IF OLD.asset_type IS NOT NULL AND NEW.asset_type IS DISTINCT FROM OLD.asset_type THEN
        RAISE EXCEPTION 'asset_type is locked: tag % is permanently bound to this hardware type. Contact an admin to correct a registration error.', OLD.asset_id;
    END IF;
    IF OLD.make IS NOT NULL AND NEW.make IS DISTINCT FROM OLD.make THEN
        RAISE EXCEPTION 'make is locked: tag % is permanently bound to this equipment. Contact an admin to correct a registration error.', OLD.asset_id;
    END IF;
    IF OLD.model IS NOT NULL AND NEW.model IS DISTINCT FROM OLD.model THEN
        RAISE EXCEPTION 'model is locked: tag % is permanently bound to this equipment. Contact an admin to correct a registration error.', OLD.asset_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_lock_hardware_identity ON public.asset_equipment;
CREATE TRIGGER trg_lock_hardware_identity
    BEFORE UPDATE ON public.asset_equipment
    FOR EACH ROW EXECUTE FUNCTION lock_hardware_identity();

-- ---------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_asset_equipment_asset_id        ON public.asset_equipment(asset_id);
CREATE INDEX IF NOT EXISTS idx_asset_equipment_checkout_status ON public.asset_equipment(checkout_status);
CREATE INDEX IF NOT EXISTS idx_asset_equipment_assigned_to     ON public.asset_equipment(assigned_to);
CREATE INDEX IF NOT EXISTS idx_asset_checkout_log_asset_id     ON public.asset_checkout_log(asset_id);

-- ---------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------
ALTER TABLE public.asset_equipment    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asset_checkout_log ENABLE ROW LEVEL SECURITY;

-- Drop existing policies so this file is fully re-runnable.
-- Supabase's CREATE POLICY does not support IF NOT EXISTS, so on a second
-- run without these drops the CREATE POLICY statements below would error.
-- Safe no-op on a fresh project (policies don't exist yet).
DROP POLICY IF EXISTS "PGCIS read asset_equipment"          ON public.asset_equipment;
DROP POLICY IF EXISTS "PGCIS write asset_equipment insert"  ON public.asset_equipment;
DROP POLICY IF EXISTS "PGCIS write asset_equipment update"  ON public.asset_equipment;
DROP POLICY IF EXISTS "PGCIS read asset_checkout_log"       ON public.asset_checkout_log;
DROP POLICY IF EXISTS "PGCIS write asset_checkout_log insert" ON public.asset_checkout_log;
DROP POLICY IF EXISTS "PGCIS write asset_checkout_log update" ON public.asset_checkout_log;

-- All reads require an authenticated @pgcis.com account.
-- The lost/found screen does NOT read from the database (it shows
-- only hardcoded contact constants), so no public read is needed.
-- Removing the public SELECT policy prevents unauthenticated API
-- enumeration of asset records, employee names, and serial numbers.
CREATE POLICY "PGCIS read asset_equipment"
    ON public.asset_equipment FOR SELECT
    USING (
        auth.role() = 'authenticated' AND
        (auth.jwt() ->> 'email') LIKE '%@pgcis.com'
    );

CREATE POLICY "PGCIS read asset_checkout_log"
    ON public.asset_checkout_log FOR SELECT
    USING (
        auth.role() = 'authenticated' AND
        (auth.jwt() ->> 'email') LIKE '%@pgcis.com'
    );

-- Write access: authenticated @pgcis.com accounts only.
CREATE POLICY "PGCIS write asset_equipment insert"
    ON public.asset_equipment FOR INSERT
    WITH CHECK (
        auth.role() = 'authenticated' AND
        (auth.jwt() ->> 'email') LIKE '%@pgcis.com'
    );

CREATE POLICY "PGCIS write asset_equipment update"
    ON public.asset_equipment FOR UPDATE
    USING (
        auth.role() = 'authenticated' AND
        (auth.jwt() ->> 'email') LIKE '%@pgcis.com'
    )
    WITH CHECK (
        auth.role() = 'authenticated' AND
        (auth.jwt() ->> 'email') LIKE '%@pgcis.com'
    );

CREATE POLICY "PGCIS write asset_checkout_log insert"
    ON public.asset_checkout_log FOR INSERT
    WITH CHECK (
        auth.role() = 'authenticated' AND
        (auth.jwt() ->> 'email') LIKE '%@pgcis.com'
    );

CREATE POLICY "PGCIS write asset_checkout_log update"
    ON public.asset_checkout_log FOR UPDATE
    USING (
        auth.role() = 'authenticated' AND
        (auth.jwt() ->> 'email') LIKE '%@pgcis.com'
    )
    WITH CHECK (
        auth.role() = 'authenticated' AND
        (auth.jwt() ->> 'email') LIKE '%@pgcis.com'
    );

-- NOTE: No DELETE policy is defined intentionally.
-- Supabase RLS denies any operation without a matching ALLOW policy.
-- Assets must never be deleted — use condition='retired' instead.
-- The ON DELETE CASCADE on asset_checkout_log exists only to handle
-- accidental direct DB deletions via the Supabase dashboard (admin action).

-- ---------------------------------------------------------------
-- Convenience views
-- ---------------------------------------------------------------

-- All equipment currently checked out.
-- security_invoker = true: view runs as the querying role (not view owner),
-- so RLS policies on asset_equipment apply and anon reads are blocked.
CREATE OR REPLACE VIEW public.asset_checked_out
WITH (security_invoker = true)
AS
SELECT
    asset_id, asset_type, make, model, serial_number,
    checked_out_to, checkout_date, expected_return, checkout_site
FROM public.asset_equipment
WHERE checkout_status IN ('checked-out', 'in-field')
ORDER BY checkout_date;

-- Test equipment with calibration due within 30 days (or overdue).
-- security_invoker = true: same RLS enforcement as above.
CREATE OR REPLACE VIEW public.asset_calibration_due
WITH (security_invoker = true)
AS
SELECT
    asset_id, asset_type, make, model,
    next_calibration_date, calibration_provider, assigned_to
FROM public.asset_equipment
WHERE calibration_required = TRUE
  AND (next_calibration_date IS NULL
       OR next_calibration_date <= CURRENT_DATE + INTERVAL '30 days')
ORDER BY next_calibration_date NULLS FIRST;
