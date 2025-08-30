FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py /app/app.py

# Default envs (override at deploy)
ENV DOCS_INDEX_OBJECT=index.html \
    DOCS_CACHE_CONTROL="public, max-age=60"

CMD ["gunicorn", "-b", ":8080", "-w", "2", "app:app"]

