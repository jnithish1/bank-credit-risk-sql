"""
make_sample.py - builds a referentially consistent ~10% sample of the Berka
dataset in data/sample/ so CI (and anyone without the full 70 MB download)
can run the entire pipeline in seconds.

Sampling unit is the ACCOUNT: every client, disposition, card, loan, order
and transaction belonging to a sampled account is kept, so all foreign keys
still resolve. Districts are kept in full (reference data).

    python scripts/make_sample.py            # default: every 10th account
"""
from pathlib import Path
import csv
import sys

ROOT = Path(__file__).resolve().parents[1]
RAW, OUT = ROOT / "data" / "raw", ROOT / "data" / "sample"
EVERY_NTH = int(sys.argv[1]) if len(sys.argv) > 1 else 10


def filter_file(name, keep, key_col=None, key_set=None, collect=None):
    """Stream a semicolon CSV, write rows passing `keep`, optionally collect a column."""
    collected = set()
    with open(RAW / name, newline="") as src, open(OUT / name, "w", newline="") as dst:
        reader = csv.reader(src, delimiter=";")
        writer = csv.writer(dst, delimiter=";", quoting=csv.QUOTE_MINIMAL)
        header = next(reader)
        writer.writerow(header)
        idx = {c: i for i, c in enumerate(header)}
        for row in reader:
            if keep(row, idx):
                writer.writerow(row)
                if collect:
                    collected.add(row[idx[collect]])
    return collected


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    accounts = filter_file("account.csv",
                           lambda r, i: int(r[i["account_id"]]) % EVERY_NTH == 0,
                           collect="account_id")
    clients = filter_file("disp.csv", lambda r, i: r[i["account_id"]] in accounts,
                          collect="client_id")
    disps = filter_file("disp.csv", lambda r, i: r[i["account_id"]] in accounts,
                        collect="disp_id")
    filter_file("client.csv", lambda r, i: r[i["client_id"]] in clients)
    filter_file("card.csv", lambda r, i: r[i["disp_id"]] in disps)
    for f in ("loan.csv", "order.csv", "trans.csv"):
        filter_file(f, lambda r, i: r[i["account_id"]] in accounts)
    (OUT / "district.csv").write_bytes((RAW / "district.csv").read_bytes())
    print(f"Sample written to {OUT} ({len(accounts)} accounts)")


if __name__ == "__main__":
    main()
