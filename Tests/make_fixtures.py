"""Generate synthetic PDFs for the compressor integration checks."""
from pathlib import Path
import random
import sys
from PIL import Image
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from pypdf import PdfReader, PdfWriter

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
rng = random.Random(7)
pixels = rng.randbytes(1800 * 2400 * 3)
image = Image.frombytes("RGB", (1800, 2400), pixels)
source = root / "sample with spaces.pdf"
c = canvas.Canvas(str(source), pagesize=(612, 792))
for i in range(2):
    c.setFont("Helvetica-Bold", 24)
    c.drawString(40, 750, f"Compression check - page {i + 1}")
    c.setFont("Helvetica", 13)
    c.drawString(40, 726, "This text should remain selectable after compression.")
    c.drawImage(ImageReader(image), 40, 70, width=532, height=638)
    c.showPage()
c.save()

c = canvas.Canvas(str(root / "tiny.pdf"), pagesize=(612, 792))
c.drawString(40, 750, "Tiny text-only PDF")
c.save()

writer = PdfWriter()
writer.append(PdfReader(str(root / "tiny.pdf")))
writer.encrypt("secret")
writer.write(root / "protected.pdf")

c = canvas.Canvas(str(root / "form.pdf"))
c.drawString(40, 760, "Interactive form")
c.acroForm.textfield(name="name", x=40, y=700, width=180, height=25)
c.showPage()
c.save()
(root / "invalid.pdf").write_text("not a PDF")
print(f"Created fixtures in {root}")
