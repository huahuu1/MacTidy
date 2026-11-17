#!/usr/bin/env python3
"""Kiểm tra bản dịch: so khoá trích từ code (file .stringsdata) với Localization/en.json.
Dùng: python3 scripts/l10n_check.py <thư mục .stringsdata>"""
import json, glob, sys, re
keys = set()
for f in glob.glob(sys.argv[1] + "/*.stringsdata"):
    for tbl in json.load(open(f)).get("tables", {}).values():
        keys.update(e["key"] for e in tbl)
en = json.load(open("Localization/en.json"))
spec = re.compile(r'%(?:\d+\$)?(?:lld|ld|d|@|lf|f|%)')
need = sorted(k for k in keys if re.search(r'[A-Za-zÀ-ỹđĐ]', k) and k not in en
              and re.search(r'[À-ỹđĐ]', k))
bad = [k for k, v in en.items() if sorted(spec.findall(k)) != sorted(spec.findall(v))]
unused = sorted(k for k in en if k not in keys)
for k in need: print("CHƯA DỊCH:", k)
for k in bad: print("SAI %:", k, "->", en[k])
for k in unused: print("THỪA:", k)
sys.exit(1 if need or bad else 0)
