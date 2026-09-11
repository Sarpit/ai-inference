FROM python:3.12-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends libldap2-dev libsasl2-dev gcc \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Runs as uid 1000, not root. /data (the sqlite DB dir) is a host bind mount
# in docker-compose.yaml -- make sure that host directory is writable by
# uid 1000 (e.g. `chown -R 1000:1000 broker_data` on the host), or override
# this with --user matching your host uid if that's not practical.
RUN useradd --create-home --uid 1000 broker
USER broker

EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
