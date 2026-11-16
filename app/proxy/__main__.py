"""Proxy stub entrypoint: root CA bootstrap, then a tiny HTTP server (docs/plan.md §4.1).

Base dir /app/certs in both modes (a per-instance emptyDir in the new chart, the shared PVC in
the legacy one).
PROXY_MODE=new (default): root CA from env only, written to /app/certs/_ca.
PROXY_MODE=legacy: current behaviour, generates the CA in /app/certs/_ca if missing.
"""

import json
import os
import re
import signal
import sys
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import NameOID

from .bootstrap import CA_DIRNAME, CERT_FILE, KEY_FILE, BootstrapError, RootCA, bootstrap, parse, validate, write_ca, write_file

PORT = 8080
# Overridable only for local tests.
BASE_DIR = Path(os.environ.get("PROXY_BASE_DIR", "/app/certs"))

HOST_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$")


def log(record: dict) -> None:
    print(json.dumps(record), flush=True)


def pem_key(key) -> bytes:
    return key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )


def generate_ca(common_name: str, days: int = 3650):
    """Self-signed root CA, RSA 4096, same extensions as the provisioning job."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=4096)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=days))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=False, content_commitment=False, key_encipherment=False,
                data_encipherment=False, key_agreement=False, key_cert_sign=True, crl_sign=True,
                encipher_only=False, decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
        .sign(key, hashes.SHA256())
    )
    return key, cert


def legacy_bootstrap(base_dir: Path) -> RootCA:
    """Current proxy behaviour: use the CA in base_dir/_ca, generate it if absent."""
    ca_dir = base_dir / CA_DIRNAME
    key_path, cert_path = ca_dir / KEY_FILE, ca_dir / CERT_FILE
    present = [p.is_file() for p in (key_path, cert_path)]
    source = "legacy-volume"
    if not any(present):
        key, cert = generate_ca("Proxy Root CA (legacy)")
        write_ca(ca_dir, pem_key(key), cert.public_bytes(serialization.Encoding.PEM))
        source = "generated"
    elif not all(present):
        raise BootstrapError(f"incomplete CA on legacy volume: {ca_dir}")
    key, cert = parse(key_path.read_bytes(), cert_path.read_bytes(), str(key_path), str(cert_path))
    validate(key, cert)
    return RootCA(key=key, cert=cert, source=source)


class Issuer:
    def __init__(self, ca: RootCA, base_dir: Path):
        self.ca = ca
        self.base_dir = base_dir
        self.lock = threading.Lock()

    def issue(self, host: str) -> dict:
        host_dir = self.base_dir / host
        cert_path = host_dir / "cert.pem"
        with self.lock:
            reused = cert_path.is_file()
            if not reused:
                key = ec.generate_private_key(ec.SECP256R1())
                now = datetime.now(timezone.utc)
                cert = (
                    x509.CertificateBuilder()
                    .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, host)]))
                    .issuer_name(self.ca.cert.subject)
                    .public_key(key.public_key())
                    .serial_number(x509.random_serial_number())
                    .not_valid_before(now - timedelta(minutes=5))
                    .not_valid_after(now + timedelta(days=90))
                    .add_extension(x509.SubjectAlternativeName([x509.DNSName(host)]), critical=False)
                    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                    .sign(self.ca.key, hashes.SHA256())
                )
                host_dir.mkdir(mode=0o700, exist_ok=True)
                write_file(host_dir / "key.pem", pem_key(key), 0o600)
                write_file(cert_path, cert.public_bytes(serialization.Encoding.PEM), 0o644)
            cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        return {"host": host, "serial": format(cert.serial_number, "x"), "path": str(cert_path), "reused": reused}

    def list(self) -> list:
        return sorted(
            p.name for p in self.base_dir.iterdir()
            if p.is_dir() and p.name != CA_DIRNAME and (p / "cert.pem").is_file()
        )


def make_handler(issuer: Issuer):
    class Handler(BaseHTTPRequestHandler):
        def reply(self, status: int, body) -> None:
            data = (body if isinstance(body, str) else json.dumps(body)).encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain" if isinstance(body, str) else "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/healthz":
                self.reply(200, "ok")
            elif url.path == "/ca":
                ca = issuer.ca
                self.reply(200, {
                    "source": ca.source,
                    "fingerprint_sha256": ca.fingerprint,
                    "not_after": ca.cert.not_valid_after_utc.isoformat(),
                    "pod": os.environ.get("HOSTNAME", ""),
                })
            elif url.path == "/issue":
                host = parse_qs(url.query).get("host", [""])[0].lower()
                if not HOST_RE.match(host):
                    self.reply(400, {"error": "invalid host"})
                else:
                    self.reply(200, issuer.issue(host))
            elif url.path == "/certs":
                self.reply(200, issuer.list())
            else:
                self.reply(404, {"error": "not found"})

        def log_message(self, *args):  # keep logs quiet (probes)
            pass

    return Handler


def main() -> int:
    mode = os.environ.get("PROXY_MODE", "new")
    try:
        if mode == "new":
            ca = bootstrap(os.environ, BASE_DIR)
        elif mode == "legacy":
            ca = legacy_bootstrap(BASE_DIR)
        else:
            raise BootstrapError(f"unknown PROXY_MODE '{mode}' (expected 'new' or 'legacy')")
    except BootstrapError as e:
        print(f"ERROR: {e}", file=sys.stderr, flush=True)
        return 1

    log({**ca.log_record(), "mode": mode})
    # PID 1 in a container ignores SIGTERM without a handler.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(Issuer(ca, BASE_DIR)))
    log({"event": "listening", "port": PORT})
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
