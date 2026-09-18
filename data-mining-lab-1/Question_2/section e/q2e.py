import csv
import glob
import re
import time
from collections import defaultdict

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer

ROOT = Path(__file__).resolve().parent
NOTICES_DIR = ROOT / "notices"
LABELS_FILE = ROOT / "labelled_pairs.csv"

N_TABLES = 16
BITS_PER_TABLE = 8
MAX_FEATURES = 30000
SEED = 42

# Mitigation: suppress very heavy LSH buckets.
# This removes the pathological high-fanout buckets from candidate generation.
BUCKET_CAP = 80


def clean_text(title, body):
    text = (title or "") + " " + (body or "")
    text = text.lower()
    text = re.sub(
        r"\b(?:ref(?:erence)?|tender|nit|bid)[\s:/-]*[a-z0-9/-]{3,}\b",
        " ", text
    )
    text = re.sub(r"\b\d{1,4}[/-]\d{1,2}[/-]\d{2,4}\b", " ", text)
    for b in [
        "national procurement aggregation service",
        "state procurement cell"
    ]:
        text = text.replace(b, " ")
    return re.sub(r"\s+", " ", text).strip()


def load_notices():
    files = sorted(glob.glob(str(NOTICES_DIR / "part-*.csv")))
    rows = []
    for fn in files:
        with open(fn, "r", encoding="utf-8", errors="replace", newline="") as f:
            for r in csv.DictReader(f):
                rows.append(r)
    return rows


def make_lsh(texts):
    vectorizer = TfidfVectorizer(
        ngram_range=(1, 2),
        max_features=MAX_FEATURES,
        min_df=1
    )
    X = vectorizer.fit_transform(texts)
    rng = np.random.default_rng(SEED)
    planes = rng.standard_normal(
        (N_TABLES, BITS_PER_TABLE, X.shape[1])
    ).astype(np.float32)
    powers = 1 << np.arange(BITS_PER_TABLE, dtype=np.uint16)

    sig = np.empty((N_TABLES, X.shape[0]), dtype=np.uint16)
    for t in range(N_TABLES):
        bits = (X @ planes[t].T >= 0).astype(np.uint16)
        sig[t] = np.asarray(bits @ powers).reshape(-1)
    return sig


def build_bucket_maps(signatures, suppressed=None):
    maps = []
    sizes = []
    for t in range(N_TABLES):
        d = defaultdict(list)
        for i, b in enumerate(signatures[t]):
            b = int(b)
            if suppressed is None or (t, b) not in suppressed:
                d[b].append(i)
        maps.append(d)
        sizes.append({b: len(v) for b, v in d.items()})
    return maps, sizes


def candidate_pairs_and_work(signatures, suppressed=None):
    maps, sizes = build_bucket_maps(signatures, suppressed)
    n = signatures.shape[1]
    # Store undirected candidate pairs as uint64 encoded min*n+max.
    chunks = []
    raw_work = np.zeros(n, dtype=np.int64)

    for t in range(N_TABLES):
        for b, ids in maps[t].items():
            m = len(ids)
            if m < 2:
                continue
            arr = np.asarray(ids, dtype=np.int64)
            raw_work[arr] += (m - 1)
            if m * (m - 1) // 2:
                a, c = np.triu_indices(m, k=1)
                pairs = arr[a].astype(np.uint64) * np.uint64(n) + arr[c].astype(np.uint64)
                chunks.append(pairs)

    if not chunks:
        return np.empty(0, dtype=np.uint64), raw_work, maps, sizes

    all_pairs = np.concatenate(chunks)
    all_pairs = np.unique(all_pairs)
    return all_pairs, raw_work, maps, sizes


def pair_set_from_labels(filename):
    labels = []
    with open(filename, "r", encoding="utf-8", errors="replace", newline="") as f:
        for r in csv.DictReader(f):
            labels.append((r["notice_id_a"], r["notice_id_b"], r["label"]))
    return labels


def recall_on_labels(pair_array, notice_to_idx, labels):
    pairset = set(int(x) for x in pair_array)
    same = 0
    survived = 0
    total = 0
    for a, b, lab in labels:
        if lab != "same":
            continue
        total += 1
        ia = notice_to_idx.get(a)
        ib = notice_to_idx.get(b)
        if ia is None or ib is None:
            continue
        x, y = sorted((ia, ib))
        key = x * len(notice_to_idx) + y
        same += 1
        if key in pairset:
            survived += 1
    return survived / same if same else 0.0, survived, same


def summarize_work(raw_work, rows, label):
    vals = np.asarray(raw_work)
    portals = [r.get("portal_id", r.get("portal", "")) for r in rows]
    order = np.argsort(vals)[::-1]

    print(f"\n=== {label}: WORK DISTRIBUTION ===")
    print("Mean candidate work per notice:", f"{vals.mean():.2f}")
    print("Median:", f"{np.median(vals):.2f}")
    print("95th percentile:", f"{np.percentile(vals,95):.2f}")
    print("99th percentile:", f"{np.percentile(vals,99):.2f}")
    print("Maximum:", int(vals.max()))

    top_n = max(1, len(vals) // 20)  # top 5%
    top_share = vals[order[:top_n]].sum() / vals.sum() if vals.sum() else 0
    print("Top 5% share of work:", f"{top_share*100:.2f}%")

    by_portal = defaultdict(lambda: [0, 0])
    for i, p in enumerate(portals):
        by_portal[p][0] += int(vals[i])
        by_portal[p][1] += 1

    portal_order = sorted(
        by_portal.items(),
        key=lambda kv: kv[1][0],
        reverse=True
    )

    print("\nTop portals by candidate work:")
    print("portal, notices, work, work_share")
    total_work = vals.sum()
    for p, (w, cnt) in portal_order[:15]:
        share = 100*w/total_work if total_work else 0
        print(f"{p}, {cnt}, {w}, {share:.2f}%")

    print("\nTop 20 notices by work:")
    print("notice_id, portal, work")
    for i in order[:20]:
        print(f"{rows[i]['notice_id']}, {portals[i]}, {int(vals[i])}")


rows = load_notices()
notice_ids = [r["notice_id"] for r in rows]
notice_to_idx = {x:i for i,x in enumerate(notice_ids)}
texts = [clean_text(r.get("title",""), r.get("body","")) for r in rows]

print("Total notices:", len(rows))
print("Building baseline LSH...")
signatures = make_lsh(texts)

labels = pair_set_from_labels(LABELS_FILE)

# ---------------- BASELINE ----------------
start = time.perf_counter()
baseline_pairs, baseline_work, maps, sizes = candidate_pairs_and_work(signatures)
baseline_runtime = time.perf_counter() - start

baseline_recall, baseline_survived, baseline_same = recall_on_labels(
    baseline_pairs, notice_to_idx, labels
)

summarize_work(baseline_work, rows, "BASELINE")

print("\n=== BASELINE SUMMARY ===")
print("Unique candidate pairs:", len(baseline_pairs))
print("Candidate fraction:", f"{len(baseline_pairs)/(len(rows)*(len(rows)-1)/2)*100:.4f}%")
print("Labelled same-pair recall:", f"{baseline_recall*100:.2f}%")
print("Same labelled pairs retrieved:", f"{baseline_survived}/{baseline_same}")
print("Retrieval runtime:", f"{baseline_runtime:.3f} seconds")
print("Retrieval runtime:", f"{baseline_runtime/60:.2f} minutes")

# ---------------- FIND HEAVY BUCKETS ----------------
# A bucket creates m*(m-1)/2 work, so even a small number of large buckets
# can dominate the full-corpus cost.
bucket_records = []
for t in range(N_TABLES):
    for b, ids in maps[t].items():
        m = len(ids)
        if m > BUCKET_CAP:
            bucket_records.append((t, b, m, m*(m-1)//2))

bucket_records.sort(key=lambda x: x[2], reverse=True)
suppressed = {(t,b) for t,b,m,w in bucket_records}

print("\n=== HEAVY BUCKETS ===")
print("Bucket cap:", BUCKET_CAP)
print("Suppressed buckets:", len(suppressed))
print("Top heavy buckets:")
print("table, bucket, rows, pair_work")
for rec in bucket_records[:20]:
    print(rec)

# ---------------- MITIGATED ----------------
start = time.perf_counter()
mitigated_pairs, mitigated_work, maps2, sizes2 = candidate_pairs_and_work(
    signatures, suppressed
)
mitigated_runtime = time.perf_counter() - start

mitigated_recall, mitigated_survived, mitigated_same = recall_on_labels(
    mitigated_pairs, notice_to_idx, labels
)

summarize_work(mitigated_work, rows, "MITIGATED")

print("\n=== MITIGATED SUMMARY ===")
print("Unique candidate pairs:", len(mitigated_pairs))
print("Candidate fraction:", f"{len(mitigated_pairs)/(len(rows)*(len(rows)-1)/2)*100:.4f}%")
print("Labelled same-pair recall:", f"{mitigated_recall*100:.2f}%")
print("Same labelled pairs retrieved:", f"{mitigated_survived}/{mitigated_same}")
print("Retrieval runtime:", f"{mitigated_runtime:.3f} seconds")
print("Retrieval runtime:", f"{mitigated_runtime/60:.2f} minutes")

print("\n=== BEFORE / AFTER ===")
print("Runtime before:", f"{baseline_runtime:.3f} s")
print("Runtime after :", f"{mitigated_runtime:.3f} s")
if baseline_runtime:
    print("Runtime change:", f"{(1-mitigated_runtime/baseline_runtime)*100:.2f}% reduction")
print("Candidate pairs before:", len(baseline_pairs))
print("Candidate pairs after :", len(mitigated_pairs))
print("Recall before:", f"{baseline_recall*100:.2f}%")
print("Recall after :", f"{mitigated_recall*100:.2f}%")
print("Recall loss  :", f"{(baseline_recall-mitigated_recall)*100:.2f} percentage points")
print("\nQ2(e) complete. Paste the complete output here.")
