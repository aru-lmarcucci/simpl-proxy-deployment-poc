"""Root CA bootstrap (docs/plan.md §4.1).

Pure logic: takes the environment and two directories, returns the loaded CA or
raises BootstrapError. Error messages name variables and files, never values.
"""

import base64
import binascii
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization

ENV_KEY = "ROOT_CA_PRIVATE_KEY"
ENV_CERT = "ROOT_CA_CERTIFICATE"
CA_DIRNAME = "_ca"
KEY_FILE = "private-key.pem"
CERT_FILE = "certificate.pem"


class BootstrapError(Exception):
    pass


@dataclass
class RootCA:
    key: object
    cert: x509.Certificate
    source: str

    @property
    def fingerprint(self) -> str:
        return self.cert.fingerprint(hashes.SHA256()).hex()

    def log_record(self) -> dict:
        return {
            "event": "root_ca_loaded",
            "source": self.source,
            "fingerprint_sha256": self.fingerprint,
            "subject": self.cert.subject.rfc4514_string(),
            "not_after": self.cert.not_valid_after_utc.isoformat(),
        }


def _blank(value) -> bool:
    return value is None or value.strip() == ""


def _decode_env(name: str, value: str) -> bytes:
    compact = "".join(value.split())
    try:
        return base64.b64decode(compact, validate=True)
    except (binascii.Error, ValueError):
        raise BootstrapError(f"{name} is not valid base64") from None


def parse(key_pem: bytes, cert_pem: bytes, key_label: str, cert_label: str):
    try:
        key = serialization.load_pem_private_key(key_pem, password=None)
    except Exception:
        raise BootstrapError(f"{key_label} does not contain a valid unencrypted PEM private key") from None
    try:
        cert = x509.load_pem_x509_certificate(cert_pem)
    except Exception:
        raise BootstrapError(f"{cert_label} does not contain a valid PEM certificate") from None
    return key, cert


def validate(key, cert: x509.Certificate, now: datetime | None = None) -> None:
    now = now or datetime.now(timezone.utc)
    spki = serialization.PublicFormat.SubjectPublicKeyInfo
    der = serialization.Encoding.DER
    if key.public_key().public_bytes(der, spki) != cert.public_key().public_bytes(der, spki):
        raise BootstrapError("root CA private key does not match the certificate")
    try:
        is_ca = cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca
    except x509.ExtensionNotFound:
        is_ca = False
    if not is_ca:
        raise BootstrapError("root CA certificate is not a CA (basicConstraints CA:TRUE missing)")
    if not (cert.not_valid_before_utc <= now <= cert.not_valid_after_utc):
        raise BootstrapError(
            "root CA certificate is outside its validity period "
            f"({cert.not_valid_before_utc.isoformat()} - {cert.not_valid_after_utc.isoformat()})"
        )


def write_file(path: Path, data: bytes, mode: int) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.fchmod(fd, mode)
        os.write(fd, data)
    finally:
        os.close(fd)


def write_ca(ca_dir: Path, key_pem: bytes, cert_pem: bytes) -> None:
    ca_dir.mkdir(parents=True, exist_ok=True)
    ca_dir.chmod(0o700)
    write_file(ca_dir / KEY_FILE, key_pem, 0o600)
    write_file(ca_dir / CERT_FILE, cert_pem, 0o644)


def bootstrap(env, legacy_dir: Path, data_dir: Path, now: datetime | None = None) -> RootCA:
    """Loads the root CA from env or from the legacy volume and copies it under data_dir/_ca.

    Never writes under legacy_dir.
    """
    key_val, cert_val = env.get(ENV_KEY), env.get(ENV_CERT)

    if not _blank(key_val) and not _blank(cert_val):
        source = "env"
        key_pem, cert_pem = _decode_env(ENV_KEY, key_val), _decode_env(ENV_CERT, cert_val)
        labels = (ENV_KEY, ENV_CERT)
    elif not _blank(key_val) or not _blank(cert_val):
        present, missing = (ENV_KEY, ENV_CERT) if not _blank(key_val) else (ENV_CERT, ENV_KEY)
        raise BootstrapError(f"partial configuration: {present} is set but {missing} is empty")
    else:
        source = "legacy-volume"
        legacy_ca = legacy_dir / CA_DIRNAME
        key_path, cert_path = legacy_ca / KEY_FILE, legacy_ca / CERT_FILE
        found = [p for p in (key_path, cert_path) if p.is_file()]
        if not found:
            raise BootstrapError(
                f"no root CA available: {ENV_KEY}/{ENV_CERT} are empty and {legacy_ca} has no CA files"
            )
        if len(found) == 1:
            raise BootstrapError(f"incomplete CA on legacy volume: only {found[0]} is present")
        key_pem, cert_pem = key_path.read_bytes(), cert_path.read_bytes()
        labels = (str(key_path), str(cert_path))

    key, cert = parse(key_pem, cert_pem, *labels)
    validate(key, cert, now)
    write_ca(data_dir / CA_DIRNAME, key_pem, cert_pem)
    return RootCA(key=key, cert=cert, source=source)
