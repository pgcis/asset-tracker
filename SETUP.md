**Created:** 2026-04-16 14:00
**Updated:** 2026-04-16 15:00
**Created By:** tylerd

# PGCIS Asset Tracker - Setup Guide

#asset-management #internal-tools

## What This Is

A QR code-based asset tracking system for PGCIS equipment (laptops, IR cameras, PQMs, tools, etc.).

**How it works:**
1. Each piece of equipment gets a durable physical label with a QR code
2. The QR code links to `https://pgcis.github.io/asset-tracker/?id=PGCIS-XXXX`
3. Scanning the code either shows the asset's info (if registered) or opens a registration form (if new)
4. Anyone can check equipment in/out by scanning the tag

---

## One-Time Setup (~45 minutes)

### Step 0 - Enable Google OAuth in Supabase

This is needed for the auth gate (PGCIS-only access + lost/found screen).

**In Google Cloud Console** (console.cloud.google.com):
1. Create or select a project
2. Go to APIs & Services > Credentials > Create Credentials > OAuth 2.0 Client ID
3. Application type: Web application
4. Name: "PGCIS Asset Tracker"
5. Under Authorized redirect URIs, add your Supabase callback URL:
   `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback`
6. Save — copy the **Client ID** and **Client Secret**

**In Supabase** (app.supabase.com > your project):
1. Authentication > Providers > Google > Enable
2. Paste in the Client ID and Client Secret from above
3. Authentication > URL Configuration > add these to Site URL / Redirect URLs:
   - `https://pgcis.github.io/asset-tracker/`
   - `https://pgcis.github.io/asset-tracker` (no trailing slash)
4. Save

**In index.html** — update the contact info constants in the config block:
```js
const CONTACT_PHONE   = '(512) 000-0000';   // your real number
const CONTACT_EMAIL   = 'info@pgcis.com';
const CONTACT_ADDRESS = 'Austin, TX';        // return address shown to finders
```

### Step 1 - Run the Supabase schema

1. Go to your Supabase project > SQL Editor
2. Paste in `schema.sql` and run it
3. Verify two tables were created: `asset_equipment` and `asset_checkout_log`

### Step 2 - Create the GitHub repo

```bash
# Create pgcis/asset-tracker repo on GitHub, then:
git clone https://github.com/pgcis/asset-tracker.git
cp index.html asset-tracker/
cd asset-tracker
git add index.html
git commit -m "initial: PGCIS asset tracker web app"
git push
```

Then enable GitHub Pages in the repo settings:
- Settings > Pages > Source: Deploy from branch `main`, folder `/root`
- Your URL will be: `https://pgcis.github.io/asset-tracker/`

### Step 3 - Add your Supabase credentials to index.html

Open `index.html` and fill in the config block at the top of the `<script>`:

```js
const SUPABASE_URL      = 'https://YOUR_PROJECT_REF.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR_ANON_KEY_HERE';
```

Get these from: Supabase project > Settings > API

The anon key is safe to expose in a public web app - Supabase RLS policies control access.

### Step 4 - Test it

1. Visit `https://pgcis.github.io/asset-tracker/?id=PGCIS-TEST`
2. You should see the registration form with "PGCIS-TEST" pre-filled
3. Fill it out and submit - then revisit the URL to confirm the asset appears

---

## Generating QR Code Label Sheets

### Install dependencies (Python 3.9+)

```bash
pip install -r requirements.txt
```

### Generate a batch of labels

```bash
# Generate a PDF sheet of labels PGCIS-0001 through PGCIS-0050
python generate_qr.py --start 1 --end 50

# Generate specific IDs only
python generate_qr.py --list PGCIS-0001,PGCIS-0005,PGCIS-0012

# Generate individual PNG files instead of a PDF sheet
python generate_qr.py --start 1 --end 10 --format png --output qr_pngs
```

The default PDF output is formatted for **Avery 5160** labels (30-up, 2.625" x 1").

---

## Physical Labels - Recommended Materials

### Option A - DIY with label printer (best quality)
| Item | Use Case |
|------|----------|
| Brady M611 printer + M21-750-595-WT labels | Office equipment, IT gear |
| Brady M611 + M21-750-499 (polyester) | Field/outdoor equipment |
| Brady B-595 polyester + B30-499-175 | Harsh environments, heat |

These Brady labels are UV-resistant, waterproof, and hold up in the field. The M611 is ~$300 but worth it if you're doing 100+ labels.

### Option B - Online printing service (easiest to start)
1. Generate QR PNGs using `python generate_qr.py --format png`
2. Upload to **StickerMule** (stickerapp.com) or **Avery Design & Print**
3. Order on weatherproof vinyl or polyester stock
4. Minimum recommended size: **1.5" x 0.75"** (QR code needs to be at least 0.6" square to scan reliably)

### Option C - Avery sheet labels (cheapest)
1. Generate the PDF sheet with default settings (Avery 5160 layout)
2. Print on **Avery 6521** (weatherproof inkjet labels, 2.625" x 1")
3. Laminate with clear film for field durability
4. These are not truly permanent - use for office equipment only

### For tamper-evident tags (computers/high-value gear)
- **Avery 60520 Destructible labels** - tear apart when removed, shows tampering
- Or use **Metalcraft TAMP-R-PROOF** labels from a label vendor

---

## Asset ID Format

`PGCIS-XXXX` — four-digit zero-padded number

Examples: `PGCIS-0001`, `PGCIS-0042`, `PGCIS-0100`

Range supports 10,000 unique assets (0001-9999).

---

## Viewing Your Data in Supabase

Supabase has a built-in Table Editor that works as a spreadsheet view.
Go to: Supabase project > Table Editor > `asset_equipment`

Two useful built-in views (created by the schema):
- `asset_checked_out` — all equipment currently checked out
- `asset_calibration_due` — test equipment with calibration due in <30 days

You can also export any view as CSV from the Table Editor.

---

## Fields Tracked

| Field | Description |
|-------|-------------|
| `asset_id` | Unique ID, e.g. PGCIS-0001 |
| `asset_type` | Laptop, PQM, IR Camera, etc. |
| `make` / `model` | Brand and model |
| `serial_number` | Manufacturer serial |
| `description` | Free-text notes at registration |
| `purchase_date` | When purchased |
| `purchase_price` | Cost |
| `vendor` | Where it was bought |
| `condition` | new / good / fair / poor / damaged / retired |
| `assigned_to` | Person it belongs to |
| `home_location` | Where it normally lives |
| `checkout_status` | available / checked-out / in-field / in-repair |
| `checked_out_to` | Who has it right now |
| `checkout_date` | When they took it |
| `expected_return` | When it should be back |
| `checkout_site` | Which project/site it went to |
| `last_seen_*` | Auto-updated on every QR scan |
| `calibration_required` | True for test equipment |
| `next_calibration_date` | Calibration due date |
| `notes` | Any additional info |

Checkout history (every checkout/checkin event) is stored in `asset_checkout_log`.

---

## Managing Admins

Admins can edit the locked hardware identity fields (Type, Make, Model) — everyone else sees them as read-only.

> **IMPORTANT — two files must always be updated together.**
> The admin list exists in `index.html` (controls the UI) and `schema.sql` (controls the database).
> If you update only one, they fall out of sync: the UI may show editable fields but the DB will reject the save, or the DB will allow a change that the UI never offered. Always update both at the same time.

### Adding or removing an admin

**1. `index.html` — config block near the top of the `<script>` tag:**

```js
const ADMIN_EMAILS = [
    'tylerd@pgcis.com',
    'benton@pgcis.com',
    'erik@pgcis.com',
    // 'newperson@pgcis.com',   ← add here
];
```

**2. `schema.sql` — inside the `lock_hardware_identity()` trigger function:**

```sql
IF caller_email = ANY(ARRAY[
    'tylerd@pgcis.com',
    'benton@pgcis.com',
    'erik@pgcis.com'
    -- 'newperson@pgcis.com'   ← add here
]) THEN
```

After editing `schema.sql`, re-run that function block in the Supabase SQL Editor to apply the change:

```sql
-- Re-run just the function + trigger block (lines starting with
-- "CREATE OR REPLACE FUNCTION lock_hardware_identity" through the
-- matching "CREATE TRIGGER trg_lock_hardware_identity" line).
```

After editing `index.html`, push the updated file to GitHub — Pages deploys automatically within ~60 seconds.

### What admins can do that regular users cannot

| Action | Regular user | Admin |
|--------|-------------|-------|
| View asset details | Yes | Yes |
| Check in / out | Yes | Yes |
| Transfer checkout | Yes | Yes |
| Reassign / unassign | Yes | Yes |
| Update serial number, condition, notes | Yes | Yes |
| Edit Type, Make, Model | No | Yes |

The DB trigger enforces the hardware lock independently of the UI — even a direct Supabase API call from a non-admin email will be rejected with a clear error message.
