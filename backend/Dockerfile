# vLEI-Gate backend (verifier, CMC proxy, Atlas/CMC price check, Cournot).
# Build context = repository root (paths below are repo-relative):
#   docker build -f backend/Dockerfile -t vlei-gate-api .
# Secrets (VERIFIER_PRIVATE_KEY, CMC_API_KEY, ...) come from the environment at runtime (fly secrets), never the image.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
# keripy needs libsodium (pysodium) and builds a few native wheels.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsodium23 build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY backend/requirements.txt backend/requirements.txt
RUN pip install -r backend/requirements.txt && apt-get purge -y build-essential && apt-get autoremove -y

# Layout mirrors the repo: config.py resolves REPO_DIR = backend/.. for deployments and logs.
COPY backend/app backend/app
# Demo vLEI test chain (sample KERI keystore for the demo holder agent; testnet demo only).
COPY backend/data backend/data
COPY contracts/deployments contracts/deployments
# Proof of the live Cournot calls; served by /api/oracle/cournot-latest.
COPY logs/cournot logs/cournot

RUN useradd -m app && chown -R app /app
USER app
WORKDIR /app/backend
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--forwarded-allow-ips", "*"]
