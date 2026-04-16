-- =============================================================
-- PGCIS Asset Registry - Supabase Schema
-- Run this once in the Supabase SQL Editor for your project
-- =============================================================

-- Main asset registry
CREATE TABLE IF NOT EXISTS public.asset_equipment (
    id              BIGSERIAL PRIMARY KEY,
    asset_id        TEXT UNIQUE NOT NULL,           -- e.g. PGCIS-0001

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
    created_by  TEXT
);

-- Checkout history log
CREATE TABLE IF NOT EXISTS public.asset_checkout_log (
    id              BIGSERIAL PRIMARY KEY,
    asset_id        TEXT REFERENCES public.asset_equipment(asset_id) ON DELETE CASCADE,
    checked_out_to  TEXT NOT NULL,
    checkout_date   TIMESTAMPTZ NOT NULL,
    return_date     TIMESTAMPTZ,
    checkout_site   TEXT,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Auto-update updated_at on asset_equipment
CREATE OR REPLACE FUNCTION update_asset_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_asset_equipment_updated_at ON public.asset_equipment;
CREATE TRIGGER trg_asset_equipment_updated_at
    BEFORE UPDATE ON public.asset_equipment
    FOR EACH ROW EXECUTE FUNCTION update_asset_updated_at();

-- Hardware identity lock
-- Once asset_type, make, and model are set on registration, they cannot be
-- changed. This enforces the physical-tag-to-hardware binding at the DB level.
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

-- Indexes
CREATE INDEX IF NOT EXISTS idx_asset_equipment_asset_id        ON public.asset_equipment(asset_id);
CREATE INDEX IF NOT EXISTS idx_asset_equipment_checkout_status ON public.asset_equipment(checkout_status);
CREATE INDEX IF NOT EXISTS idx_asset_equipment_assigned_to     ON public.asset_equipment(assigned_to);
CREATE INDEX IF NOT EXISTS idx_asset_checkout_log_asset_id     ON public.asset_checkout_log(asset_id);

-- Row Level Security
ALTER TABLE public.asset_equipment ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asset_checkout_log ENABLE ROW LEVEL SECURITY;

-- Public read - anyone who scans a QR code can view asset details
CREATE POLICY "Public read asset_equipment"
    ON public.asset_equipment FOR SELECT USING (true);

CREATE POLICY "Public read asset_checkout_log"
    ON public.asset_checkout_log FOR SELECT USING (true);

-- Write access requires an authenticated @pgcis.com Google account.
-- The web app enforces this via Supabase Google OAuth before any form is shown.
-- The DB policy is a second line of defence against direct API calls.
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
    );

-- ---------------------------------------------------------------
-- Convenience views
-- ---------------------------------------------------------------

-- All equipment currently checked out
CREATE OR REPLACE VIEW public.asset_checked_out AS
SELECT
    asset_id, asset_type, make, model, serial_number,
    checked_out_to, checkout_date, expected_return, checkout_site
FROM public.asset_equipment
WHERE checkout_status IN ('checked-out', 'in-field')
ORDER BY checkout_date;

-- Test equipment with calibration due within 30 days (or overdue)
CREATE OR REPLACE VIEW public.asset_calibration_due AS
SELECT
    asset_id, asset_type, make, model,
    next_calibration_date, calibration_provider, assigned_to
FROM public.asset_equipment
WHERE calibration_required = TRUE
  AND (next_calibration_date IS NULL
       OR next_calibration_date <= CURRENT_DATE + INTERVAL '30 days')
ORDER BY next_calibration_date NULLS FIRST;
