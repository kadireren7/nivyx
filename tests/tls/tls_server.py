#!/usr/bin/env python3
"""Local TLS endpoint for scripts/tls-verify-test.sh.

    tls_server.py CERT KEY PORTFILE

Listens on 127.0.0.1 (a free port, written to PORTFILE once listening),
serves CERT (+ chain in the same file) to every client, answers any
request with a fixed HTTP response and closes. One thread per
connection, so concurrent clients are served concurrently. Test fixture
only: loopback, no real certificates, no external network.
"""
import socket
import ssl
import sys
import threading

cert, key, portfile = sys.argv[1], sys.argv[2], sys.argv[3]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.load_cert_chain(cert, key)

lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
lsock.bind(("127.0.0.1", 0))
lsock.listen(128)
with open(portfile + ".tmp", "w") as f:
    f.write(str(lsock.getsockname()[1]))
import os
os.replace(portfile + ".tmp", portfile)


def serve(conn):
    conn.settimeout(10)
    try:
        with ctx.wrap_socket(conn, server_side=True) as tls:
            data = b""
            while b"\r\n\r\n" not in data and len(data) < 8192:
                chunk = tls.recv(4096)
                if not chunk:
                    return
                data += chunk
            tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
                        b"Connection: close\r\n\r\nok")
    except (OSError, ssl.SSLError):
        # clients that reject the certificate abort the handshake: expected
        pass
    finally:
        conn.close()


while True:
    c, _ = lsock.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
