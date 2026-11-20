#!/usr/bin/env python3
"""Minimal APK Signature Scheme v2 signer (RSA-2048 / SHA-256).

Used for local builds where Google's apksigner isn't available. CI builds use
the official apksigner through Godot. Usage:

    python3 tools/sign_apk.py unsigned.apk signed.apk --key key.pem --cert cert.der
    python3 tools/sign_apk.py --genkey key.pem cert.der      # one-time

Keep the same key for every build: Android only installs an update over an
existing app when the signatures match.
"""
import argparse
import datetime
import hashlib
import struct
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID

V2_BLOCK_ID = 0x7109871A
ALG_RSA_PKCS1_SHA256 = 0x0103
CHUNK = 1024 * 1024
MAGIC = b"APK Sig Block 42"


def lp(b: bytes) -> bytes:
    return struct.pack("<I", len(b)) + b


def find_eocd(data: bytes) -> int:
    for i in range(len(data) - 22, max(-1, len(data) - 22 - 65536), -1):
        if data[i:i + 4] == b"PK\x05\x06":
            return i
    raise ValueError("EOCD not found")


def chunk_digest(sections) -> bytes:
    digests = []
    for sec in sections:
        for off in range(0, len(sec), CHUNK):
            c = sec[off:off + CHUNK]
            digests.append(hashlib.sha256(b"\xa5" + struct.pack("<I", len(c)) + c).digest())
    return hashlib.sha256(b"\x5a" + struct.pack("<I", len(digests)) + b"".join(digests)).digest()


def genkey(key_path: str, cert_path: str) -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Racing Sim Dev")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now).not_valid_after(now + datetime.timedelta(days=365 * 30))
            .sign(key, hashes.SHA256()))
    open(key_path, "wb").write(key.private_bytes(serialization.Encoding.PEM,
                                                 serialization.PrivateFormat.PKCS8,
                                                 serialization.NoEncryption()))
    open(cert_path, "wb").write(cert.public_bytes(serialization.Encoding.DER))


def sign(src: str, dst: str, key_path: str, cert_path: str) -> None:
    data = open(src, "rb").read()
    eocd_off = find_eocd(data)
    cd_size, cd_off = struct.unpack("<II", data[eocd_off + 12:eocd_off + 20])
    if data[cd_off - 16:cd_off] == MAGIC:
        raise ValueError("APK already has a signing block")
    entries = data[:cd_off]
    cd = data[cd_off:cd_off + cd_size]
    eocd = data[eocd_off:]

    key = serialization.load_pem_private_key(open(key_path, "rb").read(), password=None)
    cert_der = open(cert_path, "rb").read()
    pub = key.public_key().public_bytes(serialization.Encoding.DER,
                                        serialization.PublicFormat.SubjectPublicKeyInfo)

    # digest: EOCD's CD-offset field must point at the signing block start
    # (= original CD offset) when digesting
    digest = chunk_digest([entries, cd, eocd])
    digests = lp(lp(struct.pack("<I", ALG_RSA_PKCS1_SHA256) + lp(digest)))
    certs = lp(lp(cert_der))
    signed_data = digests + certs + lp(b"")
    sig = key.sign(signed_data, padding.PKCS1v15(), hashes.SHA256())
    signatures = lp(lp(struct.pack("<I", ALG_RSA_PKCS1_SHA256) + lp(sig)))
    signer = lp(signed_data) + signatures + lp(pub)
    v2_value = lp(lp(signer))

    pair = struct.pack("<Q", 4 + len(v2_value)) + struct.pack("<I", V2_BLOCK_ID) + v2_value
    block_size = len(pair) + 8 + 16
    block = struct.pack("<Q", block_size) + pair + struct.pack("<Q", block_size) + MAGIC

    new_cd_off = cd_off + len(block)
    new_eocd = eocd[:16] + struct.pack("<I", new_cd_off) + eocd[20:]
    open(dst, "wb").write(entries + block + cd + new_eocd)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--genkey", nargs=2, metavar=("KEY_PEM", "CERT_DER"))
    ap.add_argument("src", nargs="?")
    ap.add_argument("dst", nargs="?")
    ap.add_argument("--key")
    ap.add_argument("--cert")
    a = ap.parse_args()
    if a.genkey:
        genkey(*a.genkey)
        return 0
    if not (a.src and a.dst and a.key and a.cert):
        ap.error("src, dst, --key and --cert are required")
    sign(a.src, a.dst, a.key, a.cert)
    return 0


if __name__ == "__main__":
    sys.exit(main())
