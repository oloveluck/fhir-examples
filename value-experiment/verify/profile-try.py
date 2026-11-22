"""try.py — run validator.py over resources and print what it answers.

    python3 try.py                 every resource of sample/
    python3 try.py --cases DIR     every .json file of DIR
    python3 try.py FILE.json …     the files named

One line a resource: its file's name, then valid, invalid, or ERROR and the exception.
"""
import importlib.util
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))


def files(args):
    if not args:
        args = ["--cases", os.path.join(here, "sample")]
    found = []
    i = 0
    while i < len(args):
        if args[i] == "--cases":
            d = args[i + 1]
            found += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".json")]
            i += 2
        else:
            found.append(args[i])
            i += 1
    return found


spec = importlib.util.spec_from_file_location("validator", os.path.join(here, "validator.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

for f in files(sys.argv[1:]):
    name = os.path.basename(f)[: -len(".json")]
    try:
        with open(f) as fh:
            answer = module.valid(json.load(fh))
        line = "%s %s" % (name, "valid" if answer else "invalid")
    except BaseException as e:
        line = "%s ERROR %s: %s" % (name, type(e).__name__, e)
    try:
        print(line, flush=True)
    except BrokenPipeError:  # the reader (head) has what it wanted
        os._exit(0)
