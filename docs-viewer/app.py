import os
from flask import Flask, Response
from google.cloud import storage

app = Flask(__name__)

BUCKET = os.environ.get("DOCS_BUCKET_NAME")
INDEX_OBJECT = os.environ.get("DOCS_INDEX_OBJECT", "index.html")
CACHE_CONTROL = os.environ.get("DOCS_CACHE_CONTROL", "public, max-age=60")

if not BUCKET:
    raise RuntimeError("DOCS_BUCKET_NAME env var is required")

storage_client = storage.Client()
bucket = storage_client.bucket(BUCKET)


def fetch_bytes():
    blob = bucket.blob(INDEX_OBJECT)
    if not blob.exists():
        return None
    return blob.download_as_bytes()


@app.get("/")
def root():
    content = fetch_bytes()
    if content is None:
        return Response("index.html not found", status=404)
    return Response(content, mimetype="text/html", headers={"Cache-Control": CACHE_CONTROL})


@app.get("/healthz")
def healthz():
    return {"status": "ok"}

