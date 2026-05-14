"""
Shared helpers for writing domain data as Parquet files.

The data generators (ecommerce / iot / financial) output one .parquet per
Iceberg target table into generated_data/iceberg/. The loader then stages each
file in the hive_data catalog and does a single INSERT INTO iceberg_data
SELECT FROM hive_data per table.

Parquet uses "safe" types (string / int64 / float64 / date / timestamp / bool)
regardless of the target Iceberg column type (e.g. DECIMAL). The loader
inspects the Iceberg target schema at load-time and emits a SELECT with
explicit CASTs, so we avoid encoding precision+scale information per column
in every generator.
"""
from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import pyarrow as pa
import pyarrow.parquet as pq


# Column-type hint codes used in the per-table schema definitions:
#   'str'   → VARCHAR
#   'int'   → INTEGER / BIGINT (stored as int64)
#   'float' → DECIMAL / DOUBLE (stored as float64, cast at load time)
#   'date'  → DATE
#   'ts'    → TIMESTAMP
#   'bool'  → BOOLEAN
TYPE_TO_PA = {
    "str":   pa.string(),
    "int":   pa.int64(),
    "float": pa.float64(),
    "date":  pa.date32(),
    "ts":    pa.timestamp("us"),
    "bool":  pa.bool_(),
}


def _coerce(v: Any, code: str):
    """Coerce a Python value to something pyarrow accepts for the hinted type."""
    if v is None or v == "":
        return None
    if code == "float" and isinstance(v, Decimal):
        return float(v)
    if code == "int" and isinstance(v, bool):
        return int(v)
    if code == "str" and not isinstance(v, str):
        return str(v)
    return v


def write_parquet(path: Path, columns: list[tuple[str, str]], rows: list[dict]) -> None:
    """
    Write `rows` to `path` as a Parquet file.

    columns: list of (name, type_code) tuples in output order.
    rows:    list of dicts keyed by column name.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [pa.field(name, TYPE_TO_PA[code]) for (name, code) in columns]
    schema = pa.schema(fields)

    data = {name: [] for (name, _) in columns}
    for r in rows:
        for (name, code) in columns:
            data[name].append(_coerce(r.get(name), code))

    table = pa.Table.from_pydict(data, schema=schema)
    pq.write_table(table, path, compression="snappy")
