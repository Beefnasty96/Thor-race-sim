#!/usr/bin/env python3
"""Probe public-domain NHTSA sources for factory tire sizes (prints what's there)."""
import io, re, sys, urllib.request, zipfile

def get(url, binary=False):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (racing-sim data probe)"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    return data if binary else data.decode("latin-1")

def links(url):
    try:
        html = get(url)
    except Exception as e:
        print("  ERR", url, e); return []
    found = sorted(set(re.findall(r'href="([^"]+)"', html)))
    return [l for l in found if "nhtsa/downloads" in l or l.lower().endswith((".zip", ".csv", ".txt", ".sas7bdat", ".pdf"))]

for folder in ["NASS/TPS/", "NASS/TPMS-SS/", "NASS/"]:
    u = "https://www.nhtsa.gov/file-downloads?p=nhtsa/downloads/" + folder
    print("==", u)
    for l in links(u)[:60]:
        print("  ", l)

def peek_zip(url, label):
    print("==", label, url)
    try:
        z = zipfile.ZipFile(io.BytesIO(get(url, True)))
    except Exception as e:
        print("  ERR", e); return
    for n in z.namelist()[:40]:
        info = z.getinfo(n)
        print("  file", n, info.file_size)
        if n.lower().endswith((".txt", ".csv", ".asc", ".exp")) or "." not in n:
            with z.open(n) as f:
                head = f.read(1500).decode("latin-1", "replace")
            print("    ", head.replace("\n", "\n     ")[:1500])

peek_zip("https://www-nrd.nhtsa.dot.gov/database/VSR/Download.aspx?tstno=&curno=&database=v&name=Vehdb-export&format=export", "crash test vehicle db export")
