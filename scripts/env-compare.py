#!/usr/bin/env python3
"""Compare local env files with the "dotenv *" documents in a 1Password vault.

Prints, per file, the closest document and which KEY NAMES differ. Never prints values.
  env-compare.py FILE...                       report only
  env-compare.py --delete-identical FILE...    also delete files identical to a document
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from envlib import op, op_json, parse  # noqa: E402

VAULT = "Gistrec Cloud"


def main(argv):
    delete = "--delete-identical" in argv
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        sys.exit(__doc__)
    docs = {}
    for item in op_json("item", "list", "--vault", VAULT, "--categories", "Document"):
        if item["title"].startswith("dotenv "):
            docs[item["title"]] = parse(op("document", "get", item["id"], "--vault", VAULT))
    print(f"loaded {len(docs)} dotenv documents from {VAULT}\n")
    for path in files:
        local = parse(open(path, encoding="utf-8").read())

        def score(doc):
            same = sum(1 for k in local if doc.get(k) == local[k])
            return same - abs(len(doc) - len(local)) * 0.01

        best = max(docs, key=lambda t: score(docs[t])) if docs else None
        doc = docs.get(best, {})
        changed = sorted(k for k in local if k in doc and doc[k] != local[k])
        only_local = sorted(k for k in local if k not in doc)
        only_doc = sorted(k for k in doc if k not in local)
        identical = not changed and not only_local and not only_doc
        print(f"{path}: {len(local)} keys -> closest '{best}'")
        if identical:
            print("  IDENTICAL")
        else:
            print(f"  same values: {sum(1 for k in local if doc.get(k) == local[k])}")
            if changed:
                print(f"  different values: {', '.join(changed)}")
            if only_local:
                print(f"  only in local file: {', '.join(only_local)}")
            if only_doc:
                print(f"  only in 1Password: {', '.join(only_doc)}")
        if identical and delete:
            os.remove(path)
            print("  deleted (identical copy is in 1Password)")
        print()


if __name__ == "__main__":
    main(sys.argv[1:])
