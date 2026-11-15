FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPATH=/app

WORKDIR /app

# The NAS can reach the Tsinghua PyPI mirror; Docker Hub pulls are not required
# at runtime because this image is built locally.
COPY requirements.txt ./
RUN pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple \
        -r requirements.txt

# Match the host service account that owns ./runtime (uid 984 / gid 978).
# The worker's openGym mount is read-only and deliberately cannot read
# openGym's 0600 auth files (db.json / secret).
RUN groupadd -g 978 daydayhealth \
    && useradd -u 984 -g 978 -M -s /usr/sbin/nologin daydayhealth

COPY --chown=984:978 daydayhealth ./daydayhealth
RUN chmod -R a+rX /app/daydayhealth

USER 984:978

EXPOSE 8000

CMD ["uvicorn", "daydayhealth.main:app", "--host", "0.0.0.0", "--port", "8000"]
