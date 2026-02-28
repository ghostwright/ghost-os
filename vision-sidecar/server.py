#!/usr/bin/env python3
"""
Ghost OS Vision Sidecar — HTTP server for VLM grounding and element detection.

Runs on localhost:9876. Ghost OS v2 (Swift) calls this when the AX tree
can't find what the agent needs (web apps, dynamic content, etc.).

Architecture:
  Layer 1: YOLO element detection (<200ms) — finds ALL interactive elements
  Layer 2: VLM precision grounding (0.5-3s) — finds ONE specific element

Endpoints:
  GET  /health    — Check if models are loaded and server is ready
  POST /ground    — Find precise coordinates for a described element
  POST /detect    — Detect all interactive elements (YOLO) [placeholder]
  POST /parse     — Combined detect + context analysis [placeholder]

The server uses Python's built-in http.server to minimize dependencies.
Models are loaded lazily on first request and kept warm in memory.
"""

import base64
import io
import json
import os
import re
import sys
import tempfile
import time
import traceback
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from threading import Lock

# ── Configuration ──────────────────────────────────────────────────

HOST = "127.0.0.1"
PORT = int(os.environ.get("GHOST_VISION_PORT", "9876"))
MODEL_PATH = str(Path.home() / ".shadow/models/llm/ShowUI-2B-bf16-8bit")

# ── Model State (lazy-loaded, thread-safe) ─────────────────────────

_vlm_model = None
_vlm_processor = None
_vlm_tokenizer = None
_vlm_lock = Lock()
_vlm_load_error = None


def _load_vlm():
    """Load ShowUI-2B model. Called once, cached forever."""
    global _vlm_model, _vlm_processor, _vlm_tokenizer, _vlm_load_error

    with _vlm_lock:
        if _vlm_model is not None:
            return True
        if _vlm_load_error is not None:
            return False

        try:
            log(f"Loading ShowUI-2B from {MODEL_PATH}...")
            t0 = time.time()

            from mlx_vlm import load
            _vlm_model, _vlm_processor = load(MODEL_PATH)

            # CRITICAL: Force the slow image processor. The fast Qwen2VLImageProcessor
            # requires PyTorch tensors which MLX doesn't provide.
            from transformers import Qwen2VLImageProcessor
            _vlm_processor.image_processor = Qwen2VLImageProcessor.from_pretrained(
                MODEL_PATH, use_fast=False
            )

            from transformers import AutoTokenizer
            _vlm_tokenizer = AutoTokenizer.from_pretrained(MODEL_PATH)

            log(f"ShowUI-2B loaded in {time.time() - t0:.1f}s")
            return True
        except Exception as e:
            _vlm_load_error = str(e)
            log(f"ERROR loading ShowUI-2B: {e}")
            traceback.print_exc(file=sys.stderr)
            return False


def _vlm_ground(image_path: str, description: str, screen_w: float, screen_h: float) -> dict:
    """
    Run ShowUI-2B grounding on an image.

    Args:
        image_path: Path to image file (will be resized internally)
        description: What to find (e.g., "Compose button")
        screen_w: Logical width in points (used to scale normalized output)
        screen_h: Logical height in points

    Returns:
        {"x": float, "y": float, "confidence": float, "raw": str}
    """
    from PIL import Image

    # Resize to ~1280px max edge for ShowUI-2B's pixel budget
    img = Image.open(image_path)
    max_edge = 1280
    w, h = img.size
    resized_path = tempfile.mktemp(suffix=".jpg", prefix="ghost_vlm_")
    if max(w, h) > max_edge:
        scale = max_edge / max(w, h)
        img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
    img.convert("RGB").save(resized_path, format="JPEG", quality=85)

    # ShowUI-2B prompt format
    system_text = (
        "Based on the screenshot of the page, I give a text description and you give its "
        "corresponding location. The coordinate represents a clickable location [x, y] for "
        "an element, which is a relative coordinate on the screenshot, scaled from 0 to 1."
    )
    prompt = f"{system_text}\n{description}"

    from mlx_vlm import stream_generate

    # Build chat template
    chat = [{"role": "user", "content": [
        {"type": "image", "image": resized_path},
        {"type": "text", "text": prompt}
    ]}]
    formatted = _vlm_tokenizer.apply_chat_template(
        chat, tokenize=False, add_generation_prompt=True
    )

    # Run inference
    t0 = time.time()
    full_text = ""
    for result in stream_generate(
        _vlm_model, _vlm_processor, formatted,
        image=resized_path,
        max_tokens=128,
        temp=0.0
    ):
        full_text += result.text if hasattr(result, 'text') else str(result)

    elapsed = time.time() - t0
    log(f"VLM '{description}' -> '{full_text.strip()}' ({elapsed:.1f}s)")

    # Clean up temp file
    try:
        os.unlink(resized_path)
    except OSError:
        pass

    # Parse [x, y] or (x, y) coordinates from model output
    match = re.search(r'[\(\[]\s*([\d.]+)\s*,\s*([\d.]+)\s*[\)\]]', full_text)
    if match:
        nx, ny = float(match.group(1)), float(match.group(2))
        if nx <= 1.0 and ny <= 1.0:
            return {
                "x": round(nx * screen_w, 1),
                "y": round(ny * screen_h, 1),
                "normalized_x": round(nx, 4),
                "normalized_y": round(ny, 4),
                "confidence": 0.8,
                "raw": full_text.strip(),
                "inference_ms": int(elapsed * 1000),
            }
        else:
            # Model returned pixel coordinates instead of normalized
            return {
                "x": round(nx, 1),
                "y": round(ny, 1),
                "normalized_x": round(nx / screen_w, 4),
                "normalized_y": round(ny / screen_h, 4),
                "confidence": 0.6,
                "raw": full_text.strip(),
                "inference_ms": int(elapsed * 1000),
            }

    # Failed to parse coordinates
    return {
        "x": round(screen_w / 2, 1),
        "y": round(screen_h / 2, 1),
        "normalized_x": 0.5,
        "normalized_y": 0.5,
        "confidence": 0.0,
        "raw": full_text.strip(),
        "inference_ms": int(elapsed * 1000),
        "error": "Failed to parse coordinates from model output",
    }


# ── HTTP Request Handler ───────────────────────────────────────────

class VisionHandler(BaseHTTPRequestHandler):
    """Handles HTTP requests for the vision sidecar."""

    def do_GET(self):
        if self.path == "/health":
            self._handle_health()
        else:
            self._send_json(404, {"error": f"Not found: {self.path}"})

    def do_POST(self):
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body) if body else {}
        except (json.JSONDecodeError, ValueError) as e:
            self._send_json(400, {"error": f"Invalid JSON: {e}"})
            return

        if self.path == "/ground":
            self._handle_ground(data)
        elif self.path == "/detect":
            self._handle_detect(data)
        elif self.path == "/parse":
            self._handle_parse(data)
        else:
            self._send_json(404, {"error": f"Not found: {self.path}"})

    def _handle_health(self):
        models = []
        if _vlm_model is not None:
            models.append("showui-2b")

        status = "ready" if _vlm_model is not None else "idle"
        self._send_json(200, {
            "status": status,
            "models_loaded": models,
            "model_path": MODEL_PATH,
            "model_exists": os.path.isdir(MODEL_PATH),
            "vlm_load_error": _vlm_load_error,
        })

    def _handle_ground(self, data: dict):
        """
        Find precise coordinates for a described UI element.

        Required: image (base64 PNG), description (str)
        Optional: screen_w, screen_h, crop_box [x1,y1,x2,y2] in logical points
        """
        image_b64 = data.get("image")
        description = data.get("description")
        screen_w = float(data.get("screen_w", 1728))
        screen_h = float(data.get("screen_h", 1117))
        crop_box = data.get("crop_box")  # [x1, y1, x2, y2] logical points

        if not image_b64:
            self._send_json(400, {"error": "Missing 'image' (base64 PNG)"})
            return
        if not description:
            self._send_json(400, {"error": "Missing 'description'"})
            return

        # Load model if needed
        if not _load_vlm():
            self._send_json(503, {
                "error": "ShowUI-2B model failed to load",
                "detail": _vlm_load_error,
                "suggestion": "Check that model exists at " + MODEL_PATH,
            })
            return

        try:
            from PIL import Image

            # Decode base64 image to temp file
            image_data = base64.b64decode(image_b64)
            img = Image.open(io.BytesIO(image_data))

            if crop_box:
                # Crop-based grounding: crop the specified region, run VLM on crop,
                # then map coordinates back to full screen.
                # crop_box is in logical points. Image may be at different resolution.
                x1, y1, x2, y2 = crop_box
                crop_w = x2 - x1
                crop_h = y2 - y1

                # Calculate pixel coordinates for cropping
                # The image from Ghost OS is already at 1280px width (logical-ish)
                # We need to scale crop_box from logical points to image pixels
                img_w, img_h = img.size
                scale_x = img_w / screen_w
                scale_y = img_h / screen_h

                px1 = int(x1 * scale_x)
                py1 = int(y1 * scale_y)
                px2 = int(x2 * scale_x)
                py2 = int(y2 * scale_y)

                crop = img.crop((px1, py1, px2, py2))

                # Save crop to temp file
                crop_path = tempfile.mktemp(suffix=".png", prefix="ghost_crop_")
                crop.save(crop_path)

                # Run VLM on crop with crop dimensions
                result = _vlm_ground(crop_path, description, crop_w, crop_h)

                # Map coordinates back to full screen
                result["x"] = round(x1 + result["x"], 1)
                result["y"] = round(y1 + result["y"], 1)
                result["normalized_x"] = round(result["x"] / screen_w, 4)
                result["normalized_y"] = round(result["y"] / screen_h, 4)
                result["method"] = "crop-based"
                result["crop_box"] = crop_box

                try:
                    os.unlink(crop_path)
                except OSError:
                    pass
            else:
                # Full-screen grounding
                img_path = tempfile.mktemp(suffix=".png", prefix="ghost_full_")
                img.save(img_path)

                result = _vlm_ground(img_path, description, screen_w, screen_h)
                result["method"] = "full-screen"

                try:
                    os.unlink(img_path)
                except OSError:
                    pass

            self._send_json(200, result)

        except Exception as e:
            log(f"ERROR in /ground: {e}")
            traceback.print_exc(file=sys.stderr)
            self._send_json(500, {"error": str(e)})

    def _handle_detect(self, data: dict):
        """
        Detect all interactive UI elements on screen.

        This is a placeholder for YOLO-based element detection.
        Currently returns a stub response indicating the feature is not yet available.
        When implemented, this will use YOLOv11 (Screen2AX) to detect buttons,
        text fields, links, etc. with bounding boxes.
        """
        self._send_json(200, {
            "elements": [],
            "count": 0,
            "note": "YOLO element detection not yet implemented. Use /ground for VLM-based element finding.",
            "suggestion": "Use ghost_find (AX tree) first, fall back to /ground for specific elements.",
        })

    def _handle_parse(self, data: dict):
        """
        Parse screen into structured element map.

        Placeholder for combined YOLO detection + VLM context analysis.
        """
        self._send_json(200, {
            "elements": [],
            "context": "Screen parsing not yet implemented.",
            "suggestion": "Use ghost_context for AX-based context, ghost_screenshot + /ground for visual grounding.",
        })

    def _send_json(self, status: int, data: dict):
        response = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format, *args):
        """Override to send access logs to stderr with our format."""
        log(f"HTTP {args[0]}")


# ── Logging ────────────────────────────────────────────────────────

def log(msg: str):
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    print(f"[{ts}] [VISION] {msg}", file=sys.stderr, flush=True)


# ── Main ───────────────────────────────────────────────────────────

def main():
    log(f"Ghost OS Vision Sidecar starting on {HOST}:{PORT}")
    log(f"ShowUI-2B model path: {MODEL_PATH}")
    log(f"Model exists: {os.path.isdir(MODEL_PATH)}")

    # Pre-load VLM if --preload flag is set
    if "--preload" in sys.argv:
        log("Pre-loading VLM model...")
        _load_vlm()

    # Allow port reuse to prevent "Address already in use" on restart
    import socketserver
    class ReusableTCPServer(HTTPServer):
        allow_reuse_address = True
        allow_reuse_port = True

    server = ReusableTCPServer((HOST, PORT), VisionHandler)
    log(f"Listening on http://{HOST}:{PORT}")
    log("Endpoints: GET /health, POST /ground, POST /detect, POST /parse")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
