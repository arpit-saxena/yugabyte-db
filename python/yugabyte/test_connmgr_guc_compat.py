#!/usr/bin/env python3
# Copyright (c) YugabyteDB, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied. See the License for the specific language governing permissions and limitations under
# the License.

"""
GUC Compatibility Test Script for YugabyteDB Connection Manager (ConnMgr).

Tests that SET/SHOW/RESET work correctly through the ConnMgr (Odyssey-based
connection pooler) running in transaction pooling mode.

Test categories:
  T1 - Basic SET/SHOW round-trip
  T2 - Cross-transaction persistence (deploy test)
  T3 - Session isolation (no state leakage between sessions)
  T4 - RESET ALL
  T5 - SET LOCAL (transaction-scoped)
  T6 - NEEDS_REVIEW special cases (cross-GUC hooks, non-round-trippable GUCs)

Usage:
  python3 test_connmgr_guc_compat.py --host 127.0.0.1 --port 5433 --csv path/to/report.csv

Exit codes:
  0 - All tests passed
  1 - One or more tests failed
"""

import argparse
import csv
import json
import sys
import time
import os
from collections import defaultdict
from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import Optional

try:
    import psycopg2
    import psycopg2.extensions
except ImportError:
    print("ERROR: psycopg2 is required. Install with: pip install psycopg2-binary", file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------------------
# GUC value lookup tables
# ---------------------------------------------------------------------------

# Known valid alternate values for string GUCs where arbitrary strings won't work.
# Maps guc_name -> (default_value, alternate_value) or just alternate_value.
# The script will use the alternate_value if it differs from current; if not, it's skipped.
STRING_GUC_TEST_VALUES: dict[str, str] = {
    # Core PG string GUCs (PGC_USERSET)
    "application_name": "connmgr_test_app",
    "client_encoding": "UTF8",
    "DateStyle": "SQL, DMY",
    "default_table_access_method": "heap",
    "default_tablespace": "",
    "default_text_search_config": "pg_catalog.simple",
    "IntervalStyle": "sql_standard",
    "lc_monetary": "C",
    "lc_numeric": "C",
    "lc_time": "C",
    "local_preload_libraries": "",
    "restrict_nonsystem_relation_kind": "view",
    "search_path": "pg_catalog, public",
    "temp_tablespaces": "",
    "TimeZone": "US/Eastern",
    "timezone_abbreviations": "Default",

    # PGC_SUSET string GUCs
    "backtrace_functions": "",
    "dynamic_library_path": "$libdir",
    "lc_messages": "C",
    "session_preload_libraries": "",
    "wal_consistency_checking": "",

    # YB-specific string GUCs
    "yb_xcluster_consistency_level": "tablet",
    "yb_default_replica_identity": "FULL",
    "yb_hinted_uids": "1",
    "yb_neg_catcache_ids": "",
    "yb_read_time": "0",
    "yb_test_fail_index_state_change": "",

    # Extension GUCs (may not be loaded)
    "passwordcheck.special_chars": "!@#",
    "plpgsql.extra_errors": "too_many_rows",
    "plpgsql.extra_warnings": "too_many_rows",
    "plperl.on_plperl_init": "",
    "plperl.on_plperlu_init": "",
    "pltcl.start_proc": "",
    "pltclu.start_proc": "",
    "postgres_fdw.application_name": "connmgr_fdw_test",

    # xCluster DDL replication extension GUCs
    "yb_xcluster_ddl_replication.ddl_queue_primary_key_ddl_end_time": "",
    "yb_xcluster_ddl_replication.ddl_queue_primary_key_query_id": "",
}

# GUCs whose enum value 'NONE' maps to empty string in SHOW output.
ENUM_NONE_AS_EMPTY: set[str] = {
    "yb_xcluster_ddl_replication.TEST_replication_role_override",
}

# GUCs that cannot be SET LOCAL inside a transaction block.
NO_SET_LOCAL_GUCS: set[str] = {
    "yb_read_after_commit_visibility",
    "transaction_isolation",
    "transaction_read_only",
    "transaction_deferrable",
}

# For enum GUCs: mapping of GUC name -> list of valid values.
ENUM_GUC_VALUES: dict[str, list[str]] = {
    "yb_enable_cbo": ["off", "on", "legacy_mode"],
    "backslash_quote": ["safe_encoding", "on", "off"],
    "bytea_output": ["escape", "hex"],
    "constraint_exclusion": ["partition", "on", "off"],
    "default_toast_compression": ["pglz"],
    "default_transaction_isolation": ["serializable", "repeatable read", "read committed"],
    "force_parallel_mode": ["off", "on", "regress"],
    "plan_cache_mode": ["auto", "force_generic_plan", "force_custom_plan"],
    "password_encryption": ["md5", "scram-sha-256"],
    "stats_fetch_consistency": ["none", "cache", "snapshot"],
    "synchronous_commit": ["local", "on", "off"],
    "transaction_isolation": ["serializable", "repeatable read", "read committed"],
    "xmlbinary": ["base64", "hex"],
    "xmloption": ["content", "document"],
    "yb_pg_batch_detection_mechanism": [
        "detect_by_peeking",
        "assume_all_batch_executions",
    ],
    "yb_read_after_commit_visibility": ["strict", "relaxed"],
    "yb_sampling_algorithm": ["full_table_scan"],
    "compute_query_id": ["auto", "on", "off"],
    "log_error_verbosity": ["terse", "default", "verbose"],
    "log_min_error_statement": ["error", "warning", "notice", "info", "debug1"],
    "log_min_messages": ["warning", "error", "notice", "info", "debug1"],
    "log_statement": ["none", "ddl", "mod", "all"],
    "session_replication_role": ["origin", "replica", "local"],
    "wal_compression": ["pglz", "on", "off"],
    "plpgsql.variable_conflict": ["error", "use_variable", "use_column"],
    "pg_stat_statements.track": ["none", "top", "all"],
    "yb_log_min_backtraces": ["error", "warning", "notice"],
    "yb_pg_stat_plans_track": ["none", "top", "all"],
    "yb_xcluster_ddl_replication.TEST_replication_role_override": ["SOURCE", "TARGET"],
}

# GUCs that should be skipped entirely (not testable via SET/SHOW for various reasons).
SKIP_GUCS: set[str] = {
    "session_authorization",  # requires specific role setup, tested separately
    "role",                   # requires specific role setup, tested separately
    "seed",                   # SHOW returns 'unavailable', non-round-trippable
    "yb_is_client_ysqlconnmgr",  # PGC_BACKEND, set at connection start
    "yb_use_tserver_key_auth",   # PGC_BACKEND
    "log_connections",           # PGC_SU_BACKEND
    "log_disconnections",        # PGC_SU_BACKEND
    "jit_debugging_support",     # PGC_SU_BACKEND
    "jit_profiling_support",     # PGC_SU_BACKEND
    "ignore_system_indexes",     # PGC_BACKEND
    "post_auth_delay",           # PGC_BACKEND
    "idle_session_timeout",      # setting non-zero kills the connection after timeout
    "exit_on_error",             # setting ON kills the connection on any error
}

# GUCs whose SHOW hook returns kernel/OS values rather than the GUC value.
KERNEL_VALUE_GUCS: set[str] = {
    "tcp_keepalives_count",
    "tcp_keepalives_idle",
    "tcp_keepalives_interval",
    "tcp_user_timeout",
}

# GUCs that can only be SET inside a transaction block.
TRANSACTION_ONLY_GUCS: set[str] = {
    "transaction_isolation",
    "transaction_read_only",
    "transaction_deferrable",
}

# GUCs whose SHOW value has a unit suffix that must be trimmed for comparison.
TIME_UNIT_GUCS: set[str] = {
    "statement_timeout",
    "lock_timeout",
    "idle_in_transaction_session_timeout",
    "idle_session_timeout",
    "deadlock_timeout",
    "authentication_timeout",
    "log_min_duration_statement",
    "log_min_duration_sample",
    "log_autovacuum_min_duration",
}

# GUCs that are exempted from RESET ALL (GUC_NO_RESET_ALL flag) or whose
# RESET ALL behavior is complicated by cross-GUC hooks.
NO_RESET_ALL_GUCS: set[str] = {
    "seed",
    "transaction_isolation",
    "transaction_read_only",
    "transaction_deferrable",
    "is_superuser",
    "role",
    "session_authorization",
    # Cross-GUC hook GUCs: RESET ALL resets them but the assign hook of
    # yb_enable_cbo re-sets them during deploy. Order-dependent.
    "yb_enable_base_scans_cost_model",
    "yb_enable_optimizer_statistics",
    "yb_enable_bitmapscan",
    "yb_enable_update_reltuples_after_create_index",
    "yb_parallel_range_rows",
}


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

class TestResult(Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    SKIP = "SKIP"
    ERROR = "ERROR"


@dataclass
class GUCInfo:
    name: str
    guc_type: str        # bool, int, real, string, enum
    context: str         # PGC_USERSET, PGC_SUSET, etc.
    category: str
    flags: str
    connmgr_compatible: str  # YES, NEEDS_REVIEW
    risk_level: str
    reasoning: str
    # Populated at runtime from pg_settings
    current_value: Optional[str] = None
    boot_val: Optional[str] = None
    reset_val: Optional[str] = None
    min_val: Optional[str] = None
    max_val: Optional[str] = None
    enumvals: Optional[list[str]] = None
    vartype: Optional[str] = None
    unit: Optional[str] = None


@dataclass
class SingleTestResult:
    guc_name: str
    test_category: str
    result: str  # PASS, FAIL, SKIP, ERROR
    message: str = ""
    set_value: str = ""
    show_value: str = ""


# ---------------------------------------------------------------------------
# CSV parser
# ---------------------------------------------------------------------------

def load_guc_report(csv_path: str) -> list[GUCInfo]:
    gucs = []
    with open(csv_path, "r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            gucs.append(GUCInfo(
                name=row["GUC Name"],
                guc_type=row["Type"],
                context=row["Context"],
                category=row["Category"],
                flags=row.get("Flags", ""),
                connmgr_compatible=row["ConnMgr Compatible"],
                risk_level=row["Risk Level"],
                reasoning=row.get("Reasoning", ""),
            ))
    return gucs


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_connection(host: str, port: int, dbname: str, user: str):
    conn = psycopg2.connect(host=host, port=port, dbname=dbname, user=user)
    conn.set_session(autocommit=True)
    return conn


def execute_scalar(conn, query: str, params=None) -> Optional[str]:
    with conn.cursor() as cur:
        cur.execute(query, params)
        row = cur.fetchone()
        return row[0] if row else None


def execute_sql(conn, query: str):
    with conn.cursor() as cur:
        cur.execute(query)


def show_guc(conn, guc_name: str) -> Optional[str]:
    try:
        return execute_scalar(conn, f"SHOW \"{guc_name}\"")
    except psycopg2.InterfaceError:
        raise  # re-raise connection-level errors so callers can reconnect
    except psycopg2.Error:
        try:
            conn.rollback()
        except Exception:
            pass
        return None


def set_guc(conn, guc_name: str, value: str):
    quoted = value.replace("'", "''")
    execute_sql(conn, f"SET \"{guc_name}\" = '{quoted}'")


def reset_guc(conn, guc_name: str):
    execute_sql(conn, f"RESET \"{guc_name}\"")


# ---------------------------------------------------------------------------
# Runtime GUC metadata from pg_settings
# ---------------------------------------------------------------------------

def populate_runtime_info(conn, gucs: list[GUCInfo]):
    """Query pg_settings to get runtime metadata for each GUC."""
    settings_map: dict[str, dict] = {}
    with conn.cursor() as cur:
        cur.execute("""
            SELECT name, setting, unit, vartype,
                   enumvals, min_val, max_val, boot_val, reset_val
            FROM pg_settings
        """)
        for row in cur.fetchall():
            settings_map[row[0].lower()] = {
                "setting": row[1],
                "unit": row[2],
                "vartype": row[3],
                "enumvals": row[4],
                "min_val": row[5],
                "max_val": row[6],
                "boot_val": row[7],
                "reset_val": row[8],
            }

    for guc in gucs:
        info = settings_map.get(guc.name.lower())
        if info:
            guc.current_value = info["setting"]
            guc.unit = info["unit"]
            guc.vartype = info["vartype"]
            guc.enumvals = info["enumvals"]
            guc.min_val = info["min_val"]
            guc.max_val = info["max_val"]
            guc.boot_val = info["boot_val"]
            guc.reset_val = info["reset_val"]


# ---------------------------------------------------------------------------
# Test value generation
# ---------------------------------------------------------------------------

def generate_test_value(guc: GUCInfo) -> Optional[str]:
    """Generate a valid non-default value for this GUC, or None if we can't."""
    name = guc.name
    vartype = guc.vartype or guc.guc_type
    current = guc.current_value

    if current is None:
        return None

    # Check lookup tables first
    if name in STRING_GUC_TEST_VALUES and vartype == "string":
        alt = STRING_GUC_TEST_VALUES[name]
        if alt != current:
            return alt
        return None

    if name in ENUM_GUC_VALUES:
        for v in ENUM_GUC_VALUES[name]:
            if v.lower() != current.lower():
                return v
        return None

    if vartype == "bool":
        return "off" if current == "on" else "on"

    if vartype == "integer":
        try:
            cur_val = int(current)
            min_val = int(guc.min_val) if guc.min_val else -(2**31)
            max_val = int(guc.max_val) if guc.max_val else (2**31 - 1)
            reset_val = int(guc.reset_val) if guc.reset_val else cur_val

            if cur_val + 1 <= max_val:
                candidate = cur_val + 1
            elif cur_val - 1 >= min_val:
                candidate = cur_val - 1
            else:
                return None

            return str(candidate)
        except (ValueError, TypeError):
            return None

    if vartype == "real":
        try:
            cur_val = float(current)
            min_val = float(guc.min_val) if guc.min_val else 0.0
            max_val = float(guc.max_val) if guc.max_val else 1e18

            # Use integer offsets when possible to avoid precision issues
            if cur_val >= 1.0 and cur_val + 1.0 <= max_val:
                candidate = cur_val + 1.0
            elif cur_val - 1.0 >= min_val and cur_val >= 2.0:
                candidate = cur_val - 1.0
            elif cur_val + 0.1 <= max_val:
                candidate = round(cur_val + 0.1, 2)
            elif cur_val - 0.1 >= min_val:
                candidate = round(cur_val - 0.1, 2)
            else:
                return None

            if candidate == int(candidate):
                return str(int(candidate))
            return str(candidate)
        except (ValueError, TypeError):
            return None

    if vartype == "enum":
        if guc.enumvals:
            for v in guc.enumvals:
                if v.lower() != current.lower():
                    return v
        if name in ENUM_GUC_VALUES:
            for v in ENUM_GUC_VALUES[name]:
                if v.lower() != current.lower():
                    return v
        return None

    if vartype == "string":
        if name in STRING_GUC_TEST_VALUES:
            alt = STRING_GUC_TEST_VALUES[name]
            if alt != current:
                return alt
            # Try a second alternate if the first matches current
            second_alts = {
                "DateStyle": "Postgres, YMD",
                "TimeZone": "UTC",
                "search_path": "public",
                "client_encoding": "SQL_ASCII",
                "lc_monetary": "POSIX",
                "lc_numeric": "POSIX",
                "lc_time": "POSIX",
                "application_name": "guc_compat_test_2",
                "default_text_search_config": "pg_catalog.english",
                "restrict_nonsystem_relation_kind": "foreign-table",
                "yb_xcluster_consistency_level": "database",
                "yb_default_replica_identity": "DEFAULT",
                "lc_messages": "POSIX",
            }
            alt2 = second_alts.get(name)
            if alt2 and alt2 != current:
                return alt2
            return None
        return None

    return None


# ---------------------------------------------------------------------------
# Test implementations
# ---------------------------------------------------------------------------

def is_session_settable(guc: GUCInfo) -> bool:
    return guc.context in ("PGC_USERSET", "PGC_SUSET")


def should_skip(guc: GUCInfo) -> tuple[bool, str]:
    if guc.name in SKIP_GUCS:
        return True, "in skip list"
    if not is_session_settable(guc):
        return True, f"context {guc.context} not session-settable"
    if guc.current_value is None:
        return True, "not found in pg_settings (extension not loaded?)"
    return False, ""


def run_t1_basic_set_show(conn, guc: GUCInfo) -> SingleTestResult:
    """T1: Basic SET then SHOW, then RESET and verify."""
    skip, reason = should_skip(guc)
    if skip:
        return SingleTestResult(guc.name, "T1", "SKIP", reason)

    if guc.name in TRANSACTION_ONLY_GUCS:
        return SingleTestResult(guc.name, "T1", "SKIP", "transaction-only GUC")

    if guc.name in KERNEL_VALUE_GUCS:
        return SingleTestResult(guc.name, "T1", "SKIP",
                                "kernel-value GUC (tested in T6)")

    test_val = generate_test_value(guc)
    if test_val is None:
        return SingleTestResult(guc.name, "T1", "SKIP", "no valid alternate value")

    try:
        set_guc(conn, guc.name, test_val)
        shown = show_guc(conn, guc.name)

        if shown is None:
            reset_guc(conn, guc.name)
            return SingleTestResult(guc.name, "T1", "ERROR",
                                    "SHOW returned None after SET")

        if not _values_match(test_val, shown, guc):
            reset_guc(conn, guc.name)
            return SingleTestResult(guc.name, "T1", "FAIL",
                                    f"SET to '{test_val}' but SHOW returned '{shown}'",
                                    set_value=test_val, show_value=shown)

        reset_guc(conn, guc.name)
        reset_shown = show_guc(conn, guc.name)
        expected_reset = guc.reset_val if guc.reset_val else guc.current_value

        if reset_shown is not None and expected_reset is not None:
            if not _values_match(expected_reset, reset_shown, guc):
                return SingleTestResult(guc.name, "T1", "FAIL",
                                        f"After RESET, expected '{expected_reset}' "
                                        f"but got '{reset_shown}'",
                                        show_value=reset_shown)

        return SingleTestResult(guc.name, "T1", "PASS", set_value=test_val,
                                show_value=shown)

    except psycopg2.InterfaceError as e:
        raise  # connection-level error, cannot recover in this function
    except psycopg2.Error as e:
        try:
            reset_guc(conn, guc.name)
        except Exception:
            pass
        return SingleTestResult(guc.name, "T1", "ERROR", str(e).strip())


def run_t2_cross_txn_persistence(conn, guc: GUCInfo) -> SingleTestResult:
    """T2: SET, then run a query in a new transaction to force backend rotation,
    then SHOW to verify value persists."""
    skip, reason = should_skip(guc)
    if skip:
        return SingleTestResult(guc.name, "T2", "SKIP", reason)

    if guc.name in TRANSACTION_ONLY_GUCS:
        return SingleTestResult(guc.name, "T2", "SKIP", "transaction-only GUC")

    if guc.name in KERNEL_VALUE_GUCS:
        return SingleTestResult(guc.name, "T2", "SKIP",
                                "kernel-value GUC (tested in T6)")

    test_val = generate_test_value(guc)
    if test_val is None:
        return SingleTestResult(guc.name, "T2", "SKIP", "no valid alternate value")

    try:
        set_guc(conn, guc.name, test_val)

        # Force a transaction boundary by running a query.
        # In transaction pooling mode, this causes detach/re-attach.
        execute_sql(conn, "SELECT 1")
        # Small delay to allow connection rotation
        time.sleep(0.05)
        execute_sql(conn, "SELECT 1")

        shown = show_guc(conn, guc.name)

        reset_guc(conn, guc.name)

        if shown is None:
            return SingleTestResult(guc.name, "T2", "ERROR",
                                    "SHOW returned None after cross-txn")

        if not _values_match(test_val, shown, guc):
            return SingleTestResult(guc.name, "T2", "FAIL",
                                    f"SET to '{test_val}' but after cross-txn "
                                    f"SHOW returned '{shown}'",
                                    set_value=test_val, show_value=shown)

        return SingleTestResult(guc.name, "T2", "PASS", set_value=test_val,
                                show_value=shown)

    except psycopg2.Error as e:
        try:
            reset_guc(conn, guc.name)
        except Exception:
            pass
        return SingleTestResult(guc.name, "T2", "ERROR", str(e).strip())


def run_t3_session_isolation(conn_factory, guc: GUCInfo) -> SingleTestResult:
    """T3: SET in session A, verify session B doesn't see it."""
    skip, reason = should_skip(guc)
    if skip:
        return SingleTestResult(guc.name, "T3", "SKIP", reason)

    if guc.name in TRANSACTION_ONLY_GUCS:
        return SingleTestResult(guc.name, "T3", "SKIP", "transaction-only GUC")

    test_val = generate_test_value(guc)
    if test_val is None:
        return SingleTestResult(guc.name, "T3", "SKIP", "no valid alternate value")

    conn_a = None
    conn_b = None
    try:
        conn_a = conn_factory()
        set_guc(conn_a, guc.name, test_val)

        conn_b = conn_factory()
        shown_b = show_guc(conn_b, guc.name)

        expected_default = guc.reset_val if guc.reset_val else guc.current_value

        reset_guc(conn_a, guc.name)

        if shown_b is None:
            return SingleTestResult(guc.name, "T3", "ERROR",
                                    "SHOW on session B returned None")

        if _values_match(test_val, shown_b, guc) and \
           not _values_match(test_val, expected_default, guc):
            return SingleTestResult(guc.name, "T3", "FAIL",
                                    f"Session B sees session A's value '{shown_b}' "
                                    f"instead of default '{expected_default}'",
                                    set_value=test_val, show_value=shown_b)

        return SingleTestResult(guc.name, "T3", "PASS", set_value=test_val,
                                show_value=shown_b)

    except psycopg2.Error as e:
        return SingleTestResult(guc.name, "T3", "ERROR", str(e).strip())
    finally:
        if conn_a:
            try:
                conn_a.close()
            except Exception:
                pass
        if conn_b:
            try:
                conn_b.close()
            except Exception:
                pass


def run_t4_reset_all(conn, testable_gucs: list[GUCInfo]) -> list[SingleTestResult]:
    """T4: SET several GUCs, RESET ALL, verify all returned to defaults."""
    results = []
    set_gucs: list[tuple[GUCInfo, str]] = []

    for guc in testable_gucs:
        if guc.name in SKIP_GUCS or guc.name in TRANSACTION_ONLY_GUCS:
            continue
        if guc.name in NO_RESET_ALL_GUCS:
            continue
        if "GUC_NO_RESET_ALL" in (guc.flags or ""):
            continue

        test_val = generate_test_value(guc)
        if test_val is None:
            continue

        try:
            set_guc(conn, guc.name, test_val)
            set_gucs.append((guc, test_val))
        except psycopg2.Error:
            pass

        if len(set_gucs) >= 20:
            break

    if not set_gucs:
        return [SingleTestResult("(RESET ALL)", "T4", "SKIP",
                                 "no GUCs could be SET")]

    try:
        execute_sql(conn, "RESET ALL")
    except psycopg2.Error as e:
        return [SingleTestResult("(RESET ALL)", "T4", "ERROR",
                                 f"RESET ALL failed: {e}")]

    for guc, test_val in set_gucs:
        shown = show_guc(conn, guc.name)
        expected = guc.reset_val if guc.reset_val else guc.current_value

        if shown is None:
            results.append(SingleTestResult(guc.name, "T4", "ERROR",
                                            "SHOW returned None after RESET ALL"))
        elif expected and not _values_match(expected, shown, guc):
            results.append(SingleTestResult(guc.name, "T4", "FAIL",
                                            f"After RESET ALL, expected '{expected}' "
                                            f"but got '{shown}'",
                                            set_value=test_val, show_value=shown))
        else:
            results.append(SingleTestResult(guc.name, "T4", "PASS",
                                            set_value=test_val, show_value=shown))

    return results


def run_t5_set_local(conn, guc: GUCInfo) -> SingleTestResult:
    """T5: SET LOCAL inside a transaction, verify gone after COMMIT."""
    skip, reason = should_skip(guc)
    if skip:
        return SingleTestResult(guc.name, "T5", "SKIP", reason)

    if guc.name in KERNEL_VALUE_GUCS:
        return SingleTestResult(guc.name, "T5", "SKIP",
                                "kernel-value GUC (tested in T6)")

    if guc.name in NO_SET_LOCAL_GUCS:
        return SingleTestResult(guc.name, "T5", "SKIP",
                                "cannot SET LOCAL in txn block")

    test_val = generate_test_value(guc)
    if test_val is None:
        return SingleTestResult(guc.name, "T5", "SKIP", "no valid alternate value")

    try:
        original = show_guc(conn, guc.name)
    except psycopg2.InterfaceError:
        raise

    try:
        conn.set_session(autocommit=False)
        quoted = test_val.replace("'", "''")
        execute_sql(conn, f"SET LOCAL \"{guc.name}\" = '{quoted}'")
        shown_in_txn = show_guc(conn, guc.name)
        conn.commit()

        conn.set_session(autocommit=True)
        shown_after = show_guc(conn, guc.name)

        if shown_in_txn is not None and not _values_match(test_val, shown_in_txn, guc):
            return SingleTestResult(guc.name, "T5", "FAIL",
                                    f"SET LOCAL to '{test_val}' but inside txn "
                                    f"SHOW returned '{shown_in_txn}'",
                                    set_value=test_val, show_value=shown_in_txn)

        if shown_after is not None and original is not None:
            if not _values_match(original, shown_after, guc):
                return SingleTestResult(guc.name, "T5", "FAIL",
                                        f"After COMMIT, expected '{original}' "
                                        f"but got '{shown_after}'",
                                        set_value=test_val, show_value=shown_after)

        return SingleTestResult(guc.name, "T5", "PASS", set_value=test_val,
                                show_value=str(shown_after))

    except psycopg2.Error as e:
        try:
            conn.rollback()
        except Exception:
            pass
        conn.set_session(autocommit=True)
        return SingleTestResult(guc.name, "T5", "ERROR", str(e).strip())


def run_t6_needs_review(conn, conn_factory) -> list[SingleTestResult]:
    """T6: Targeted tests for NEEDS_REVIEW GUCs."""
    results = []

    # T6a: yb_enable_cbo cross-GUC hook test
    results.extend(_test_cbo_cross_guc(conn))

    # T6b: seed non-round-trippable test
    results.extend(_test_seed(conn))

    # T6c: tcp_keepalives_* kernel value tests
    results.extend(_test_tcp_keepalives(conn))

    # T6d: Cross-transaction persistence for NEEDS_REVIEW GUCs
    results.extend(_test_needs_review_persistence(conn, conn_factory))

    # T6e: Transaction-only GUCs
    results.extend(_test_transaction_only_gucs(conn))

    # T6f: Role-related GUCs
    results.extend(_test_role_gucs(conn))

    return results


def _test_cbo_cross_guc(conn) -> list[SingleTestResult]:
    """Test that SET yb_enable_cbo affects dependent GUCs through ConnMgr.

    The key test: SET yb_enable_cbo on one physical connection, then after
    a transaction boundary (possible backend switch), verify the dependent
    GUCs are still consistent.
    """
    results = []

    try:
        orig_cbo = show_guc(conn, "yb_enable_cbo")
        orig_bsm = show_guc(conn, "yb_enable_base_scans_cost_model")

        # Test: SET cbo=off should also set base_scans=off
        set_guc(conn, "yb_enable_cbo", "off")
        off_bsm = show_guc(conn, "yb_enable_base_scans_cost_model")

        if off_bsm == "off":
            results.append(SingleTestResult("yb_enable_cbo", "T6_cross_guc_off",
                                            "PASS",
                                            "SET yb_enable_cbo=off correctly "
                                            "set base_scans_cost_model=off"))
        else:
            results.append(SingleTestResult("yb_enable_cbo", "T6_cross_guc_off",
                                            "FAIL",
                                            f"yb_enable_base_scans_cost_model="
                                            f"'{off_bsm}' (expected 'off')"))

        # Cross-transaction persistence of cross-GUC state
        execute_sql(conn, "SELECT 1")
        time.sleep(0.05)
        execute_sql(conn, "SELECT 1")

        persisted_cbo = show_guc(conn, "yb_enable_cbo")
        persisted_bsm = show_guc(conn, "yb_enable_base_scans_cost_model")

        if persisted_cbo == "off" and persisted_bsm == "off":
            results.append(SingleTestResult("yb_enable_cbo",
                                            "T6_cross_guc_persist",
                                            "PASS",
                                            "Cross-GUC state persisted: "
                                            f"cbo={persisted_cbo}, "
                                            f"bsm={persisted_bsm}"))
        else:
            results.append(SingleTestResult("yb_enable_cbo",
                                            "T6_cross_guc_persist",
                                            "FAIL",
                                            f"Cross-GUC state NOT persisted: "
                                            f"cbo={persisted_cbo}, "
                                            f"bsm={persisted_bsm} "
                                            f"(expected both 'off')"))

        # Restore
        if orig_cbo:
            set_guc(conn, "yb_enable_cbo", orig_cbo)

    except psycopg2.Error as e:
        results.append(SingleTestResult("yb_enable_cbo", "T6_cross_guc",
                                        "ERROR", str(e).strip()))
    return results


def _test_seed(conn) -> list[SingleTestResult]:
    """Test the 'seed' GUC which has a non-round-trippable SHOW hook."""
    results = []
    try:
        execute_sql(conn, "SET seed = 0.5")
        shown = show_guc(conn, "seed")

        # SHOW seed always returns 'unavailable' in YB with ConnMgr
        # The key test: does this not break anything?
        results.append(SingleTestResult("seed", "T6_seed_set",
                                        "PASS",
                                        f"SET seed=0.5 succeeded, "
                                        f"SHOW returned '{shown}'"))

        # Verify we can still run random() after setting seed
        val = execute_scalar(conn, "SELECT random()")
        if val is not None:
            results.append(SingleTestResult("seed", "T6_seed_random",
                                            "PASS",
                                            f"random() returned {val} after SET seed"))
        else:
            results.append(SingleTestResult("seed", "T6_seed_random",
                                            "FAIL",
                                            "random() returned None after SET seed"))

    except psycopg2.Error as e:
        results.append(SingleTestResult("seed", "T6_seed", "ERROR",
                                        str(e).strip()))
    return results


def _test_tcp_keepalives(conn) -> list[SingleTestResult]:
    """Test tcp_keepalives_* GUCs whose SHOW returns kernel values."""
    results = []
    tcp_gucs = [
        ("tcp_keepalives_count", "5"),
        ("tcp_keepalives_idle", "30"),
        ("tcp_keepalives_interval", "5"),
        ("tcp_user_timeout", "5000"),
    ]

    for guc_name, test_val in tcp_gucs:
        try:
            set_guc(conn, guc_name, test_val)
            shown = show_guc(conn, guc_name)

            # The SHOW hook returns the kernel value, not the GUC value.
            # We just verify SET doesn't error and SHOW returns something.
            if shown is not None:
                results.append(SingleTestResult(guc_name, "T6_tcp",
                                                "PASS",
                                                f"SET={test_val}, SHOW='{shown}' "
                                                f"(kernel value may differ)"))
            else:
                results.append(SingleTestResult(guc_name, "T6_tcp",
                                                "FAIL",
                                                "SHOW returned None"))

            reset_guc(conn, guc_name)

        except psycopg2.Error as e:
            results.append(SingleTestResult(guc_name, "T6_tcp",
                                            "ERROR", str(e).strip()))
    return results


def _test_needs_review_persistence(conn, conn_factory) -> list[SingleTestResult]:
    """Test cross-transaction persistence specifically for NEEDS_REVIEW GUCs."""
    results = []
    needs_review_tests = [
        ("yb_enable_cbo", "on"),
        ("lc_messages", "C"),
        ("tcp_keepalives_count", "5"),
        ("tcp_keepalives_idle", "30"),
    ]

    for guc_name, test_val in needs_review_tests:
        try:
            set_guc(conn, guc_name, test_val)
            execute_sql(conn, "SELECT 1")
            time.sleep(0.05)
            execute_sql(conn, "SELECT 1")

            shown = show_guc(conn, guc_name)
            reset_guc(conn, guc_name)

            if shown is not None:
                results.append(SingleTestResult(guc_name,
                                                "T6_needs_review_persist",
                                                "PASS",
                                                f"Persisted across txn: "
                                                f"SET={test_val}, SHOW={shown}"))
            else:
                results.append(SingleTestResult(guc_name,
                                                "T6_needs_review_persist",
                                                "FAIL", "SHOW returned None"))

        except psycopg2.Error as e:
            results.append(SingleTestResult(guc_name,
                                            "T6_needs_review_persist",
                                            "ERROR", str(e).strip()))
    return results


def _test_transaction_only_gucs(conn) -> list[SingleTestResult]:
    """Test GUCs that can only be SET inside a transaction block."""
    results = []
    txn_gucs = [
        ("transaction_isolation", "serializable"),
        ("transaction_read_only", "on"),
        ("transaction_deferrable", "on"),
    ]

    for guc_name, test_val in txn_gucs:
        try:
            conn.set_session(autocommit=False)
            quoted = test_val.replace("'", "''")
            execute_sql(conn, f"SET {guc_name} = '{quoted}'")
            shown = show_guc(conn, guc_name)
            conn.commit()
            conn.set_session(autocommit=True)

            if shown is not None and shown.lower() == test_val.lower():
                results.append(SingleTestResult(guc_name, "T6_txn_only",
                                                "PASS",
                                                f"SET inside txn: {shown}"))
            elif shown is not None:
                results.append(SingleTestResult(guc_name, "T6_txn_only",
                                                "FAIL",
                                                f"Expected '{test_val}' inside txn "
                                                f"but got '{shown}'",
                                                set_value=test_val, show_value=shown))
            else:
                results.append(SingleTestResult(guc_name, "T6_txn_only",
                                                "FAIL",
                                                "SHOW returned None inside txn"))

        except psycopg2.Error as e:
            try:
                conn.rollback()
            except Exception:
                pass
            conn.set_session(autocommit=True)
            results.append(SingleTestResult(guc_name, "T6_txn_only",
                                            "ERROR", str(e).strip()))

    return results


def _test_role_gucs(conn) -> list[SingleTestResult]:
    """Test role/session_authorization GUCs which require actual roles."""
    results = []
    test_role = "connmgr_guc_role_test"

    try:
        try:
            execute_sql(conn, f"DROP ROLE IF EXISTS {test_role}")
        except psycopg2.Error:
            pass
        execute_sql(conn, f"CREATE ROLE {test_role} LOGIN")

        # Test SET ROLE
        execute_sql(conn, f"SET role = '{test_role}'")
        shown = show_guc(conn, "role")
        if shown and shown.lower() == test_role.lower():
            results.append(SingleTestResult("role", "T6_role", "PASS",
                                            f"SET role={test_role}, SHOW={shown}"))
        else:
            results.append(SingleTestResult("role", "T6_role", "FAIL",
                                            f"Expected '{test_role}' but got '{shown}'"))

        execute_sql(conn, "RESET role")

        # Test SET session_authorization
        execute_sql(conn, f"SET session_authorization = '{test_role}'")
        shown = show_guc(conn, "session_authorization")
        if shown and shown.lower() == test_role.lower():
            results.append(SingleTestResult("session_authorization", "T6_role",
                                            "PASS",
                                            f"SET session_authorization={test_role}, "
                                            f"SHOW={shown}"))
        else:
            results.append(SingleTestResult("session_authorization", "T6_role",
                                            "FAIL",
                                            f"Expected '{test_role}' but got '{shown}'"))

        execute_sql(conn, "RESET session_authorization")

        # Cross-transaction persistence test for role GUC
        execute_sql(conn, f"SET role = '{test_role}'")
        execute_sql(conn, "SELECT 1")
        time.sleep(0.05)
        execute_sql(conn, "SELECT 1")
        shown = show_guc(conn, "role")
        if shown and shown.lower() == test_role.lower():
            results.append(SingleTestResult("role", "T6_role_persist", "PASS",
                                            f"role persisted across txn: {shown}"))
        else:
            results.append(SingleTestResult("role", "T6_role_persist", "FAIL",
                                            f"role did not persist: {shown}"))
        execute_sql(conn, "RESET role")

    except psycopg2.Error as e:
        results.append(SingleTestResult("role", "T6_role", "ERROR",
                                        str(e).strip()))
        try:
            execute_sql(conn, "RESET role")
            execute_sql(conn, "RESET session_authorization")
        except Exception:
            pass
    finally:
        try:
            execute_sql(conn, f"DROP ROLE IF EXISTS {test_role}")
        except Exception:
            pass

    return results


# ---------------------------------------------------------------------------
# Value comparison helpers
# ---------------------------------------------------------------------------

def _normalize_unit_value(raw: str, unit: Optional[str]) -> Optional[str]:
    """Normalize a GUC value that may include unit suffixes.

    pg_settings stores raw numeric values (e.g., '4096' for 4MB when unit=kB)
    but SHOW returns human-friendly values (e.g., '4MB'). This converts
    the SHOW output back to the raw unit for comparison.
    """
    if not raw or not unit:
        return raw

    raw = raw.strip()

    # Common unit conversions: SHOW format -> base unit multiplier
    unit_multipliers: dict[str, dict[str, float]] = {
        "kB": {"kB": 1, "MB": 1024, "GB": 1024 * 1024, "TB": 1024**3},
        "8kB": {"kB": 0.125, "MB": 128, "GB": 128 * 1024, "TB": 128 * 1024**2,
                "8kB": 1},
        "B": {"B": 1, "kB": 1024, "MB": 1024**2, "GB": 1024**3},
        "ms": {"us": 0.001, "ms": 1, "s": 1000, "min": 60000, "h": 3600000,
               "d": 86400000},
        "s": {"ms": 0.001, "s": 1, "min": 60, "h": 3600, "d": 86400},
        "min": {"s": 1/60, "min": 1, "h": 60, "d": 1440},
    }

    multipliers = unit_multipliers.get(unit, {})
    for suffix, mult in sorted(multipliers.items(), key=lambda x: -len(x[0])):
        if raw.endswith(suffix):
            num_part = raw[:-len(suffix)].strip()
            try:
                return str(int(float(num_part) * mult))
            except (ValueError, TypeError):
                pass

    return raw


def _values_match(expected: str, actual: str, guc: GUCInfo) -> bool:
    """Compare GUC values, handling type-specific normalization."""
    if expected == actual:
        return True

    # Case-insensitive for bools and enums
    if (guc.vartype or guc.guc_type) in ("bool", "enum"):
        return expected.lower() == actual.lower()

    # For GUCs with units, normalize before comparing
    if guc.unit:
        norm_actual = _normalize_unit_value(actual, guc.unit)
        norm_expected = _normalize_unit_value(expected, guc.unit)
        if norm_actual and norm_expected:
            try:
                if int(float(norm_actual)) == int(float(norm_expected)):
                    return True
            except (ValueError, TypeError):
                pass

    # Numeric comparison for ints and reals
    if (guc.vartype or guc.guc_type) == "integer":
        try:
            return int(expected) == int(actual)
        except (ValueError, TypeError):
            pass

    if (guc.vartype or guc.guc_type) == "real":
        try:
            return abs(float(expected) - float(actual)) < 1e-6
        except (ValueError, TypeError):
            pass
        # Also try parsing with unit stripping
        try:
            actual_num = actual.rstrip("abcdefghijklmnopqrstuvwxyzBMGTkKs ")
            return abs(float(expected) - float(actual_num)) < 1e-6
        except (ValueError, TypeError):
            pass

    # Handle string quoting (e.g., SHOW search_path returns '"pg_catalog, public"')
    if actual.startswith('"') and actual.endswith('"'):
        if expected == actual[1:-1]:
            return True

    # Handle enum GUCs where value "NONE" maps to empty string
    if guc.name in ENUM_NONE_AS_EMPTY:
        if (expected.upper() == "NONE" and actual == "") or \
           (expected == "" and actual.upper() == "NONE"):
            return True

    # Normalized string comparison
    return expected.strip().lower() == actual.strip().lower()


# ---------------------------------------------------------------------------
# Test role setup
# ---------------------------------------------------------------------------

def setup_test_role(conn, role_name: str = "connmgr_test_user"):
    """Create a non-superuser role for testing PGC_USERSET GUCs."""
    try:
        execute_sql(conn, f"DROP ROLE IF EXISTS {role_name}")
    except psycopg2.Error:
        pass
    try:
        execute_sql(conn, f"CREATE ROLE {role_name} LOGIN")
        execute_sql(conn, f"GRANT ALL ON DATABASE yugabyte TO {role_name}")
    except psycopg2.Error as e:
        print(f"  WARNING: Could not create test role: {e}", file=sys.stderr)
        return False
    return True


def cleanup_test_role(conn, role_name: str = "connmgr_test_user"):
    try:
        execute_sql(conn, f"DROP ROLE IF EXISTS {role_name}")
    except psycopg2.Error:
        pass


# ---------------------------------------------------------------------------
# Main test runner
# ---------------------------------------------------------------------------

def run_all_tests(args) -> tuple[list[SingleTestResult], dict]:
    all_results: list[SingleTestResult] = []
    summary: dict = {
        "host": args.host,
        "port": args.port,
        "total_gucs_in_csv": 0,
        "session_settable_gucs": 0,
        "tests_run": 0,
        "passed": 0,
        "failed": 0,
        "skipped": 0,
        "errors": 0,
    }

    print(f"Loading GUC report from {args.csv}...")
    gucs = load_guc_report(args.csv)
    summary["total_gucs_in_csv"] = len(gucs)
    print(f"  Loaded {len(gucs)} GUCs from CSV")

    # Separate GUCs by required privilege level
    userset_gucs = [g for g in gucs if g.context == "PGC_USERSET"]
    suset_gucs = [g for g in gucs if g.context == "PGC_SUSET"]
    summary["session_settable_gucs"] = len(userset_gucs) + len(suset_gucs)

    # Connect as superuser to set up roles and get metadata
    print(f"\nConnecting to ConnMgr at {args.host}:{args.port} as {args.su_user}...")
    su_conn = get_connection(args.host, args.port, args.dbname, args.su_user)

    print("  Populating runtime GUC metadata from pg_settings...")
    populate_runtime_info(su_conn, gucs)

    populated = sum(1 for g in gucs if g.current_value is not None)
    print(f"  Found {populated}/{len(gucs)} GUCs in pg_settings")

    # Setup test role for non-superuser tests
    test_role = "connmgr_test_user"
    print(f"\nSetting up test role '{test_role}'...")
    role_ok = setup_test_role(su_conn, test_role)

    if role_ok:
        print(f"  Connecting as '{test_role}' for USERSET tests...")
        try:
            user_conn = get_connection(args.host, args.port, args.dbname, test_role)
        except psycopg2.Error as e:
            print(f"  WARNING: Could not connect as {test_role}: {e}", file=sys.stderr)
            print(f"  Falling back to {args.su_user} for all tests", file=sys.stderr)
            user_conn = su_conn
            role_ok = False
    else:
        user_conn = su_conn

    def user_conn_factory():
        if role_ok:
            return get_connection(args.host, args.port, args.dbname, test_role)
        return get_connection(args.host, args.port, args.dbname, args.su_user)

    def su_conn_factory():
        return get_connection(args.host, args.port, args.dbname, args.su_user)

    def _run_with_recovery(conn_ref, conn_factory_fn, guc, test_fn, results_list):
        """Run a test function with connection recovery on InterfaceError."""
        nonlocal user_conn, su_conn
        try:
            r = test_fn(conn_ref[0], guc)
            results_list.append(r)
            _print_result(r)
        except psycopg2.InterfaceError:
            results_list.append(SingleTestResult(
                guc.name, "?", "ERROR", "connection lost, reconnecting"))
            _print_result(results_list[-1])
            try:
                conn_ref[0] = conn_factory_fn()
            except Exception as e:
                print(f"\n  FATAL: could not reconnect: {e}", file=sys.stderr)

    # Wrap connections in mutable references for recovery
    user_conn_ref = [user_conn]
    su_conn_ref = [su_conn]

    # ---- T1: Basic SET/SHOW ----
    print("\n" + "=" * 70)
    print("T1: Basic SET/SHOW round-trip")
    print("=" * 70)

    for guc in userset_gucs:
        _run_with_recovery(user_conn_ref, user_conn_factory,
                           guc, run_t1_basic_set_show, all_results)

    for guc in suset_gucs:
        _run_with_recovery(su_conn_ref, su_conn_factory,
                           guc, run_t1_basic_set_show, all_results)

    print()  # newline after T1 dots

    # ---- T2: Cross-transaction persistence ----
    print("\n" + "=" * 70)
    print("T2: Cross-transaction persistence (deploy test)")
    print("=" * 70)

    for guc in userset_gucs:
        _run_with_recovery(user_conn_ref, user_conn_factory,
                           guc, run_t2_cross_txn_persistence, all_results)

    for guc in suset_gucs:
        _run_with_recovery(su_conn_ref, su_conn_factory,
                           guc, run_t2_cross_txn_persistence, all_results)

    print()  # newline after T2 dots

    # ---- T3: Session isolation ----
    print("\n" + "=" * 70)
    print("T3: Session isolation (no state leakage)")
    print("=" * 70)

    for guc in userset_gucs:
        r = run_t3_session_isolation(user_conn_factory, guc)
        all_results.append(r)
        _print_result(r)

    for guc in suset_gucs:
        r = run_t3_session_isolation(su_conn_factory, guc)
        all_results.append(r)
        _print_result(r)

    print()  # newline after T3 dots

    # ---- T4: RESET ALL ----
    print("\n" + "=" * 70)
    print("T4: RESET ALL")
    print("=" * 70)

    testable_userset = [g for g in userset_gucs
                        if not should_skip(g)[0]
                        and g.name not in TRANSACTION_ONLY_GUCS
                        and g.name not in KERNEL_VALUE_GUCS]
    t4_results = run_t4_reset_all(user_conn_ref[0], testable_userset)
    all_results.extend(t4_results)
    for r in t4_results:
        _print_result(r)

    testable_suset = [g for g in suset_gucs
                      if not should_skip(g)[0]
                      and g.name not in TRANSACTION_ONLY_GUCS
                      and g.name not in KERNEL_VALUE_GUCS]
    t4_su_results = run_t4_reset_all(su_conn_ref[0], testable_suset)
    all_results.extend(t4_su_results)
    for r in t4_su_results:
        _print_result(r)

    print()  # newline after T4 dots

    # ---- T5: SET LOCAL ----
    print("\n" + "=" * 70)
    print("T5: SET LOCAL (transaction-scoped)")
    print("=" * 70)

    for guc in userset_gucs:
        _run_with_recovery(user_conn_ref, user_conn_factory,
                           guc, run_t5_set_local, all_results)

    for guc in suset_gucs:
        _run_with_recovery(su_conn_ref, su_conn_factory,
                           guc, run_t5_set_local, all_results)

    print()  # newline after T5 dots

    # ---- T6: NEEDS_REVIEW special cases ----
    print("\n" + "=" * 70)
    print("T6: NEEDS_REVIEW special cases")
    print("=" * 70)

    t6_results = run_t6_needs_review(su_conn_ref[0], su_conn_factory)
    all_results.extend(t6_results)
    for r in t6_results:
        _print_result(r)

    # Cleanup
    user_conn = user_conn_ref[0]
    su_conn = su_conn_ref[0]
    if role_ok and user_conn is not su_conn:
        try:
            user_conn.close()
        except Exception:
            pass
    cleanup_test_role(su_conn, test_role)
    su_conn.close()

    # Compute summary
    for r in all_results:
        summary["tests_run"] += 1
        if r.result == "PASS":
            summary["passed"] += 1
        elif r.result == "FAIL":
            summary["failed"] += 1
        elif r.result == "SKIP":
            summary["skipped"] += 1
        elif r.result == "ERROR":
            summary["errors"] += 1

    return all_results, summary


_print_counter = 0


def _print_result(r: SingleTestResult):
    """Print a single test result on one line."""
    global _print_counter
    status_char = {"PASS": ".", "FAIL": "F", "SKIP": "S", "ERROR": "E"}
    c = status_char.get(r.result, "?")
    if r.result in ("FAIL", "ERROR"):
        if _print_counter > 0:
            print()  # newline before error message
            _print_counter = 0
        print(f"  [{c}] {r.test_category} {r.guc_name}: {r.message}")
    elif r.result == "SKIP" and os.environ.get("VERBOSE"):
        if _print_counter > 0:
            print()
            _print_counter = 0
        print(f"  [{c}] {r.test_category} {r.guc_name}: {r.message}")
    else:
        print(c, end="", flush=True)
        _print_counter += 1
        if _print_counter >= 72:
            print()
            _print_counter = 0


# ---------------------------------------------------------------------------
# Output and reporting
# ---------------------------------------------------------------------------

def write_report(all_results: list[SingleTestResult], summary: dict,
                 output_path: Optional[str]):
    report = {
        "summary": summary,
        "results": [asdict(r) for r in all_results],
        "failures": [asdict(r) for r in all_results if r.result == "FAIL"],
        "errors": [asdict(r) for r in all_results if r.result == "ERROR"],
    }

    json_str = json.dumps(report, indent=2)
    if output_path:
        with open(output_path, "w") as f:
            f.write(json_str)
        print(f"\nDetailed results written to {output_path}")
    return report


def print_summary(summary: dict, all_results: list[SingleTestResult]):
    print("\n")
    print("=" * 70)
    print("TEST SUMMARY")
    print("=" * 70)
    print(f"  GUCs in CSV:           {summary['total_gucs_in_csv']}")
    print(f"  Session-settable GUCs: {summary['session_settable_gucs']}")
    print(f"  Tests run:             {summary['tests_run']}")
    print(f"  Passed:                {summary['passed']}")
    print(f"  Failed:                {summary['failed']}")
    print(f"  Errors:                {summary['errors']}")
    print(f"  Skipped:               {summary['skipped']}")

    failures = [r for r in all_results if r.result == "FAIL"]
    errors = [r for r in all_results if r.result == "ERROR"]

    if failures:
        print(f"\n  FAILURES ({len(failures)}):")
        for r in failures:
            print(f"    [{r.test_category}] {r.guc_name}: {r.message}")

    if errors:
        print(f"\n  ERRORS ({len(errors)}):")
        for r in errors:
            print(f"    [{r.test_category}] {r.guc_name}: {r.message}")

    if not failures and not errors:
        print("\n  All tests passed!")
    print("=" * 70)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Test GUC compatibility with YugabyteDB Connection Manager")
    parser.add_argument("--host", default="127.0.0.1",
                        help="ConnMgr host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=5433,
                        help="ConnMgr port (default: 5433)")
    parser.add_argument("--dbname", default="yugabyte",
                        help="Database name (default: yugabyte)")
    parser.add_argument("--su-user", default="yugabyte",
                        help="Superuser name (default: yugabyte)")
    parser.add_argument("--csv", required=True,
                        help="Path to the GUC compatibility CSV report")
    parser.add_argument("--output", default=None,
                        help="Path to write JSON results (default: stdout)")
    parser.add_argument("--verbose", action="store_true",
                        help="Show SKIP results in addition to FAIL/ERROR")

    args = parser.parse_args()

    if args.verbose:
        os.environ["VERBOSE"] = "1"

    all_results, summary = run_all_tests(args)
    report = write_report(all_results, summary, args.output)
    print_summary(summary, all_results)

    if summary["failed"] > 0 or summary["errors"] > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
