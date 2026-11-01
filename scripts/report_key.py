#!/usr/bin/env python3
"""The key that signs the reports of one version of the Mac program.

The master key (~/.config/nimb/report.key) never goes into the program: each version gets its own key, HMAC-SHA256(master, "nimb-key|" + version)
in hex letters, and the relay (report-relay/index.js, `versionKey`) makes the same key from the version a report names. A key taken out of one
release signs reports of that version only, and once the next version is out the relay turns that one away as not the latest.

  report_key.py derive KEYFILE VERSION        prints the key of that version
  report_key.py source KEYFILE VERSION FILE   writes it into the Swift file of the build, mixed with the version (see `ReportKey.unmixed`)
"""
import hashlib
import hmac
import sys


def version_key(master: str, version: str) -> str:
    return hmac.new(master.encode(), ("nimb-key|" + version).encode(), hashlib.sha256).hexdigest()


def main(argv: list) -> int:
    if len(argv) < 4 or argv[1] not in ("derive", "source") or (argv[1] == "source" and len(argv) != 5):
        print(__doc__, file=sys.stderr)
        return 2
    key = version_key(open(argv[2]).read().strip(), argv[3])
    if argv[1] == "derive":
        print(key)
    else:
        pad = argv[3].encode()
        mixed = [byte ^ pad[index % len(pad)] for index, byte in enumerate(key.encode())]
        open(argv[4], "w").write("#if OFFICIAL_BUILD\nlet officialReportKey: [UInt8] = [%s]\n#endif\n" % ", ".join(map(str, mixed)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
