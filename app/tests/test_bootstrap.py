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
def data(tmp_path):
    return tmp_path / "data"


# --- matrix ----------------------------------------------------------------

def test_env_both_set(data):
    key, cert = make_ca("Env CA")

    ca = bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(cert)}, data)

    assert ca.source == "env"
    assert ca.fingerprint == fingerprint(cert)
    assert (data / CA_DIRNAME / KEY_FILE).read_bytes() == key
    assert (data / CA_DIRNAME / CERT_FILE).read_bytes() == cert


@pytest.mark.parametrize("set_var,empty_var", [(ENV_KEY, ENV_CERT), (ENV_CERT, ENV_KEY)])
@pytest.mark.parametrize("empty_value", [None, "", "  \n"])
def test_partial_env_fails(data, set_var, empty_var, empty_value):
    key, cert = make_ca()
    env = {set_var: b64(key if set_var == ENV_KEY else cert)}
    if empty_value is not None:
        env[empty_var] = empty_value
    with pytest.raises(BootstrapError, match="partial configuration"):
        bootstrap(env, data)


@pytest.mark.parametrize("env", [{}, {ENV_KEY: "", ENV_CERT: ""}, {ENV_KEY: " ", ENV_CERT: "\n\t"}])
def test_no_ca_fails(data, env):
    with pytest.raises(BootstrapError, match="no root CA available"):
        bootstrap(env, data)
    assert not (data / CA_DIRNAME / KEY_FILE).exists()


# --- input handling and validation ----------------------------------------

def test_invalid_base64_names_variable_not_value(data):
    _, cert = make_ca()
    bad = "not*base64*SECRETVALUE"
    with pytest.raises(BootstrapError) as e:
        bootstrap({ENV_KEY: bad, ENV_CERT: b64(cert)}, data)
    assert ENV_KEY in str(e.value) and "base64" in str(e.value)
    assert "SECRETVALUE" not in str(e.value)


def test_invalid_pem_in_env(data):
    key, _ = make_ca()
    with pytest.raises(BootstrapError, match=ENV_CERT):
        bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(b"hello")}, data)


def test_values_with_newlines_and_spaces(data):
    key, cert = make_ca()
    wrap = lambda s: "  " + "\n".join(s[i:i + 64] for i in range(0, len(s), 64)) + " \n"
    ca = bootstrap({ENV_KEY: wrap(b64(key)), ENV_CERT: wrap(b64(cert))}, data)
    assert ca.fingerprint == fingerprint(cert)


def test_key_cert_mismatch(data):
    key, _ = make_ca()
    _, other_cert = make_ca()
    with pytest.raises(BootstrapError, match="does not match"):
        bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(other_cert)}, data)


@pytest.mark.parametrize("is_ca", [False, None])
def test_non_ca_certificate(data, is_ca):
    key, cert = make_ca(is_ca=is_ca)
    with pytest.raises(BootstrapError, match="not a CA"):
        bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(cert)}, data)


@pytest.mark.parametrize("window", [
    (NOW - timedelta(days=30), NOW - timedelta(days=1)),   # expired
    (NOW + timedelta(days=1), NOW + timedelta(days=30)),   # not yet valid
])
def test_certificate_outside_validity(data, window):
    key, cert = make_ca(not_before=window[0], not_after=window[1])
    with pytest.raises(BootstrapError, match="validity period"):
        bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(cert)}, data)


def test_file_permissions(data):
    key, cert = make_ca()
    bootstrap({ENV_KEY: b64(key), ENV_CERT: b64(cert)}, data)
    mode = lambda p: stat.S_IMODE(p.stat().st_mode)
    assert mode(data / CA_DIRNAME) == 0o700
    assert mode(data / CA_DIRNAME / KEY_FILE) == 0o600
    assert mode(data / CA_DIRNAME / CERT_FILE) == 0o644


def test_rsa_key_supported(data):
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
    ca = bootstrap({ENV_KEY: b64(key_pem), ENV_CERT: b64(cert_pem)}, data)
    assert ca.source == "env"


# --- legacy mode -------------------------------------------------------------

def test_legacy_mode_generates_then_reuses(tmp_path):
    first = legacy_bootstrap(tmp_path)
    assert first.source == "generated"
    second = legacy_bootstrap(tmp_path)
    assert second.source == "legacy-volume"
    assert second.fingerprint == first.fingerprint
    # The generated files, imported as-is by the provisioning job, are accepted by the new mode.
    ca_dir = tmp_path / CA_DIRNAME
    env = {ENV_KEY: b64((ca_dir / KEY_FILE).read_bytes()), ENV_CERT: b64((ca_dir / CERT_FILE).read_bytes())}
    ca = bootstrap(env, tmp_path / "data")
    assert ca.fingerprint == first.fingerprint
