"""Runtime-stage build gate for the Docling Serve package (run by the Dockerfile on the assembled image).

Imports the native modules and the OCR engine modules the package ships, then converts one tiny PDF,
generated here, to Markdown three ways: its text layer, then a forced full-page OCR pass through each
of the two Python OCR engines the package bakes models for (EasyOCR, the default, and RapidOCR). Every
step uses the baked models only (no network). A missing system library (libGL, libglib, libgomp) fails
here, at build time, rather than on a customer's first conversion.
"""
import os, sys, tempfile, time
assert sys.version_info[:2] == (3, 12), sys.version
import cv2, torch, torchvision, onnxruntime
import easyocr, rapidocr
from docling.document_converter import DocumentConverter, PdfFormatOption
from docling.datamodel.base_models import InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions, EasyOcrOptions, RapidOcrOptions
from docling.models.stages.ocr.easyocr_model import EasyOcrModel
from docling.models.stages.ocr.rapid_ocr_model import RapidOcrModel
assert torch.__version__.endswith("+cpu") and not torch.cuda.is_available()
text = "Docling gate smoke test"
stream = f"BT /F1 24 Tf 72 700 Td ({text}) Tj ET".encode()
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
pdf, offs = b"%PDF-1.4\n", []
for i, o in enumerate(objs, 1):
    offs.append(len(pdf)); pdf += b"%d 0 obj\n" % i + o + b"\nendobj\n"
x = len(pdf)
pdf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
pdf += b"".join(b"%010d 00000 n \n" % o for o in offs)
pdf += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
path = os.path.join(tempfile.mkdtemp(), "gate.pdf")
open(path, "wb").write(pdf)
art = os.environ["DOCLING_SERVE_ARTIFACTS_PATH"]
for label, opts in (
    ("text layer", PdfPipelineOptions(artifacts_path=art, do_ocr=False)),
    ("easyocr full-page", PdfPipelineOptions(artifacts_path=art, do_ocr=True,
        ocr_options=EasyOcrOptions(force_full_page_ocr=True))),
    ("rapidocr full-page", PdfPipelineOptions(artifacts_path=art, do_ocr=True,
        ocr_options=RapidOcrOptions(force_full_page_ocr=True))),
):
    t = time.time()
    conv = DocumentConverter(format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=opts)})
    md = conv.convert(path).document.export_to_markdown()
    print(f"convert [{label}] {time.time()-t:.1f}s ->", repr(md.strip()))
    assert "gate" in md.lower() and "smoke" in md.lower(), md
print("runtime gate ok:", sys.version.split()[0], torch.__version__)
