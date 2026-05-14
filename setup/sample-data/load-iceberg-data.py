#!/usr/bin/env python3
"""
Load Iceberg sample data via Hive staging.

For each domain's generated_data/iceberg/*.parquet file:
  1. Upload the file into watsonx.data's MinIO (the `hive-bucket`)
  2. Register a Hive external table over it in hive_data.staging
  3. INSERT INTO iceberg_data.<domain>.<table> SELECT (with type casts)
     FROM hive_data.staging.<table>
  4. Drop the Hive staging table

One INSERT per Iceberg table; the whole thing runs in a single presto-cli
invocation so we pay the CLI+container startup cost once, not per table.

Requires: pyarrow (for reading parquet schemas), podman (to reach MinIO),
and a working watsonx.data with cassandra_catalog/iceberg_data/hive_data.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pyarrow.parquet as pq


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SAMPLE_DIR = Path(__file__).resolve().parent
PRESTO_CLI = REPO_ROOT / ".watsonx-data" / "ibm-lh-dev" / "bin" / "presto-cli"

MINIO_CONTAINER = "ibm-lh-minio"
MINIO_BUCKET = "hive-bucket"


def _detect_podman_conn() -> str | None:
    """Find the podman connection that can see the wxd containers.

    On macOS, `podman machine init --rootful watsonx-workshop` creates two
    connections (`watsonx-workshop` rootless, `watsonx-workshop-root` rootful);
    wxd lives in the rootful one. On Linux/WSL2 there is no machine and no
    named connection — `podman` talks directly to the local socket. Probe in
    preference order: rootful machine → rootless machine → bare podman (None).
    """
    try:
        out = subprocess.run(
            ["podman", "system", "connection", "list", "--format", "{{.Name}}"],
            check=False, text=True, capture_output=True,
        ).stdout.split()
    except Exception:
        out = []
    for cand in ("watsonx-workshop-root", "watsonx-workshop"):
        if cand in out:
            return cand
    return None  # native Linux / WSL2: no connections, default socket only


MINIO_CONN = _detect_podman_conn()
# MinIO credentials are generated per install (by ibm-lh-dev/bin/setup).
# Read them from the running container's env rather than hard-coding.
STAGING_PREFIX = "staging"             # hive-bucket/staging/<domain>/<table>/data.parquet

HIVE_SCHEMA = "hive_data.staging"

DEFAULT_DOMAINS = ["ecommerce", "iot", "financial"]


# ---------------------------------------------------------------------------
# Type mapping
# ---------------------------------------------------------------------------
def pa_to_hive_type(ptype) -> str:
    """Map a pyarrow type to a Presto/Hive DDL type used in the staging table."""
    s = str(ptype)
    if s == "string":                  return "VARCHAR"
    if s == "bool":                    return "BOOLEAN"
    if s.startswith("int32"):          return "INTEGER"
    if s.startswith("int64"):          return "BIGINT"
    if s.startswith("float") or s.startswith("double"):
                                       return "DOUBLE"
    if s.startswith("date"):           return "DATE"
    if s.startswith("timestamp"):      return "TIMESTAMP"
    raise RuntimeError(f"unsupported parquet type: {s}")


# ---------------------------------------------------------------------------
# Podman / MinIO helpers
# ---------------------------------------------------------------------------
def _podman(*args, capture=False, check=True):
    cmd = ["podman"]
    if MINIO_CONN:
        cmd += ["--connection", MINIO_CONN]
    cmd += list(args)
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=capture,
    )


def _podman_exec(*args, capture=False, check=True):
    return _podman("exec", MINIO_CONTAINER, *args, capture=capture, check=check)


def _read_minio_credentials() -> tuple[str, str]:
    """Fetch the MinIO access/secret keys from the container's env.
    wxd writes LH_S3_ACCESS_KEY / LH_S3_SECRET_KEY at setup time — those are
    the keys bound to the hive-bucket + iceberg-bucket buckets we need to write to.
    """
    proc = _podman_exec(
        "sh", "-c", "printenv LH_S3_ACCESS_KEY; printenv LH_S3_SECRET_KEY",
        capture=True, check=False,
    )
    out = proc.stdout.strip().splitlines()
    if len(out) < 2 or not out[0] or not out[1]:
        raise RuntimeError(
            "Could not read LH_S3_ACCESS_KEY/LH_S3_SECRET_KEY from the "
            f"{MINIO_CONTAINER} container env. Is wxd up and started?"
        )
    return out[0].strip(), out[1].strip()


def ensure_minio_alias():
    """Set the mc alias inside the minio container; idempotent."""
    access_key, secret_key = _read_minio_credentials()
    _podman_exec(
        "mc", "alias", "set", "local",
        "http://localhost:9000", access_key, secret_key,
        capture=True, check=False,
    )


def upload_parquet_to_minio(host_path: Path, domain: str, table: str) -> str:
    """
    Copy host_path into the MinIO container, then mc-cp it into hive-bucket.
    Returns the s3a://... location (pointing at the directory, as Hive expects).
    """
    container_tmp = f"/tmp/wxd-load-{domain}-{table}.parquet"
    bucket_key = f"local/{MINIO_BUCKET}/{STAGING_PREFIX}/{domain}/{table}/data.parquet"
    s3a_dir = f"s3a://{MINIO_BUCKET}/{STAGING_PREFIX}/{domain}/{table}/"

    _podman("cp", str(host_path), f"{MINIO_CONTAINER}:{container_tmp}")
    _podman_exec("mc", "rm", "--recursive", "--force",
                 f"local/{MINIO_BUCKET}/{STAGING_PREFIX}/{domain}/{table}/",
                 capture=True, check=False)
    _podman_exec("mc", "cp", container_tmp, bucket_key, capture=True)
    _podman_exec("rm", "-f", container_tmp, capture=True, check=False)
    return s3a_dir


# ---------------------------------------------------------------------------
# Presto schema queries — batched
# ---------------------------------------------------------------------------
def _parse_csv_row(line: str) -> list[str]:
    """Parse a presto-cli CSV output row: "v1","v2","v3" -> [v1, v2, v3]."""
    out = []
    i = 0
    n = len(line)
    while i < n:
        if line[i] == '"':
            j = i + 1
            # Handle escaped quotes ("")
            buf = []
            while j < n:
                if line[j] == '"':
                    if j + 1 < n and line[j+1] == '"':
                        buf.append('"')
                        j += 2
                        continue
                    break
                buf.append(line[j])
                j += 1
            out.append("".join(buf))
            i = j + 1
            if i < n and line[i] == ',':
                i += 1
        else:
            # Skip unexpected chars
            i += 1
    return out


def fetch_all_iceberg_schemas(domains: list[str]) -> dict[tuple[str, str], list[tuple[str, str]]]:
    """
    One presto-cli round trip gets every target column for every table across
    all requested domains. Returns {(domain, table): [(col, type), ...]}
    ordered by ordinal_position.
    """
    if not domains:
        return {}
    schemas_in = ", ".join(f"'{d}'" for d in domains)
    sql = (
        "SELECT table_schema, table_name, column_name, data_type, ordinal_position "
        "FROM iceberg_data.information_schema.columns "
        f"WHERE table_schema IN ({schemas_in}) "
        "ORDER BY table_schema, table_name, ordinal_position"
    )
    out = _run_presto(sql, capture=True)
    result: dict[tuple[str, str], list[tuple[str, str]]] = {}
    for raw in out.splitlines():
        raw = raw.strip()
        if not raw or not raw.startswith('"'):
            continue
        parts = _parse_csv_row(raw)
        if len(parts) < 4:
            continue
        schema, table, colname, dtype = parts[0], parts[1], parts[2], parts[3]
        result.setdefault((schema, table), []).append((colname, dtype))
    return result


# ---------------------------------------------------------------------------
# SQL emission
# ---------------------------------------------------------------------------
def build_statements(domain: str, parquet_path: Path, s3a_dir: str,
                      iceberg_cols: list[tuple[str, str]]) -> list[str]:
    table = parquet_path.stem
    parquet_schema = pq.read_schema(str(parquet_path))
    parquet_cols = [(f.name, pa_to_hive_type(f.type)) for f in parquet_schema]

    staging_fqn = f"{HIVE_SCHEMA}.{domain}__{table}"
    target_fqn = f"iceberg_data.{domain}.{table}"

    col_defs = ", ".join(f"{n} {t}" for (n, t) in parquet_cols)

    if not iceberg_cols:
        raise RuntimeError(f"no iceberg columns found for {target_fqn}")
    iceberg_names = {n for (n, _) in iceberg_cols}
    parquet_names = {n for (n, _) in parquet_cols}
    missing = iceberg_names - parquet_names
    if missing:
        raise RuntimeError(f"{target_fqn}: parquet is missing columns {missing}")

    select_list = ", ".join(f"CAST({n} AS {t}) AS {n}" for (n, t) in iceberg_cols)
    col_list = ", ".join(n for (n, _) in iceberg_cols)

    return [
        f"DROP TABLE IF EXISTS {staging_fqn}",
        f"CREATE TABLE {staging_fqn} ({col_defs}) "
        f"WITH (format = 'PARQUET', external_location = '{s3a_dir}')",
        f"INSERT INTO {target_fqn} ({col_list}) "
        f"SELECT {select_list} FROM {staging_fqn}",
        f"DROP TABLE {staging_fqn}",
    ]


# ---------------------------------------------------------------------------
# Presto runner
# ---------------------------------------------------------------------------
def _run_presto(statement: str, capture: bool = False) -> str:
    env = {**os.environ, "LH_SANDBOX_DIR": str(REPO_ROOT)}
    proc = subprocess.run(
        [str(PRESTO_CLI), "--execute", statement],
        env=env, text=True, capture_output=True, check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise RuntimeError(f"presto-cli failed: {statement[:120]}")
    return proc.stdout


def run_presto_file(sql_path: Path) -> int:
    env = {**os.environ, "LH_SANDBOX_DIR": str(REPO_ROOT)}
    proc = subprocess.run(
        [str(PRESTO_CLI), "--file", str(sql_path)],
        env=env, text=True, check=False,
    )
    return proc.returncode


def ensure_default_podman_connection():
    """Make sure the rootful connection is default; otherwise presto-cli can't reach wxd.

    No-op on native Linux / WSL2 — there are no named connections, the local
    socket is the only thing podman talks to.
    """
    if not MINIO_CONN:
        return
    subprocess.run(
        ["podman", "system", "connection", "default", MINIO_CONN],
        capture_output=True, text=True, check=False,
    )


def ensure_hive_schema():
    _run_presto(
        "CREATE SCHEMA IF NOT EXISTS hive_data.staging "
        f"WITH (location = 's3a://{MINIO_BUCKET}/{STAGING_PREFIX}/')"
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def _domain_parquet_files(domain: str) -> list[Path]:
    iceberg_dir = SAMPLE_DIR / domain / "generated_data" / "iceberg"
    if not iceberg_dir.is_dir():
        return []
    return sorted(iceberg_dir.glob("*.parquet"))


def load_domain(domain: str, schema_map: dict) -> int:
    parquet_files = _domain_parquet_files(domain)
    if not parquet_files:
        print(f"[{domain}] no .parquet files — skipping")
        return 0

    print(f"── {domain} ({len(parquet_files)} tables) ──", flush=True)
    t0 = time.time()

    all_statements: list[str] = []
    for pq_path in parquet_files:
        table = pq_path.stem
        u0 = time.time()
        s3a_dir = upload_parquet_to_minio(pq_path, domain, table)
        iceberg_cols = schema_map.get((domain, table), [])
        all_statements.extend(build_statements(domain, pq_path, s3a_dir, iceberg_cols))
        print(f"  [{domain}] upload {pq_path.name} ({time.time() - u0:.1f}s)", flush=True)

    # Write combined SQL to a domain-specific file and execute in one presto-cli call.
    sql_path = REPO_ROOT / f".iceberg-load-{domain}.sql"
    sql_path.write_text(";\n".join(all_statements) + ";\n")
    print(f"  [{domain}] running {len(all_statements)} SQL statements...", flush=True)
    r = run_presto_file(sql_path)
    sql_path.unlink(missing_ok=True)
    elapsed = time.time() - t0
    status = "✓" if r == 0 else "✗"
    print(f"  [{domain}] {status} loaded in {elapsed:.1f}s", flush=True)
    return r


def main(argv: list[str]) -> int:
    # Accept args like:  python load-iceberg-data.py [--serial] [domain ...]
    args = argv[1:]
    serial = False
    if args and args[0] == "--serial":
        serial = True
        args = args[1:]
    domains = args if args else DEFAULT_DOMAINS

    if not PRESTO_CLI.is_file():
        print(f"Presto CLI not found at {PRESTO_CLI} — run setup/install-workshop.sh first")
        return 1

    ensure_default_podman_connection()
    ensure_minio_alias()
    ensure_hive_schema()

    # Drop any domain whose generator hasn't run (nothing to load).
    domains = [d for d in domains if _domain_parquet_files(d)]
    if not domains:
        print("No domains have generated parquet files — run the generators first.")
        return 0

    overall_start = time.time()

    # Win 1: fetch every target-table schema in a single presto-cli round trip.
    print(f"Fetching Iceberg schemas for: {', '.join(domains)}")
    s0 = time.time()
    schema_map = fetch_all_iceberg_schemas(domains)
    print(f"  got {len(schema_map)} table schemas in {time.time() - s0:.1f}s\n")

    any_err = 0
    if serial or len(domains) == 1:
        for d in domains:
            if load_domain(d, schema_map) != 0:
                any_err = 1
    else:
        # Win 2: run the domain loaders concurrently. Each gets its own
        # presto-cli invocation; Presto handles concurrent sessions fine.
        from concurrent.futures import ThreadPoolExecutor, as_completed
        with ThreadPoolExecutor(max_workers=len(domains)) as pool:
            futures = {pool.submit(load_domain, d, schema_map): d for d in domains}
            for fut in as_completed(futures):
                d = futures[fut]
                try:
                    rc = fut.result()
                except Exception as exc:
                    print(f"[{d}] failed with exception: {exc}")
                    rc = 1
                if rc != 0:
                    any_err = 1

    total = time.time() - overall_start
    print()
    if any_err:
        print(f"Completed with errors in {total:.0f}s")
    else:
        print(f"✓ All domains loaded in {total:.0f}s")
    return any_err


if __name__ == "__main__":
    sys.exit(main(sys.argv))
