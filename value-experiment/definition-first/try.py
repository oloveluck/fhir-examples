"""Start this directory's server and send it the example requests: the implementer's own check.

    python3 try.py              every request of examples/
    python3 try.py FILE...      those requests

For each request it prints the status and the body the server answers. It scores nothing: there
are no expected answers here. The server is started as start.json says, on a free port, and
stopped afterwards; what it prints goes to server.log.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "start.json")) as f:
    start = json.load(f)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def up(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
        return True
    except OSError:
        return False


def main():
    port = free_port()
    command = [a.replace("{port}", str(port)) for a in start["command"]]
    log_path = os.path.join(here, "server.log")
    with open(log_path, "w") as log:
        server = subprocess.Popen(command, cwd=here, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        deadline = time.time() + 120
        while time.time() < deadline and server.poll() is None and not up(port):
            time.sleep(0.2)
        if not up(port):
            print("the server did not start: %s" % " ".join(command))
            with open(log_path) as log:
                print(log.read()[-4000:])
            return 1
        files = sys.argv[1:] or sorted(os.path.join(here, "examples", n) for n in os.listdir(os.path.join(here, "examples")))
        for name in files:
            with open(name, "rb") as f:
                body = f.read()
            request = urllib.request.Request("http://127.0.0.1:%d/$%s" % (port, start["code"]), data=body,
                                             headers={"Content-Type": "application/fhir+json"}, method="POST")
            try:
                with urllib.request.urlopen(request, timeout=30) as answer:
                    status, text = answer.status, answer.read()
            except urllib.error.HTTPError as e:
                status, text = e.code, e.read()
            except Exception as e:
                status, text = "no answer", str(e).encode()
            print("== %s -> %s" % (os.path.basename(name), status))
            print(text.decode("utf-8", "replace")[:3000])
        return 0
    finally:
        try:
            os.killpg(server.pid, signal.SIGKILL)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
