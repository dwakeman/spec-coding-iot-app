#!/usr/bin/env python3
"""
Load CSV data into Cassandra using the Python driver
Runs on host machine, connects to Cassandra container via localhost:9042
Optimized with concurrent execution for faster loading
"""

import csv
import sys
import os
from pathlib import Path
from datetime import datetime
from uuid import UUID
from decimal import Decimal
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock

try:
    from cassandra.cluster import Cluster
    from cassandra.auth import PlainTextAuthProvider
    from cassandra.concurrent import execute_concurrent_with_args
except ImportError:
    print("ERROR: cassandra-driver not installed")
    print("Install it with: pip install cassandra-driver")
    sys.exit(1)


class CassandraDataLoader:
    def __init__(self, host='localhost', port=9042, keyspace=None):
        self.host = host
        self.port = port
        self.keyspace = keyspace
        self.cluster = None
        self.session = None
        
    def connect(self):
        """Connect to Cassandra"""
        print(f"Connecting to Cassandra at {self.host}:{self.port}...")
        self.cluster = Cluster([self.host], port=self.port)
        self.session = self.cluster.connect()
        
        if self.keyspace:
            self.session.set_keyspace(self.keyspace)
            print(f"Using keyspace: {self.keyspace}")
        
        print("✓ Connected to Cassandra")
    
    def disconnect(self):
        """Disconnect from Cassandra"""
        if self.cluster:
            self.cluster.shutdown()
            print("✓ Disconnected from Cassandra")
    
    def get_column_types(self, keyspace, table):
        """Fetch {column_name: cql_type} from system_schema.columns."""
        rows = self.session.execute(
            "SELECT column_name, type FROM system_schema.columns "
            "WHERE keyspace_name=%s AND table_name=%s",
            (keyspace, table),
        )
        return {r.column_name: r.type for r in rows}

    def convert_value(self, value, cql_type):
        """Convert a CSV string to the Python type that matches the CQL column type."""
        if value is None or value == '':
            return None

        t = cql_type.lower()

        # Collections: list<...>, set<...>, map<...>, frozen<...>. CSVs store these as JSON.
        if t.startswith(('list<', 'set<', 'frozen<list<', 'frozen<set<')):
            import json
            try:
                return json.loads(value)
            except Exception:
                return [item.strip().strip('"\'') for item in value.strip('[]').split(',') if item.strip()]
        if t.startswith(('map<', 'frozen<map<')):
            import json
            return json.loads(value)

        if t == 'boolean':
            return value.strip().lower() == 'true'
        if t in ('uuid', 'timeuuid'):
            return UUID(value)
        if t == 'timestamp':
            return datetime.fromisoformat(value.replace('Z', '+00:00'))
        if t == 'date':
            return datetime.strptime(value, '%Y-%m-%d').date()
        if t in ('int', 'smallint', 'tinyint', 'bigint', 'varint', 'counter'):
            # Tolerate Decimal-looking inputs like "10.0" by going through Decimal.
            return int(Decimal(value.strip()))
        if t in ('float', 'double'):
            return float(value)
        if t == 'decimal':
            return Decimal(value.strip())
        # text, varchar, ascii, inet, blob → leave as string
        return value
    
    def load_csv_to_table(self, csv_file, table_name):
        """Load a CSV file into a Cassandra table with concurrent execution"""
        if not os.path.exists(csv_file):
            print(f"✗ File not found: {csv_file}")
            return False
        
        print(f"\nLoading {table_name}...")
        
        try:
            # Read CSV header first to build INSERT statement
            with open(csv_file, 'r') as f:
                reader = csv.DictReader(f)
                first_row = next(reader, None)
                
                if not first_row:
                    print(f"  ⚠ No data in {csv_file}")
                    return True
                
                columns = list(first_row.keys())
            
            # Build INSERT statement
            placeholders = ', '.join(['?' for _ in columns])
            insert_stmt = f"INSERT INTO {table_name} ({', '.join(columns)}) VALUES ({placeholders})"
            prepared = self.session.prepare(insert_stmt)

            # Fetch authoritative CQL types from the schema so we convert
            # CSV strings based on the declared column type, not guesswork
            # from column names. Missing types fall back to text.
            column_types = self.get_column_types(self.session.keyspace, table_name)
            col_type_list = [column_types.get(c, 'text') for c in columns]
            
            # Process CSV in chunks for memory efficiency
            chunk_size = 5000  # Process 5000 rows at a time
            concurrency = 100  # Execute 100 statements concurrently
            
            total_loaded = 0
            total_errors = 0
            error_lock = Lock()
            
            with open(csv_file, 'r') as f:
                reader = csv.DictReader(f)
                chunk = []
                
                for row in reader:
                    chunk.append(row)
                    
                    if len(chunk) >= chunk_size:
                        # Process chunk
                        loaded, errors = self._load_chunk(prepared, chunk, columns, col_type_list, concurrency)
                        total_loaded += loaded
                        total_errors += errors

                        # Progress indicator
                        if total_loaded % 10000 == 0:
                            print(f"  Loaded {total_loaded:,} rows...")

                        chunk = []

                # Process remaining rows
                if chunk:
                    loaded, errors = self._load_chunk(prepared, chunk, columns, col_type_list, concurrency)
                    total_loaded += loaded
                    total_errors += errors
            
            print(f"✓ Loaded {total_loaded:,} rows into {table_name}")
            if total_errors > 0:
                print(f"  ⚠ {total_errors} rows failed to load")
            
            return True
            
        except Exception as e:
            print(f"✗ Error loading {table_name}: {e}")
            return False
    
    def _load_chunk(self, prepared, chunk, columns, col_types, concurrency):
        """Load a chunk of rows using concurrent execution"""
        # Convert rows to parameter lists
        parameters = []
        for row in chunk:
            values = [self.convert_value(row[col], col_types[i]) for i, col in enumerate(columns)]
            parameters.append(values)
        
        # Execute concurrently
        try:
            results = execute_concurrent_with_args(
                self.session,
                prepared,
                parameters,
                concurrency=concurrency,
                raise_on_first_error=False
            )
            
            # Count successes and failures
            loaded = sum(1 for success, _ in results if success)
            errors = len(results) - loaded
            
            # Print first few errors for debugging
            error_count = 0
            for success, result in results:
                if not success and error_count < 3:
                    print(f"  ⚠ Error inserting row: {result}")
                    error_count += 1
            
            return loaded, errors
            
        except Exception as e:
            print(f"  ⚠ Chunk load error: {e}")
            return 0, len(chunk)
    
    def load_dataset(self, dataset_dir, keyspace_name):
        """Load all CSV files from a dataset directory.

        New generators write Cassandra CSVs under generated_data/cassandra/
        so joins with the Iceberg side (generated_data/iceberg/*.parquet)
        are easy to reason about. Older layouts (flat generated_data/) are
        still tolerated for backwards compatibility.
        """
        dataset_path = Path(dataset_dir)
        new_dir = dataset_path / 'generated_data' / 'cassandra'
        legacy_dir = dataset_path / 'generated_data'
        data_dir = new_dir if new_dir.is_dir() else legacy_dir

        if not data_dir.exists():
            print(f"✗ Data directory not found: {data_dir}")
            return False
        
        # Set keyspace
        self.session.set_keyspace(keyspace_name)
        print(f"\n{'='*60}")
        print(f"Loading {keyspace_name} dataset")
        print(f"{'='*60}")
        
        # Find all CSV files
        csv_files = sorted(data_dir.glob('*.csv'))
        
        if not csv_files:
            print(f"✗ No CSV files found in {data_dir}")
            return False
        
        # Group files by base table name (handle batched files like sensor_readings_00.csv)
        table_files = {}
        for csv_file in csv_files:
            filename = csv_file.stem
            # Remove batch suffix (_00, _01, etc.) if present
            import re
            base_name = re.sub(r'_\d+$', '', filename)
            if base_name not in table_files:
                table_files[base_name] = []
            table_files[base_name].append(csv_file)
        
        # Load each table (may have multiple files)
        success = True
        for table_name, files in sorted(table_files.items()):
            if len(files) > 1:
                print(f"\nLoading {table_name} ({len(files)} files)...")
            for csv_file in files:
                if not self.load_csv_to_table(str(csv_file), table_name):
                    success = False
        
        return success


def main():
    """Main entry point"""
    print("="*60)
    print("Cassandra Data Loader")
    print("="*60)
    
    # Get script directory
    script_dir = Path(__file__).parent
    
    # Initialize loader
    loader = CassandraDataLoader(host='localhost', port=9042)
    
    try:
        # Connect to Cassandra
        loader.connect()
        
        # Load each dataset
        datasets = [
            ('ecommerce', 'ecommerce'),
            ('iot', 'iot'),
            ('financial', 'financial')
        ]
        
        for dataset_name, keyspace_name in datasets:
            dataset_dir = script_dir / dataset_name
            if dataset_dir.exists():
                loader.load_dataset(dataset_dir, keyspace_name)
            else:
                print(f"\n⚠ Dataset directory not found: {dataset_dir}")
        
        print("\n" + "="*60)
        print("✓ Data loading complete!")
        print("="*60)
        
    except Exception as e:
        print(f"\n✗ Error: {e}")
        sys.exit(1)
    
    finally:
        loader.disconnect()


if __name__ == '__main__':
    main()

# Made with Bob
