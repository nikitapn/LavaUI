#!/usr/bin/env python3
"""FTP, explicit FTPS and SFTP over one folder, for Tests/LavaRemoteTests.

    python3 -m venv /tmp/lava-remote-venv
    /tmp/lava-remote-venv/bin/pip install pyftpdlib pyopenssl asyncssh
    /tmp/lava-remote-venv/bin/python tools/remote_test_servers.py /tmp/lava-remote

serves /tmp/lava-remote/root (made, with a few files, if missing) as user
`alice`, password `secret`, on 127.0.0.1: FTP on 2121, FTPS on 2122 and SFTP on
2222 — anonymous FTP too. SFTP also takes the key `certs/client_key`, and not
`certs/decoy_key`, which is there to be refused. The FTPS certificate, the SSH
host key and both client keys are made in /tmp/lava-remote/certs. Then, in
another shell:

    LAVA_REMOTE_TEST_ROOT=/tmp/lava-remote/root \\
    LAVA_REMOTE_TEST_CA=/tmp/lava-remote/certs/cert.pem \\
        swift test --filter LavaRemoteTests

Each server is its own process: pyftpdlib's event loop is global, and two FTP
servers on threads of one process trample each other's connections.
Ctrl+C stops all three.
"""
import asyncio
import os
import subprocess
import sys


def certificates(certdir):
    os.makedirs(certdir, exist_ok=True)
    cert, key = os.path.join(certdir, "cert.pem"), os.path.join(certdir, "key.pem")
    if not os.path.exists(cert):
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
             "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
             "-keyout", key, "-out", cert],
            check=True, capture_output=True)
    return cert, key


def ftp(mode, root, port, certdir):
    from pyftpdlib.authorizers import DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
    from pyftpdlib.servers import FTPServer

    auth = DummyAuthorizer()
    auth.add_user("alice", "secret", root, perm="elradfmwMT")
    auth.add_anonymous(root)

    class Handler(TLS_FTPHandler if mode == "ftps" else FTPHandler):
        pass

    if mode == "ftps":
        Handler.certfile, Handler.keyfile = certificates(certdir)
        Handler.tls_control_required = Handler.tls_data_required = True
    Handler.authorizer = auth
    # Ten each, so 2121 and 2122 (21210… and 21220…) do not overlap.
    Handler.passive_ports = range(port * 10, port * 10 + 10)
    FTPServer(("127.0.0.1", port), Handler).serve_forever()


def sftp(root, port, certdir):
    import asyncssh

    os.makedirs(certdir, exist_ok=True)
    keys = {}
    for name in ("ssh_host_key", "client_key", "decoy_key"):
        path = os.path.join(certdir, name)
        if not os.path.exists(path):
            key = asyncssh.generate_private_key("ssh-ed25519")
            key.write_private_key(path)
            key.write_public_key(path + ".pub")
            os.chmod(path, 0o600)
        keys[name] = path
    hostkey = keys["ssh_host_key"]

    class Server(asyncssh.SSHServer):
        def begin_auth(self, username):
            return True

        def password_auth_supported(self):
            return True

        def validate_password(self, username, password):
            return username == "alice" and password == "secret"

    class Root(asyncssh.SFTPServer):
        def __init__(self, chan):
            super().__init__(chan, chroot=root)

    async def main():
        await asyncssh.create_server(
            Server, "127.0.0.1", port, server_host_keys=[hostkey], sftp_factory=Root,
            authorized_client_keys=keys["client_key"] + ".pub")
        await asyncio.Future()

    asyncio.run(main())


def seed(root):
    if os.path.exists(root):
        return
    os.makedirs(os.path.join(root, "docs"))
    os.makedirs(os.path.join(root, "My Folder"))
    with open(os.path.join(root, "docs", "hello.txt"), "w") as f:
        f.write("hello\n")
    with open(os.path.join(root, "big.bin"), "wb") as f:
        f.write(os.urandom(300_000))
    with open(os.path.join(root, ".secret"), "w") as f:
        f.write("hidden\n")


if __name__ == "__main__":
    if len(sys.argv) == 5:  # one server: MODE ROOT PORT CERTDIR
        mode, root, port, certdir = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
        if mode == "sftp":
            sftp(root, port, certdir)
        else:
            ftp(mode, root, port, certdir)
        sys.exit(0)
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    base = sys.argv[1]
    root, certdir = os.path.join(base, "root"), os.path.join(base, "certs")
    seed(root)
    certificates(certdir)
    children = [subprocess.Popen([sys.executable, __file__, mode, root, str(port), certdir])
                for mode, port in (("ftp", 2121), ("ftps", 2122), ("sftp", 2222))]
    print("serving", root, "— ftp 2121, ftps 2122, sftp 2222 (alice/secret)", flush=True)
    try:
        for child in children:
            child.wait()
    except KeyboardInterrupt:
        for child in children:
            child.terminate()
