"""Bootstrap matrix (docs/plan.md §4.1). Test CAs are generated here, never committed."""

import base64
import stat
from datetime import datetime, timedelta, timezone

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import NameOID

from proxy.__main__ import legacy_bootstrap
from proxy.bootstrap import CA_DIRNAME, CERT_FILE, ENV_CERT, ENV_KEY, KEY_FILE, BootstrapError, bootstrap

NOW = datetime.now(timezone.utc)


def make_ca(cn="Test Root CA", is_ca=True, not_before=None, not_after=None):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    builder = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before or NOW - timedelta(days=1))
        .not_valid_after(not_after or NOW + timedelta(days=365))
    )
    if is_ca is not None:
        builder = builder.add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True)
    cert = builder.sign(key, hashes.SHA256())
    key_pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    return key_pem, cert.public_bytes(serialization.Encoding.PEM)


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def fingerprint(cert_pem: bytes) -> str:
    return x509.load_pem_x509_certificate(cert_pem).fingerprint(hashes.SHA256()).hex()


@pytest.fixture
def dirs(tmp_path):
    legacy, data = tmp_path / "legacy", tmp_path / "data"
    legacy.mkdir()
    return legacy, data


def put_legacy(legacy, key_pem=None, cert_pem=None):
    ca = legacy / CA_DIRNAME
    ca.mkdir(exist_ok=True)
    if key_pem is not None:
        (ca / KEY_FILE).write_bytes(key_pem)
    if cert_pem is not None:
        (ca / CERT_FILE).write_bytes(cert_pem)


def snapshot(path):
    return {p: p.read_bytes() for p in sorted(path.rglob("*")) if p.is_file()}


# --- matrix ----------------------------------------------------------------

@pytest.mark.parametrize("with_legacy", [False, True])
def test_env_both_set_wins(dirs, with_legacy):
    legacy, data = dirs
    key, cert = make_ca("Env CA")
    if with_legacy:
        put_legacy(legacy, *make_ca("Legacy CA"))
    before = snapshot(legacy)

    ca = bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(cert)}, legacy, data)

    assert ca.source == "env"
    assert ca.fingerprint == fingerprint(cert)
    assert (data / CA_DIRNAME / KEY_FILE).read_bytes() == key
    assert (data / CA_DIRNAME / CERT_FILE).read_bytes() == cert
    assert snapshot(legacy) == before  # never writes the legacy volume


@pytest.mark.parametrize("set_var,empty_var", [(ENV_KEY, ENV_CERT), (ENV_CERT, ENV_KEY)])
@pytest.mark.parametrize("empty_value", [None, "", "  \n"])
def test_partial_env_fails(dirs, set_var, empty_var, empty_value):
    legacy, data = dirs
    key, cert = make_ca()
    put_legacy(legacy, key, cert)  # irrelevant: partial config is always an error
    env = {set_var: b64(key if set_var == ENV_KEY else cert)}
    if empty_value is not None:
        env[empty_var] = empty_value
    with pytest.raises(BootstrapError, match="partial configuration"):
        bootstrap(env, legacy, data)


@pytest.mark.parametrize("env", [{}, {ENV_KEY: "", ENV_CERT: ""}, {ENV_KEY: " ", ENV_CERT: "\n\t"}])
def test_legacy_volume_used_when_env_empty(dirs, env):
    legacy, data = dirs
    key, cert = make_ca("Legacy CA")
    put_legacy(legacy, key, cert)
    before = snapshot(legacy)

    ca = bootstrap(env, legacy, data)

    assert ca.source == "legacy-volume"
    assert ca.fingerprint == fingerprint(cert)
    assert (data / CA_DIRNAME / KEY_FILE).read_bytes() == key
    assert (data / CA_DIRNAME / CERT_FILE).read_bytes() == cert
    assert snapshot(legacy) == before


@pytest.mark.parametrize("which", ["key", "cert"])
def test_incomplete_legacy_volume_fails(dirs, which):
    legacy, data = dirs
    key, cert = make_ca()
    put_legacy(legacy, key if which == "key" else None, cert if which == "cert" else None)
    with pytest.raises(BootstrapError, match="incomplete CA on legacy volume"):
        bootstrap({ENV_KEY: "", ENV_CERT: ""}, legacy, data)


@pytest.mark.parametrize("make_dir", [False, True])
def test_no_ca_anywhere_fails(dirs, make_dir):
    legacy, data = dirs
    if make_dir:
        put_legacy(legacy)
    with pytest.raises(BootstrapError, match="no root CA available"):
        bootstrap({}, legacy, data)
    assert not (data / CA_DIRNAME / KEY_FILE).exists()


# --- input handling and validation ----------------------------------------

def test_invalid_base64_names_variable_not_value(dirs):
    legacy, data = dirs
    _, cert = make_ca()
    bad = "not*base64*SECRETVALUE"
    with pytest.raises(BootstrapError) as e:
        bootstrap({ENV_KEY: bad, ENV_CERT: b64(cert)}, legacy, data)
    assert ENV_KEY in str(e.value) and "base64" in str(e.value)
    assert "SECRETVALUE" not in str(e.value)


def test_invalid_pem_in_env(dirs):
    legacy, data = dirs
    key, _ = make_ca()
    with pytest.raises(BootstrapError, match=ENV_CERT):
        bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(b"hello")}, legacy, data)


def test_values_with_newlines_and_spaces(dirs):
    legacy, data = dirs
    key, cert = make_ca()
    wrap = lambda s: "  " + "\n".join(s[i:i + 64] for i in range(0, len(s), 64)) + " \n"
    ca = bootstrap({ENV_KEY: wrap(b64(key)), ENV_CERT: wrap(b64(cert))}, legacy, data)
    assert ca.fingerprint == fingerprint(cert)


@pytest.mark.parametrize("source", ["env", "legacy"])
def test_key_cert_mismatch(dirs, source):
    legacy, data = dirs
    key, _ = make_ca()
    _, other_cert = make_ca()
    env = {ENV_KEY: b64(key), ENV_CERT: b64(other_cert)} if source == "env" else {}
    if source == "legacy":
        put_legacy(legacy, key, other_cert)
    with pytest.raises(BootstrapError, match="does not match"):
        bootstrap(env, legacy, data)


@pytest.mark.parametrize("is_ca", [False, None])
def test_non_ca_certificate(dirs, is_ca):
    legacy, data = dirs
    key, cert = make_ca(is_ca=is_ca)
    with pytest.raises(BootstrapError, match="not a CA"):
        bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(cert)}, legacy, data)


@pytest.mark.parametrize("window", [
    (NOW - timedelta(days=30), NOW - timedelta(days=1)),   # expired
    (NOW + timedelta(days=1), NOW + timedelta(days=30)),   # not yet valid
])
def test_certificate_outside_validity(dirs, window):
    legacy, data = dirs
    key, cert = make_ca(not_before=window[0], not_after=window[1])
    with pytest.raises(BootstrapError, match="validity period"):
        bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(cert)}, legacy, data)


def test_file_permissions(dirs):
    legacy, data = dirs
    key, cert = make_ca()
    bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(cert)}, legacy, data)
    mode = lambda p: stat.S_IMODE(p.stat().st_mode)
    assert mode(data / CA_DIRNAME) == 0o700
    assert mode(data / CA_DIRNAME / KEY_FILE) == 0o600
    assert mode(data / CA_DIRNAME / CERT_FILE) == 0o644


def test_rsa_key_supported(dirs):
    legacy, data = dirs
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "RSA CA")])
    cert = (
        x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(1).not_valid_before(NOW - timedelta(days=1)).not_valid_after(NOW + timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    key_pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                                serialization.NoEncryption())
    cert_pem = cert.public_bytes(serialization.Encoding.PEM)
    ca = bootstrap({ENV_KEY: b64(key_pem), ENV_CERT: b64(cert_pem)}, legacy, data)
    assert ca.source == "env"


# --- legacy mode -------------------------------------------------------------

def test_legacy_mode_generates_then_reuses(tmp_path):
    first = legacy_bootstrap(tmp_path)
    assert first.source == "generated"
    second = legacy_bootstrap(tmp_path)
    assert second.source == "legacy-volume"
    assert second.fingerprint == first.fingerprint
    # The generated CA is accepted by the new-mode bootstrap.
    ca = bootstrap({}, tmp_path, tmp_path / "data")
    assert ca.fingerprint == first.fingerprint
