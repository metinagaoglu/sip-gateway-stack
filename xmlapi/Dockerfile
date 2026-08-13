FROM python:3.11-slim

LABEL maintainer="VoIP Stack"
LABEL description="FreeSWITCH XML API Service with PostgreSQL Backend"

WORKDIR /app

# Install system dependencies for health check
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir \
    flask==3.0.0 \
    psycopg2-binary==2.9.9 \
    gunicorn==21.2.0

# Copy application
COPY app.py .

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8080/health').raise_for_status()" || exit 1

# Run with gunicorn (production-ready)
CMD ["gunicorn", \
     "--workers", "4", \
     "--bind", "0.0.0.0:8080", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "--log-level", "info", \
     "app:app"]
