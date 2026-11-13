#!/usr/bin/env python3
import argparse

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers.ftps.control import TLS_FTPHandler
from pyftpdlib.servers import FTPServer


class ImplicitTLSHandler(TLS_FTPHandler):
    tls_control_required = True
    tls_data_required = True

    def handle(self):
        if not self._ssl_requested:
            self.secure_connection(self.ssl_context)
        super().handle()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    authorizer = DummyAuthorizer()
    authorizer.add_user(args.username, args.password, args.root, perm="elradfmwMT")
    ImplicitTLSHandler.authorizer = authorizer
    ImplicitTLSHandler.certfile = args.certificate
    ImplicitTLSHandler.keyfile = args.key
    FTPServer((args.host, args.port), ImplicitTLSHandler).serve_forever()


if __name__ == "__main__":
    main()
