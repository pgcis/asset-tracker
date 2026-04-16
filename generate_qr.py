#!/usr/bin/env python3
"""
PGCIS Asset QR Code Generator
Generates printable QR code label sheets for PGCIS asset tags.

Usage:
    python generate_qr.py --start 1 --end 50
    python generate_qr.py --start 1 --end 10 --format png
    python generate_qr.py --list PGCIS-0001,PGCIS-0005,PGCIS-0012

Dependencies:
    pip install -r requirements.txt
"""

import argparse
import io
import os
import sys

try:
    import qrcode
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Missing dependencies. Run: pip install -r requirements.txt")
    sys.exit(1)

# ----------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------
BASE_URL = "https://pgcis.github.io/asset-tracker/"
PREFIX   = "PGCIS"

# Label dimensions for Avery 5160 (30-up, 2.625" x 1")
# Change to match whatever label stock you're using.
LABEL_W_IN  = 2.625
LABEL_H_IN  = 1.0
LABEL_COLS  = 3
LABEL_ROWS  = 10

# Page margins (inches)
MARGIN_LEFT = 0.19
MARGIN_TOP  = 0.50

# Gap between labels (inches)
GAP_H = 0.125
GAP_V = 0.0

# Print DPI
DPI = 300
# ----------------------------------------------------------------


def to_px(inches):
    return int(inches * DPI)


def asset_url(asset_id):
    return f"{BASE_URL}?id={asset_id}"


def make_qr(url):
    """Return a QR code PIL image with high error correction."""
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=8,
        border=2,
    )
    qr.add_data(url)
    qr.make(fit=True)
    return qr.make_image(fill_color="black", back_color="white").convert("RGB")


def generate_single_png(asset_id, output_dir="qr_codes"):
    """Generate one labeled QR PNG for an asset ID."""
    os.makedirs(output_dir, exist_ok=True)
    url = asset_url(asset_id)
    qr_img = make_qr(url)

    qw, qh = qr_img.size
    pad = 10
    label_h = 32

    final = Image.new("RGB", (qw, qh + label_h + pad * 2), "white")
    final.paste(qr_img, (0, pad))

    draw = ImageDraw.Draw(final)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
    except Exception:
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), asset_id, font=font)
    text_w = bbox[2] - bbox[0]
    x = (qw - text_w) / 2
    draw.text((x, qh + pad), asset_id, fill="black", font=font)

    out = os.path.join(output_dir, f"{asset_id}.png")
    final.save(out, dpi=(DPI, DPI))
    return out


def generate_label_sheet(asset_ids, output_path="asset-tags.pdf"):
    """
    Generate a printable Avery 5160 label sheet PDF.
    Falls back to individual PNGs if reportlab is not installed.
    """
    try:
        from reportlab.lib.pagesizes import letter
        from reportlab.pdfgen import canvas as rl_canvas
        from reportlab.lib.units import inch
    except ImportError:
        print("reportlab not installed -- generating individual PNGs instead.")
        print("To enable PDF sheets: pip install reportlab")
        out_dir = output_path.replace(".pdf", "_pngs")
        for aid in asset_ids:
            p = generate_single_png(aid, out_dir)
            print(f"  {p}")
        return

    c = rl_canvas.Canvas(output_path, pagesize=letter)
    page_w, page_h = letter

    lw = LABEL_W_IN * inch
    lh = LABEL_H_IN * inch

    idx = 0
    while idx < len(asset_ids):
        for row in range(LABEL_ROWS):
            for col in range(LABEL_COLS):
                if idx >= len(asset_ids):
                    break

                aid = asset_ids[idx]
                idx += 1

                x = MARGIN_LEFT * inch + col * (lw + GAP_H * inch)
                y = page_h - MARGIN_TOP * inch - (row + 1) * (lh + GAP_V * inch)

                # Build the QR code and draw it into the label
                qr_img  = make_qr(asset_url(aid))
                buf     = io.BytesIO()
                qr_img.save(buf, format="PNG")
                buf.seek(0)

                qr_size = lh * 0.88
                qr_x    = x + 4
                qr_y    = y + (lh - qr_size) / 2

                c.drawImage(buf, qr_x, qr_y, width=qr_size, height=qr_size,
                            preserveAspectRatio=True)

                # Asset ID and company label
                text_x = qr_x + qr_size + 6
                text_y = y + lh / 2 + 4

                c.setFont("Helvetica-Bold", 9)
                c.drawString(text_x, text_y, aid)

                c.setFont("Helvetica", 7)
                c.setFillColorRGB(0.43, 0.43, 0.43)
                c.drawString(text_x, text_y - 11, "PGCIS Equipment")
                c.setFillColorRGB(0, 0, 0)

        if idx < len(asset_ids):
            c.showPage()

    c.save()
    print(f"PDF sheet saved: {output_path}  ({idx} labels)")


def parse_id_list(csv_str):
    return [x.strip().upper() for x in csv_str.split(",") if x.strip()]


def make_ids(start, end, prefix):
    return [f"{prefix}-{str(i).zfill(4)}" for i in range(start, end + 1)]


# ----------------------------------------------------------------
# CLI
# ----------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Generate PGCIS asset QR code labels.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    id_group = parser.add_mutually_exclusive_group(required=True)
    id_group.add_argument("--start", type=int,
                          help="Starting asset number (use with --end)")
    id_group.add_argument("--list", metavar="IDS",
                          help="Comma-separated list of asset IDs, e.g. PGCIS-0001,PGCIS-0005")

    parser.add_argument("--end",    type=int, default=None,
                        help="Ending asset number (required with --start)")
    parser.add_argument("--prefix", default=PREFIX,
                        help=f"Asset ID prefix (default: {PREFIX})")
    parser.add_argument("--format", choices=["pdf", "png"], default="pdf",
                        help="Output format: pdf (label sheet) or png (individual files)")
    parser.add_argument("--output", default="asset-tags",
                        help="Output base path (default: asset-tags)")
    parser.add_argument("--url",    default=BASE_URL,
                        help=f"Base URL for QR codes (default: {BASE_URL})")

    args = parser.parse_args()

    global BASE_URL
    BASE_URL = args.url.rstrip("/") + "/"

    if args.list:
        asset_ids = parse_id_list(args.list)
    else:
        if args.end is None:
            parser.error("--end is required when using --start")
        asset_ids = make_ids(args.start, args.end, args.prefix)

    print(f"Generating {len(asset_ids)} QR codes: {asset_ids[0]} ... {asset_ids[-1]}")
    print(f"Base URL: {BASE_URL}")

    if args.format == "pdf":
        out = args.output if args.output.endswith(".pdf") else args.output + ".pdf"
        generate_label_sheet(asset_ids, out)
    else:
        for aid in asset_ids:
            p = generate_single_png(aid, args.output)
            print(f"  {p}")
        print(f"Done. {len(asset_ids)} PNGs saved to ./{args.output}/")


if __name__ == "__main__":
    main()
