#!/usr/bin/env python3
"""Sign local builds with one persistent, private, self-signed identity.

No Apple account, trust-store modification, TCC access, or application launch.
The build-only keychain is discoverable only while codesign is running.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import stat
import subprocess
import tempfile


def run(label, arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=60)
    if result.returncode:
        # Do not include argv: some security commands require a generated
        # keychain password as an argument. It is never a user's login password.
        raise RuntimeError(f"{label}: {result.stdout.strip()}")
    return result.stdout.strip()


def keychains():
    return shlex.split(run("Read keychain search list",
                          ["/usr/bin/security", "list-keychains", "-d", "user"]))


def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError("Local signing files must be regular, owner-only files.")


def create_identity(state):
    state.mkdir(mode=0o700)
    keychain = state / "identity.keychain-db"
    password = secrets.token_hex(32)
    (state / "keychain-password").write_text(password, encoding="utf-8")
    try:
        with tempfile.TemporaryDirectory(prefix=".create-", dir=state) as temporary:
            work = Path(temporary)
            (work / "certificate.cnf").write_text(
                "[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=code\n"
                "[dn]\nCN=AppSweep Local Development\n"
                "[code]\nbasicConstraints=critical,CA:FALSE\n"
                "keyUsage=critical,digitalSignature\n"
                "extendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n",
                encoding="utf-8")
            run("Create local certificate", ["/usr/bin/openssl", "req", "-x509",
                "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-sha256",
                "-config", str(work / "certificate.cnf"), "-keyout", str(work / "key.pem"),
                "-out", str(state / "certificate.pem")])
            run("Prepare local identity", ["/usr/bin/openssl", "pkcs12", "-export",
                "-inkey", str(work / "key.pem"), "-in", str(state / "certificate.pem"),
                "-out", str(work / "identity.p12"), "-passout",
                "file:" + str(state / "keychain-password")])
            run("Create build keychain", ["/usr/bin/security", "create-keychain", "-p", password, str(keychain)])
            run("Unlock build keychain", ["/usr/bin/security", "unlock-keychain", "-p", password, str(keychain)])
            run("Import local signing key", ["/usr/bin/security", "import", str(work / "identity.p12"),
                "-k", str(keychain), "-P", password, "-x", "-T", "/usr/bin/codesign"])
            run("Set build key access", ["/usr/bin/security", "set-key-partition-list",
                "-S", "apple-tool:,apple:", "-s", "-k", password, str(keychain)])
            run("Set build keychain timeout", ["/usr/bin/security", "set-keychain-settings", "-lut", "300", str(keychain)])
        fingerprint = run("Read signing fingerprint", ["/usr/bin/openssl", "x509",
            "-in", str(state / "certificate.pem"), "-noout", "-fingerprint", "-sha1"])
        identity = fingerprint.split("=")[-1].replace(":", "").strip()
        if len(identity) != 40 or any(c not in "0123456789ABCDEFabcdef" for c in identity):
            raise RuntimeError("Invalid local certificate fingerprint.")
        (state / "identity.json").write_text(json.dumps({"version": 1, "sha1": identity}) + "\n", encoding="utf-8")
        for name in ("identity.keychain-db", "keychain-password", "certificate.pem", "identity.json"):
            (state / name).chmod(0o600)
    except Exception:
        # Only remove a brand-new identity that was not yet used for a build.
        if keychain.exists():
            run("Remove incomplete build keychain", ["/usr/bin/security", "delete-keychain", str(keychain)])
        shutil.rmtree(state)
        raise


def sign(app, state):
    if state.is_symlink():
        raise RuntimeError("Local signing directory must not be a symbolic link.")
    # security canonicalizes /var to /private/var. Use the same spelling for
    # creation, discovery and cleanup so no temporary search entry is left.
    state = state.resolve()
    state.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = state.parent / (state.name + ".lock")
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not state.exists():
            create_identity(state)
        info = state.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError("Local signing directory must be owned by the current user with mode 700.")
        for name in ("identity.keychain-db", "keychain-password", "certificate.pem", "identity.json"):
            private_file(state / name)
        metadata = json.loads((state / "identity.json").read_text(encoding="utf-8"))
        if metadata.get("version") != 1:
            raise RuntimeError("Unknown local signing identity format; existing identity was preserved.")
        fingerprint = run("Read signing fingerprint", ["/usr/bin/openssl", "x509",
            "-in", str(state / "certificate.pem"), "-noout", "-fingerprint", "-sha1"])
        if metadata.get("sha1") != fingerprint.split("=")[-1].replace(":", "").strip():
            raise RuntimeError("Local certificate identity changed; existing state was preserved.")
        run("Check local certificate expiration", ["/usr/bin/openssl", "x509",
            "-in", str(state / "certificate.pem"), "-checkend", "0", "-noout"])
        password = (state / "keychain-password").read_text(encoding="utf-8")
        keychain = str(state / "identity.keychain-db")
        previous_search = keychains()
        added = not any(str(Path(p).resolve()) == keychain for p in previous_search)
        try:
            run("Unlock build keychain", ["/usr/bin/security", "unlock-keychain", "-p", password, keychain])
            if added:
                run("Make build identity discoverable", ["/usr/bin/security", "list-keychains",
                    "-d", "user", "-s", *previous_search, keychain])
            run("Sign local application", ["/usr/bin/codesign", "--force", "--sign", metadata["sha1"],
                "--keychain", keychain, "--timestamp=none", str(app)])
        finally:
            try:
                if added:
                    # Preserve unrelated entries added by other processes.
                    current_search = keychains()
                    remaining = [p for p in current_search if str(Path(p).resolve()) != keychain]
                    if len(remaining) != len(current_search):
                        run("Remove build search entry", ["/usr/bin/security", "list-keychains",
                            "-d", "user", "-s", *remaining])
            finally:
                run("Lock build keychain", ["/usr/bin/security", "lock-keychain", keychain])
        print("Signed with the persistent local development identity (no Apple account required).")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--state-dir", type=Path, default=Path(os.environ.get(
        "LOCAL_SIGNING_DIR", str(Path.home() / "Library/Application Support/AppSweep Build/Signing"))))
    args = parser.parse_args()
    if args.app.is_symlink() or not (args.app / "Contents/Info.plist").is_file():
        parser.error("Expected a local application bundle.")
    try:
        sign(args.app.resolve(), args.state_dir.absolute())
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        # A timeout exception includes argv; do not print it.
        message = "Local signing command timed out." if isinstance(error, subprocess.TimeoutExpired) else str(error)
        parser.exit(1, message + "\nExisting signing state is preserved; do not delete it to retry.\n")


if __name__ == "__main__":
    main()
