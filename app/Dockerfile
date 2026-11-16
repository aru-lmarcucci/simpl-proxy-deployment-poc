# Base image pinned in poc/versions.env (PYTHON_IMAGE), passed by poc/build.sh.
ARG PYTHON_IMAGE
FROM ${PYTHON_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY proxy/ proxy/

USER 10001:10001
EXPOSE 8080
CMD ["python", "-m", "proxy"]
