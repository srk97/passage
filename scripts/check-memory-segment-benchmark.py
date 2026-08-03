#!/usr/bin/env python3
"""Fail-closed validation for Passage's frozen MemorySegment benchmark."""

from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 3
PROTOCOL_REVISION = "chronicle.memory-segment-benchmark-protocol.v3"
CORPUS_REVISION = "chronicle.memory-segment-benchmark-corpus.v2"
REBUILD_LIMIT_MS = 60_000.0
INDEX_OVERHEAD_RATIO_LIMIT = 0.25
INDEX_BYTES_PER_FRAME_LIMIT = 384.0
MAINTENANCE_CAPTURE_WAL_AMPLIFICATION_LIMIT = 2.0
MAXIMUM_FRAMES_PER_SEGMENT = 64
SQLITE_PENDING_BYTE = 0x40000000

REQUIRED_EXCLUDED_CLAIMS = {
    "concurrent-writer-contention",
    "device-level-physical-write-amplification",
    "end-to-end-product-latency",
    "media-io-or-decoding",
    "physical-cold-disk-latency",
    "real-world-relevance",
}

REQUIRED_VALIDATIONS = {
    "agent_privacy_full_cursor_walk_matches",
    "canonical_frame_count_matches",
    "capture_keeps_index_ready_and_available",
    "corpus_exact_counts_match",
    "corpus_protocol_matches_revision",
    "dirty_overlay_retrieves_all_appended_frame_ids",
    "domainless_context_is_preserved",
    "fresh_connection_first_query_available",
    "first_page_hydration_within_limit",
    "frame_key_support_objects_are_accounted",
    "full_cursor_walks_match_expected_results",
    "index_ready_after_rebuild",
    "maintenance_queue_drains_to_zero",
    "post_maintenance_index_counts_match",
    "post_maintenance_result_equals_dirty_overlay",
    "post_maintenance_revision_equals_dirty_overlay",
    "rebuild_revision_is_deterministic",
    "segment_count_matches_deterministic_corpus",
    "shadow_footprint_is_positive",
    "verification_storage_growth_within_budget",
    "storage_is_checkpointed",
    "workload_access_boundaries_match",
    "workload_first_page_counts_match",
    "write_amplification_samples_are_nonzero",
}

NESTED_KEYS = {
    "system": {"operating_system", "architecture", "processor_count"},
    "configuration": {
        "profile", "run_ordinal", "required_run_count", "frame_count", "sample_count",
        "fresh_connection_sample_count", "batch_size", "frames_per_session",
        "context_key_count", "page_limit", "capture_probe_count",
    },
    "corpus": {
        "revision", "session_count", "sensitive_session_count", "application_count",
        "site_count", "topic_count", "context_key_frame_distribution",
        "domainless_context_key", "needle_frame_index", "needle_frame_count",
        "expected_segment_count", "expected_agent_safe_segment_count",
        "expected_topic42_segment_count", "expected_topic42_frame_count",
        "expected_topic42_app2_site12_segment_count",
        "expected_topic42_app2_site12_frame_count",
        "expected_app2_site12_segment_count", "expected_app2_site12_frame_count",
        "expected_agent_safe_topic42_segment_count",
        "expected_agent_safe_topic42_frame_count",
    },
    "seed": {"total_milliseconds", "frames_per_second", "batch_latency", "checkpoint_milliseconds"},
    "index": {
        "lifecycle", "last_full_rebuild_revision", "canonical_frame_count", "segment_count",
        "pending_session_count", "initial_rebuild_milliseconds",
        "initial_checkpoint_milliseconds", "verification_rebuild_milliseconds",
        "verification_checkpoint_milliseconds", "deterministic_last_full_rebuild_revision",
    },
    "storage": {
        "measurement", "accounting_notes", "before_index", "after_initial_index",
        "after_verification_index",
        "shadow_bytes_per_frame", "shadow_overhead_ratio",
        "verification_shadow_growth_bytes", "verification_shadow_growth_budget_bytes",
        "stable_across_verification_rebuild",
        "media_bytes", "memory_segment_schema_objects", "memory_segment_db_stat_objects",
        "capture_wal_bytes", "maintenance_wal_bytes",
        "maintenance_to_capture_wal_amplification", "write_amplification_scope",
    },
    "storage_snapshot": {
        "logical_main_file_bytes", "page_size_bytes", "page_count", "freelist_page_count",
        "live_database_bytes", "memory_segment_shadow_bytes", "canonical_live_bytes",
        "memory_segment_object_live_bytes",
    },
    "storage_object": {"name", "live_bytes"},
    "workload": {
        "name", "access_boundary", "request_shape", "sample_count",
        "expected_first_page_segment_count", "expected_total_segment_count", "latency",
        "minimum_returned_segments", "maximum_returned_segments", "first_page_hydration",
        "omission_reasons",
    },
    "first_page_hydration": {
        "measurement", "measurement_count", "canonical_frame_limit",
        "minimum_hydrated_canonical_frame_count",
        "maximum_hydrated_canonical_frame_count", "minimum_returned_frame_count",
        "maximum_returned_frame_count", "minimum_hydration_surplus", "within_limit",
    },
    "cursor_walk": {
        "name", "access_boundary", "page_limit", "expected_segment_count",
        "returned_segment_count", "expected_frame_count", "returned_unique_frame_count",
        "page_count", "access_boundary_stable", "revision_stable", "strict_order",
        "no_duplicate_segments", "no_duplicate_frames", "agent_safe_segments",
        "policy_omission_count_hidden", "terminated", "omission_reasons",
    },
    "fresh_connection": {
        "name", "access_boundary", "cache_state", "sample_count",
        "expected_first_page_segment_count", "open_latency", "first_query_latency",
        "open_and_first_latency", "minimum_returned_segments", "maximum_returned_segments",
        "first_page_hydration", "retrieval_available", "omission_reasons",
    },
    "capture_probe": {
        "appended_frame_count", "expected_appended_frame_id_count",
        "retrieved_appended_frame_id_count", "insert_latency", "lifecycle_after_append",
        "pending_session_count_after_append", "dirty_overlay_segment_count",
        "dirty_overlay_frame_count", "dirty_overlay_contains_every_appended_frame_id",
        "dirty_overlay_revision", "retrieval_available_after_append",
        "retrieval_omission_reasons", "interference_model",
    },
    "maintenance": {
        "attempt_count", "maintained_session_count", "deferred_session_count",
        "reached_no_work", "latency", "lifecycle_after_maintenance",
        "pending_session_count_after_maintenance", "canonical_frame_count_after_maintenance",
        "segment_count_after_maintenance", "expected_segment_count_after_maintenance",
        "post_maintenance_equals_dirty_overlay",
        "post_maintenance_revision_equals_dirty_overlay",
        "retrieval_available_after_maintenance", "retrieval_omission_reasons",
    },
}

MEMORY_SEGMENT_SCHEMA_OBJECTS = [
    "frame_key_sequence", "frames_frame_key",
    "memory_segment_dirty_sessions", "memory_segment_dirty_sessions_order",
    "memory_segment_index_state", "memory_segment_members",
    "memory_segments", "memory_segments_context_order", "memory_segments_order",
    "sqlite_autoindex_memory_segment_members_1", "sqlite_autoindex_memory_segments_1",
    "sqlite_autoindex_memory_segments_2",
]
MEMORY_SEGMENT_DBSTAT_OBJECTS = list(MEMORY_SEGMENT_SCHEMA_OBJECTS)
STORAGE_ACCOUNTING_NOTES = [
    "frame-key-sequence-and-frames-frame-key-index-count-as-shadow-support",
    (
        "frames.frame_key-column-bytes-remain-in-canonical-frames-btree-and-are-not-"
        "separable-by-dbstat"
    ),
    (
        "sqlite-pending-byte-locking-page-excluded-from-dbstat-when-main-db-exceeds-"
        "0x40000000-bytes"
    ),
]

MILLION_WORKLOAD_P95_MS = {
    "private_full_browse": 150.0,
    "private_topic42": 100.0,
    "private_topic42_app2_site12": 100.0,
    "private_metadata_app2_site12": 100.0,
    "private_needle4242": 50.0,
    "private_zero_hit": 50.0,
    "private_session42_context": 50.0,
    "agent_topic42": 100.0,
}
SMOKE_WORKLOAD_P95_MS = {name: (1_000.0 if name == "private_full_browse" else 500.0)
                         for name in MILLION_WORKLOAD_P95_MS}

TOP_LEVEL_KEYS = {
    "schema_version",
    "protocol_revision",
    "benchmark",
    "claim_scope",
    "cache_state",
    "corpus_kind",
    "media_fixture",
    "excluded_claims",
    "generated_at",
    "system",
    "configuration",
    "corpus",
    "seed",
    "storage",
    "index",
    "workloads",
    "cursor_walks",
    "fresh_connection",
    "capture_probe",
    "maintenance",
    "validations",
}

WORKLOAD_SHAPES = {
    "private_full_browse": ("privateLocal", "all-segments-first-page"),
    "private_topic42": ("privateLocal", "saved-text:topic42"),
    "private_topic42_app2_site12": (
        "privateLocal",
        "saved-text:topic42+app.fixture.2+site12.example",
    ),
    "private_metadata_app2_site12": (
        "privateLocal",
        "app.fixture.2+site12.example",
    ),
    "private_needle4242": ("privateLocal", "saved-text:needle4242"),
    "private_zero_hit": (
        "privateLocal",
        "saved-text:termdoesnotexistpassage",
    ),
    "private_session42_context": ("privateLocal", "activity-session:42"),
    "agent_topic42": ("agentSafe", "saved-text:topic42+agent-safe"),
}

PROFILE_PROTOCOLS: dict[str, dict[str, Any]] = {
    "million": {
        "configuration": {
            "required_run_count": 3,
            "frame_count": 1_000_000,
            "sample_count": 50,
            "fresh_connection_sample_count": 50,
            "batch_size": 5_000,
            "frames_per_session": 100,
            "context_key_count": 4,
            "page_limit": 50,
            "capture_probe_count": 50,
        },
        "corpus": {
            "session_count": 10_000,
            "sensitive_session_count": 589,
            "expected_segment_count": 50_000,
            "expected_agent_safe_segment_count": 47_055,
            "expected_topic42_segment_count": 390,
            "expected_topic42_frame_count": 7_800,
            "expected_topic42_app2_site12_segment_count": 12,
            "expected_topic42_app2_site12_frame_count": 420,
            "expected_app2_site12_segment_count": 332,
            "expected_app2_site12_frame_count": 11_620,
            "expected_agent_safe_topic42_segment_count": 365,
            "expected_agent_safe_topic42_frame_count": 7_300,
        },
        "workloads": {
            "private_full_browse": (50, 50_000, 1_000_000),
            "private_topic42": (50, 390, 7_800),
            "private_topic42_app2_site12": (12, 12, 420),
            "private_metadata_app2_site12": (50, 332, 11_620),
            "private_needle4242": (1, 1, 1),
            "private_zero_hit": (0, 0, 0),
            "private_session42_context": (5, 5, 100),
            "agent_topic42": (50, 365, 7_300),
        },
    },
    "smoke": {
        "configuration": {
            "required_run_count": 1,
            "frame_count": 20_000,
            "sample_count": 5,
            "fresh_connection_sample_count": 5,
            "batch_size": 5_000,
            "frames_per_session": 100,
            "context_key_count": 4,
            "page_limit": 50,
            "capture_probe_count": 50,
        },
        "corpus": {
            "session_count": 200,
            "sensitive_session_count": 12,
            "expected_segment_count": 1_000,
            "expected_agent_safe_segment_count": 940,
            "expected_topic42_segment_count": 10,
            "expected_topic42_frame_count": 200,
            "expected_topic42_app2_site12_segment_count": 2,
            "expected_topic42_app2_site12_frame_count": 70,
            "expected_app2_site12_segment_count": 6,
            "expected_app2_site12_frame_count": 210,
            "expected_agent_safe_topic42_segment_count": 5,
            "expected_agent_safe_topic42_frame_count": 100,
        },
        "workloads": {
            "private_full_browse": (50, 1_000, 20_000),
            "private_topic42": (10, 10, 200),
            "private_topic42_app2_site12": (2, 2, 70),
            "private_metadata_app2_site12": (6, 6, 210),
            "private_needle4242": (1, 1, 1),
            "private_zero_hit": (0, 0, 0),
            "private_session42_context": (5, 5, 100),
            "agent_topic42": (5, 5, 100),
        },
    },
}


def sqlite_reserved_locking_page_count(page_count: float, page_size: float) -> int:
    """Return SQLite's non-btree locking page once the main DB crosses PENDING_BYTE."""
    return int(page_count * page_size > SQLITE_PENDING_BYTE)


def expected_dbstat_live_bytes(
    page_count: float,
    page_size: float,
    freelist_page_count: float,
) -> float:
    reserved_page_count = sqlite_reserved_locking_page_count(page_count, page_size)
    return page_size * (page_count - freelist_page_count - reserved_page_count)


class Gate:
    def __init__(self, prefix: str) -> None:
        self.prefix = prefix
        self.failures: list[str] = []

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.failures.append(f"{self.prefix}: {message}")

    def equal(self, actual: Any, expected: Any, label: str) -> None:
        self.require(actual == expected, f"{label} must be {expected!r}; got {actual!r}")

    def finite(self, value: Any, label: str, *, minimum: float = 0.0) -> float | None:
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            self.failures.append(f"{self.prefix}: {label} must be numeric")
            return None
        numeric = float(value)
        if not math.isfinite(numeric):
            self.failures.append(f"{self.prefix}: {label} must be finite")
            return None
        if numeric < minimum:
            self.failures.append(
                f"{self.prefix}: {label} is {numeric:.6f}; minimum is {minimum:.6f}"
            )
        return numeric

    def integer(self, value: Any, label: str, *, minimum: int = 0) -> int | None:
        if not isinstance(value, int) or isinstance(value, bool):
            self.failures.append(f"{self.prefix}: {label} must be an integer")
            return None
        if value < minimum:
            self.failures.append(
                f"{self.prefix}: {label} is {value}; minimum is {minimum}"
            )
        return value

    def at_most(self, value: Any, limit: float, label: str) -> float | None:
        numeric = self.finite(value, label)
        if numeric is not None and numeric > limit:
            self.failures.append(
                f"{self.prefix}: {label} is {numeric:.6f}; gate is <= {limit:.6f}"
            )
        return numeric

    def object(self, value: Any, label: str) -> dict[str, Any] | None:
        if not isinstance(value, dict):
            self.failures.append(f"{self.prefix}: {label} must be an object")
            return None
        return value

    def array(self, value: Any, label: str) -> list[Any] | None:
        if not isinstance(value, list):
            self.failures.append(f"{self.prefix}: {label} must be an array")
            return None
        return value


def load_report(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("report root must be an object")
    return value


def validate_latency(gate: Gate, value: Any, label: str) -> dict[str, float] | None:
    latency = gate.object(value, label)
    if latency is None:
        return None
    expected_keys = {
        "minimum_milliseconds",
        "p50_milliseconds",
        "p95_milliseconds",
        "maximum_milliseconds",
    }
    gate.equal(set(latency), expected_keys, f"{label} keys")
    numbers: dict[str, float] = {}
    for key in expected_keys:
        numeric = gate.finite(latency.get(key), f"{label}.{key}")
        if numeric is not None:
            numbers[key] = numeric
    if len(numbers) == 4:
        gate.require(
            numbers["minimum_milliseconds"] <= numbers["p50_milliseconds"]
            <= numbers["p95_milliseconds"] <= numbers["maximum_milliseconds"],
            f"{label} percentiles must be monotonic",
        )
    return numbers


def validate_first_page_hydration(
    gate: Gate,
    value: Any,
    label: str,
    canonical_frame_limit: int,
    expected_measurement_count: int,
) -> dict[str, int] | None:
    hydration = gate.object(value, label)
    if hydration is None:
        return None
    gate.equal(set(hydration), NESTED_KEYS["first_page_hydration"], f"{label} keys")
    gate.equal(
        hydration.get("measurement"),
        "canonical-frame-decode-loop-rows",
        f"{label}.measurement",
    )
    gate.equal(
        hydration.get("canonical_frame_limit"),
        canonical_frame_limit,
        f"{label}.canonical_frame_limit",
    )
    gate.equal(
        hydration.get("measurement_count"),
        expected_measurement_count,
        f"{label}.measurement_count",
    )
    values: dict[str, int] = {}
    for key in (
        "minimum_hydrated_canonical_frame_count",
        "maximum_hydrated_canonical_frame_count",
        "minimum_returned_frame_count",
        "maximum_returned_frame_count",
    ):
        integer = gate.integer(hydration.get(key), f"{label}.{key}")
        if integer is not None:
            values[key] = integer
    minimum_surplus = gate.integer(
        hydration.get("minimum_hydration_surplus"),
        f"{label}.minimum_hydration_surplus",
    )
    if minimum_surplus is not None:
        values["minimum_hydration_surplus"] = minimum_surplus
    if len(values) == 5:
        minimum_hydrated = values["minimum_hydrated_canonical_frame_count"]
        maximum_hydrated = values["maximum_hydrated_canonical_frame_count"]
        minimum_returned = values["minimum_returned_frame_count"]
        maximum_returned = values["maximum_returned_frame_count"]
        gate.require(
            minimum_hydrated <= maximum_hydrated,
            f"{label} hydrated frame range must be monotonic",
        )
        gate.require(
            minimum_returned <= maximum_returned,
            f"{label} returned frame range must be monotonic",
        )
        gate.require(
            minimum_hydrated >= minimum_returned
            and maximum_hydrated >= maximum_returned,
            f"{label} cannot hydrate fewer canonical frames than it returns",
        )
        gate.require(
            maximum_hydrated <= canonical_frame_limit,
            f"{label} hydrated {maximum_hydrated} canonical frames; "
            f"limit is {canonical_frame_limit}",
        )
    gate.require(hydration.get("within_limit") is True, f"{label}.within_limit must be true")
    return values


def indexed_entries(
    gate: Gate,
    raw: Any,
    label: str,
) -> dict[str, dict[str, Any]]:
    entries = gate.array(raw, label)
    if entries is None:
        return {}
    result: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(entries):
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            gate.failures.append(f"{gate.prefix}: {label}[{index}] is malformed")
            continue
        name = item["name"]
        if name in result:
            gate.failures.append(f"{gate.prefix}: duplicate {label} entry {name!r}")
        result[name] = item
    return result


def maximum_numeric(values: Any) -> float | None:
    numeric = [
        float(value)
        for value in values
        if isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    ]
    return max(numeric, default=None)


def storage_object_byte_mapping(snapshot: Any) -> dict[str, Any]:
    if not isinstance(snapshot, dict):
        return {}
    entries = snapshot.get("memory_segment_object_live_bytes")
    if not isinstance(entries, list):
        return {}
    return {
        item["name"]: item.get("live_bytes")
        for item in entries
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }


def validate_report(
    report: dict[str, Any],
    path: Path,
    correctness_only: bool,
) -> tuple[list[str], dict[str, Any]]:
    gate = Gate(str(path))
    gate.equal(set(report), TOP_LEVEL_KEYS, "top-level keys")
    gate.equal(report.get("schema_version"), SCHEMA_VERSION, "schema_version")
    gate.equal(report.get("protocol_revision"), PROTOCOL_REVISION, "protocol_revision")
    gate.equal(report.get("benchmark"), "chronicle-memory-segments", "benchmark")
    gate.equal(report.get("claim_scope"), "store-only", "claim_scope")
    gate.equal(report.get("cache_state"), "warm-os-cache", "cache_state")
    gate.equal(report.get("corpus_kind"), "synthetic-deterministic", "corpus_kind")
    gate.equal(
        report.get("media_fixture"),
        "path-references-only-no-media-files",
        "media_fixture",
    )
    excluded = report.get("excluded_claims")
    gate.require(
        isinstance(excluded, list) and set(excluded) == REQUIRED_EXCLUDED_CLAIMS,
        "excluded_claims must exactly preserve store-only/warm-cache/synthetic/no-media disclaimers",
    )

    generated_at = report.get("generated_at")
    try:
        parsed_timestamp = datetime.fromisoformat(str(generated_at).replace("Z", "+00:00"))
        gate.require(parsed_timestamp.tzinfo is not None, "generated_at must include a timezone")
    except (TypeError, ValueError):
        gate.require(False, "generated_at must be an ISO-8601 timestamp")

    system = gate.object(report.get("system"), "system")
    configuration = gate.object(report.get("configuration"), "configuration")
    corpus = gate.object(report.get("corpus"), "corpus")
    seed = gate.object(report.get("seed"), "seed")
    storage = gate.object(report.get("storage"), "storage")
    index = gate.object(report.get("index"), "index")
    fresh = gate.object(report.get("fresh_connection"), "fresh_connection")
    capture = gate.object(report.get("capture_probe"), "capture_probe")
    maintenance = gate.object(report.get("maintenance"), "maintenance")
    validations = gate.object(report.get("validations"), "validations")
    if any(value is None for value in (
        system, configuration, corpus, seed, storage, index, fresh, capture, maintenance,
        validations,
    )):
        return gate.failures, {}
    assert system is not None
    assert configuration is not None
    assert corpus is not None
    assert seed is not None
    assert storage is not None
    assert index is not None
    assert fresh is not None
    assert capture is not None
    assert maintenance is not None
    assert validations is not None

    for label, value in (
        ("system", system),
        ("configuration", configuration),
        ("corpus", corpus),
        ("seed", seed),
        ("storage", storage),
        ("index", index),
        ("fresh_connection", fresh),
        ("capture_probe", capture),
        ("maintenance", maintenance),
    ):
        gate.equal(set(value), NESTED_KEYS[label], f"{label} keys")

    profile = configuration.get("profile")
    gate.require(
        isinstance(profile, str) and profile in PROFILE_PROTOCOLS,
        f"unknown profile {profile!r}",
    )
    if not isinstance(profile, str) or profile not in PROFILE_PROTOCOLS:
        return gate.failures, {}
    protocol = PROFILE_PROTOCOLS[profile]
    for key, expected in protocol["configuration"].items():
        gate.equal(configuration.get(key), expected, f"configuration.{key}")
    run_ordinal = configuration.get("run_ordinal")
    gate.require(
        isinstance(run_ordinal, int)
        and not isinstance(run_ordinal, bool)
        and 1 <= run_ordinal <= protocol["configuration"]["required_run_count"],
        "configuration.run_ordinal is outside the frozen run set",
    )

    gate.equal(corpus.get("revision"), CORPUS_REVISION, "corpus.revision")
    fixed_corpus = {
        "application_count": 20,
        "site_count": 30,
        "topic_count": 128,
        "context_key_frame_distribution": [70, 20, 8, 2],
        "domainless_context_key": 3,
        "needle_frame_index": 4_242,
        "needle_frame_count": 1,
    }
    for key, expected in fixed_corpus.items():
        gate.equal(corpus.get(key), expected, f"corpus.{key}")
    for key, expected in protocol["corpus"].items():
        gate.equal(corpus.get(key), expected, f"corpus.{key}")

    gate.equal(set(validations), REQUIRED_VALIDATIONS, "validations keys")
    for name in sorted(REQUIRED_VALIDATIONS):
        gate.require(validations.get(name) is True, f"validation failed: {name}")

    gate.equal(index.get("lifecycle"), "ready", "index.lifecycle")
    gate.equal(
        index.get("canonical_frame_count"),
        configuration.get("frame_count"),
        "index.canonical_frame_count",
    )
    gate.equal(
        index.get("segment_count"),
        corpus.get("expected_segment_count"),
        "index.segment_count",
    )
    gate.equal(index.get("pending_session_count"), 0, "index.pending_session_count")
    gate.require(
        isinstance(index.get("last_full_rebuild_revision"), str)
        and len(index["last_full_rebuild_revision"]) == 64,
        "index.last_full_rebuild_revision must be a 64-character digest",
    )
    gate.require(
        index.get("deterministic_last_full_rebuild_revision") is True,
        "index deterministic last-full-rebuild revision must be true",
    )
    validate_latency(gate, seed.get("batch_latency"), "seed.batch_latency")
    gate.finite(seed.get("total_milliseconds"), "seed.total_milliseconds")
    gate.finite(seed.get("frames_per_second"), "seed.frames_per_second")
    gate.finite(
        seed.get("checkpoint_milliseconds"),
        "seed.checkpoint_milliseconds",
    )
    for key in (
        "initial_rebuild_milliseconds",
        "initial_checkpoint_milliseconds",
        "verification_rebuild_milliseconds",
        "verification_checkpoint_milliseconds",
    ):
        gate.finite(index.get(key), f"index.{key}")
    if not correctness_only:
        gate.at_most(
            index.get("initial_rebuild_milliseconds"),
            REBUILD_LIMIT_MS,
            "index.initial_rebuild_milliseconds",
        )
        gate.at_most(
            index.get("verification_rebuild_milliseconds"),
            REBUILD_LIMIT_MS,
            "index.verification_rebuild_milliseconds",
        )

    gate.equal(
        storage.get("measurement"),
        "checkpointed-dbstat-v3-exact-memory-segment-shadow-live-bytes",
        "storage.measurement",
    )
    gate.equal(
        storage.get("accounting_notes"),
        STORAGE_ACCOUNTING_NOTES,
        "storage.accounting_notes",
    )
    gate.equal(storage.get("media_bytes"), 0, "storage.media_bytes")
    gate.equal(
        storage.get("memory_segment_schema_objects"),
        MEMORY_SEGMENT_SCHEMA_OBJECTS,
        "storage.memory_segment_schema_objects",
    )
    gate.equal(
        storage.get("memory_segment_db_stat_objects"),
        MEMORY_SEGMENT_DBSTAT_OBJECTS,
        "storage.memory_segment_db_stat_objects",
    )
    snapshots: dict[str, dict[str, Any]] = {}
    for name in ("before_index", "after_initial_index", "after_verification_index"):
        snapshot = gate.object(storage.get(name), f"storage.{name}")
        if snapshot is None:
            continue
        snapshots[name] = snapshot
        gate.equal(set(snapshot), NESTED_KEYS["storage_snapshot"], f"storage.{name} keys")
        file_bytes = gate.finite(
            snapshot.get("logical_main_file_bytes"),
            f"storage.{name}.logical_main_file_bytes",
            minimum=1,
        )
        page_size = gate.finite(
            snapshot.get("page_size_bytes"), f"storage.{name}.page_size_bytes", minimum=1
        )
        page_count = gate.finite(
            snapshot.get("page_count"), f"storage.{name}.page_count", minimum=1
        )
        freelist = gate.finite(
            snapshot.get("freelist_page_count"),
            f"storage.{name}.freelist_page_count",
        )
        live_bytes = gate.finite(
            snapshot.get("live_database_bytes"),
            f"storage.{name}.live_database_bytes",
            minimum=1,
        )
        shadow_bytes = gate.finite(
            snapshot.get("memory_segment_shadow_bytes"),
            f"storage.{name}.memory_segment_shadow_bytes",
            minimum=1,
        )
        canonical_bytes = gate.finite(
            snapshot.get("canonical_live_bytes"),
            f"storage.{name}.canonical_live_bytes",
            minimum=1,
        )
        object_bytes = indexed_entries(
            gate,
            snapshot.get("memory_segment_object_live_bytes"),
            f"storage.{name}.memory_segment_object_live_bytes",
        )
        gate.equal(
            set(object_bytes),
            set(MEMORY_SEGMENT_DBSTAT_OBJECTS),
            f"storage.{name} object-byte names",
        )
        object_byte_total = 0
        for object_name, item in object_bytes.items():
            gate.equal(
                set(item),
                NESTED_KEYS["storage_object"],
                f"storage.{name}.{object_name} keys",
            )
            item_bytes = gate.integer(
                item.get("live_bytes"),
                f"storage.{name}.{object_name}.live_bytes",
                minimum=1,
            )
            if item_bytes is not None:
                object_byte_total += item_bytes
                if page_size is not None:
                    gate.require(
                        item_bytes % int(page_size) == 0,
                        f"storage.{name}.{object_name}.live_bytes is not page-aligned",
                    )
        if None not in (file_bytes, page_size, page_count, freelist, live_bytes):
            assert file_bytes is not None and page_size is not None
            assert page_count is not None and freelist is not None and live_bytes is not None
            reserved_page_count = sqlite_reserved_locking_page_count(page_count, page_size)
            gate.require(
                freelist + reserved_page_count <= page_count,
                f"storage.{name} freelist plus reserved locking page exceeds page count",
            )
            gate.require(
                abs(file_bytes - page_size * page_count) < 0.5,
                f"storage.{name} file bytes do not match page_count * page_size",
            )
            gate.require(
                abs(
                    live_bytes
                    - expected_dbstat_live_bytes(page_count, page_size, freelist)
                ) < 0.5,
                (
                    f"storage.{name} live bytes do not match page_size * "
                    "(page_count - freelist - SQLite reserved locking page count)"
                ),
            )
        if live_bytes is not None and shadow_bytes is not None and canonical_bytes is not None:
            gate.require(
                abs(live_bytes - shadow_bytes - canonical_bytes) < 0.5,
                f"storage.{name} dbstat partition is inconsistent",
            )
        if shadow_bytes is not None:
            gate.require(
                abs(shadow_bytes - object_byte_total) < 0.5,
                f"storage.{name} per-object bytes do not sum to shadow bytes",
            )

    initial_snapshot = snapshots.get("after_initial_index")
    verification_snapshot = snapshots.get("after_verification_index")
    shadow_per_frame = gate.finite(
        storage.get("shadow_bytes_per_frame"), "storage.shadow_bytes_per_frame"
    )
    shadow_ratio = gate.finite(
        storage.get("shadow_overhead_ratio"), "storage.shadow_overhead_ratio"
    )
    growth = gate.finite(
        storage.get("verification_shadow_growth_bytes"),
        "storage.verification_shadow_growth_bytes",
        minimum=-float("inf"),
    )
    growth_budget = gate.finite(
        storage.get("verification_shadow_growth_budget_bytes"),
        "storage.verification_shadow_growth_budget_bytes",
        minimum=1,
    )
    if initial_snapshot is not None and verification_snapshot is not None:
        initial_shadow = initial_snapshot.get("memory_segment_shadow_bytes")
        canonical_live = initial_snapshot.get("canonical_live_bytes")
        verification_shadow = verification_snapshot.get("memory_segment_shadow_bytes")
        if all(
            isinstance(value, (int, float)) and not isinstance(value, bool)
            for value in (initial_shadow, canonical_live, verification_shadow)
        ):
            expected_per_frame = float(initial_shadow) / configuration["frame_count"]
            expected_ratio = float(initial_shadow) / float(canonical_live)
            expected_growth = float(verification_shadow) - float(initial_shadow)
            expected_budget = max(
                16 * int(initial_snapshot["page_size_bytes"]),
                math.ceil(float(initial_shadow) * 0.001),
            )
            if shadow_per_frame is not None:
                gate.require(
                    abs(shadow_per_frame - expected_per_frame) < 1e-9,
                    "storage shadow bytes/frame is inconsistent",
                )
            if shadow_ratio is not None:
                gate.require(
                    abs(shadow_ratio - expected_ratio) < 1e-9,
                    "storage shadow overhead ratio is inconsistent",
                )
            if growth is not None:
                gate.require(
                    abs(growth - expected_growth) < 0.5,
                    "storage verification shadow growth is inconsistent",
                )
            if growth_budget is not None:
                gate.require(
                    abs(growth_budget - expected_budget) < 0.5,
                    "storage verification growth budget is inconsistent",
                )
            gate.equal(
                verification_snapshot.get("canonical_live_bytes"),
                initial_snapshot.get("canonical_live_bytes"),
                "storage canonical live bytes across verification rebuild",
            )
            gate.require(
                abs(expected_growth) <= expected_budget,
                "storage verification shadow growth exceeds the frozen allocator-noise budget",
            )
    gate.require(
        storage.get("stable_across_verification_rebuild") is True,
        "storage verification growth must remain within the frozen budget",
    )
    if not correctness_only:
        ratio_limit = INDEX_OVERHEAD_RATIO_LIMIT if profile == "million" else 0.75
        bytes_limit = INDEX_BYTES_PER_FRAME_LIMIT if profile == "million" else 1_200.0
        gate.at_most(
            storage.get("shadow_overhead_ratio"),
            ratio_limit,
            "storage.shadow_overhead_ratio",
        )
        gate.at_most(
            storage.get("shadow_bytes_per_frame"),
            bytes_limit,
            "storage.shadow_bytes_per_frame",
        )

    capture_wal = gate.finite(
        storage.get("capture_wal_bytes"),
        "storage.capture_wal_bytes",
        minimum=1,
    )
    maintenance_wal = gate.finite(
        storage.get("maintenance_wal_bytes"),
        "storage.maintenance_wal_bytes",
        minimum=1,
    )
    amplification = gate.finite(
        storage.get("maintenance_to_capture_wal_amplification"),
        "storage.maintenance_to_capture_wal_amplification",
    )
    gate.equal(
        storage.get("write_amplification_scope"),
        "incremental-maintenance-to-capture-wal-proxy-not-device-writes",
        "storage.write_amplification_scope",
    )
    if capture_wal is not None and maintenance_wal is not None and amplification is not None:
        expected_amplification = maintenance_wal / max(capture_wal, 1)
        gate.require(
            abs(amplification - expected_amplification) < 1e-9,
            "storage WAL amplification is inconsistent",
        )
    if not correctness_only:
        gate.at_most(
            storage.get("maintenance_to_capture_wal_amplification"),
            MAINTENANCE_CAPTURE_WAL_AMPLIFICATION_LIMIT,
            "storage.maintenance_to_capture_wal_amplification",
        )

    workloads = indexed_entries(gate, report.get("workloads"), "workloads")
    gate.equal(set(workloads), set(WORKLOAD_SHAPES), "workload names")
    sample_count = configuration["sample_count"]
    hydration_frame_limit = configuration["page_limit"] * MAXIMUM_FRAMES_PER_SEGMENT
    workload_hydration_maxima: dict[str, int | None] = {}
    for name, (boundary, shape) in WORKLOAD_SHAPES.items():
        workload = workloads.get(name)
        if workload is None:
            continue
        gate.equal(set(workload), NESTED_KEYS["workload"], f"{name} keys")
        first_count, total_count, _ = protocol["workloads"][name]
        gate.equal(workload.get("access_boundary"), boundary, f"{name}.access_boundary")
        gate.equal(workload.get("request_shape"), shape, f"{name}.request_shape")
        gate.equal(workload.get("sample_count"), sample_count, f"{name}.sample_count")
        gate.equal(
            workload.get("expected_first_page_segment_count"),
            first_count,
            f"{name}.expected_first_page_segment_count",
        )
        gate.equal(
            workload.get("expected_total_segment_count"),
            total_count,
            f"{name}.expected_total_segment_count",
        )
        gate.equal(workload.get("minimum_returned_segments"), first_count, f"{name}.minimum")
        gate.equal(workload.get("maximum_returned_segments"), first_count, f"{name}.maximum")
        expected_omissions = ["policyFiltered"] if name == "agent_topic42" else []
        gate.equal(workload.get("omission_reasons"), expected_omissions, f"{name}.omissions")
        hydration = validate_first_page_hydration(
            gate,
            workload.get("first_page_hydration"),
            f"{name}.first_page_hydration",
            hydration_frame_limit,
            sample_count + 1,
        )
        workload_hydration_maxima[name] = hydration.get(
            "maximum_hydrated_canonical_frame_count"
        ) if hydration is not None else None
        latency = validate_latency(gate, workload.get("latency"), f"{name}.latency")
        if not correctness_only and latency is not None:
            latency_limit = (
                MILLION_WORKLOAD_P95_MS[name]
                if profile == "million"
                else SMOKE_WORKLOAD_P95_MS[name]
            )
            gate.at_most(
                latency.get("p95_milliseconds"),
                latency_limit,
                f"{name}.latency.p95_milliseconds",
            )
            if sample_count < 20:
                gate.at_most(
                    latency.get("maximum_milliseconds"),
                    latency_limit,
                    f"{name}.latency.maximum_milliseconds",
                )

    walks = indexed_entries(gate, report.get("cursor_walks"), "cursor_walks")
    expected_walk_names = set(WORKLOAD_SHAPES) - {"private_full_browse"}
    gate.equal(set(walks), expected_walk_names, "cursor walk names")
    for name in sorted(expected_walk_names):
        walk = walks.get(name)
        if walk is None:
            continue
        gate.equal(set(walk), NESTED_KEYS["cursor_walk"], f"cursor {name} keys")
        boundary = WORKLOAD_SHAPES[name][0]
        _, total_count, frame_count = protocol["workloads"][name]
        expected_pages = max(1, math.ceil(total_count / configuration["page_limit"]))
        gate.equal(walk.get("access_boundary"), boundary, f"cursor {name}.access_boundary")
        gate.equal(walk.get("page_limit"), 50, f"cursor {name}.page_limit")
        gate.equal(walk.get("expected_segment_count"), total_count, f"cursor {name}.expected segments")
        gate.equal(walk.get("returned_segment_count"), total_count, f"cursor {name}.returned segments")
        gate.equal(walk.get("expected_frame_count"), frame_count, f"cursor {name}.expected frames")
        gate.equal(walk.get("returned_unique_frame_count"), frame_count, f"cursor {name}.returned frames")
        gate.equal(walk.get("page_count"), expected_pages, f"cursor {name}.page_count")
        for flag in (
            "access_boundary_stable",
            "revision_stable",
            "strict_order",
            "no_duplicate_segments",
            "no_duplicate_frames",
            "agent_safe_segments",
            "policy_omission_count_hidden",
            "terminated",
        ):
            gate.require(walk.get(flag) is True, f"cursor {name}.{flag} must be true")
        expected_omissions = ["policyFiltered"] if name == "agent_topic42" else []
        gate.equal(walk.get("omission_reasons"), expected_omissions, f"cursor {name}.omissions")

    fresh_first = protocol["workloads"]["private_topic42_app2_site12"][0]
    gate.equal(fresh.get("name"), "private_topic42_app2_site12", "fresh_connection.name")
    gate.equal(fresh.get("access_boundary"), "privateLocal", "fresh_connection.access_boundary")
    gate.equal(
        fresh.get("cache_state"),
        "new-sqlcipher-connection-warm-os-cache",
        "fresh_connection.cache_state",
    )
    gate.equal(fresh.get("sample_count"), sample_count, "fresh_connection.sample_count")
    gate.equal(
        fresh.get("expected_first_page_segment_count"),
        fresh_first,
        "fresh_connection.expected_first_page_segment_count",
    )
    gate.equal(fresh.get("minimum_returned_segments"), fresh_first, "fresh_connection.minimum")
    gate.equal(fresh.get("maximum_returned_segments"), fresh_first, "fresh_connection.maximum")
    fresh_hydration = validate_first_page_hydration(
        gate,
        fresh.get("first_page_hydration"),
        "fresh_connection.first_page_hydration",
        hydration_frame_limit,
        sample_count,
    )
    gate.require(fresh.get("retrieval_available") is True, "fresh connection retrieval unavailable")
    gate.equal(fresh.get("omission_reasons"), [], "fresh_connection.omission_reasons")
    fresh_latencies = {
        key: validate_latency(gate, fresh.get(key), f"fresh_connection.{key}")
        for key in ("open_latency", "first_query_latency", "open_and_first_latency")
    }
    if not correctness_only and fresh_latencies["open_and_first_latency"] is not None:
        fresh_limit = 150.0 if profile == "million" else 500.0
        combined = fresh_latencies["open_and_first_latency"]
        assert combined is not None
        gate.at_most(
            combined.get("p95_milliseconds"),
            fresh_limit,
            "fresh_connection.open_and_first_latency.p95_milliseconds",
        )
        if fresh.get("sample_count", 0) < 20:
            gate.at_most(
                combined.get("maximum_milliseconds"),
                fresh_limit,
                "fresh_connection.open_and_first_latency.maximum_milliseconds",
            )

    gate.equal(capture.get("appended_frame_count"), 50, "capture_probe.appended_frame_count")
    gate.equal(
        capture.get("expected_appended_frame_id_count"),
        50,
        "capture_probe.expected_appended_frame_id_count",
    )
    gate.equal(
        capture.get("retrieved_appended_frame_id_count"),
        50,
        "capture_probe.retrieved_appended_frame_id_count",
    )
    gate.equal(capture.get("lifecycle_after_append"), "ready", "capture_probe.lifecycle")
    gate.equal(capture.get("pending_session_count_after_append"), 1, "capture_probe.pending sessions")
    gate.equal(capture.get("dirty_overlay_segment_count"), 1, "capture_probe.overlay segments")
    gate.equal(capture.get("dirty_overlay_frame_count"), 50, "capture_probe.overlay frames")
    gate.require(
        capture.get("dirty_overlay_contains_every_appended_frame_id") is True,
        "capture dirty overlay did not return every appended frame ID",
    )
    gate.require(
        isinstance(capture.get("dirty_overlay_revision"), str)
        and len(capture["dirty_overlay_revision"]) == 64,
        "capture dirty overlay revision must be a 64-character digest",
    )
    gate.require(
        capture.get("retrieval_available_after_append") is True,
        "capture made retrieval unavailable",
    )
    gate.equal(capture.get("retrieval_omission_reasons"), [], "capture omissions")
    gate.equal(
        capture.get("interference_model"),
        "capture-then-dirty-overlay-read-then-bounded-maintenance-on-one-store-actor",
        "capture_probe.interference_model",
    )
    capture_latency = validate_latency(
        gate, capture.get("insert_latency"), "capture_probe.insert_latency"
    )
    if not correctness_only and capture_latency is not None:
        capture_limit = 20.0 if profile == "million" else 500.0
        gate.at_most(
            capture_latency.get("p95_milliseconds"),
            capture_limit,
            "capture_probe.insert_latency.p95_milliseconds",
        )
        if capture.get("appended_frame_count", 0) < 20:
            gate.at_most(
                capture_latency.get("maximum_milliseconds"),
                capture_limit,
                "capture_probe.insert_latency.maximum_milliseconds",
            )

    expected_post_frames = configuration["frame_count"] + 50
    expected_post_segments = corpus["expected_segment_count"] + 1
    gate.equal(maintenance.get("attempt_count"), 2, "maintenance.attempt_count")
    gate.equal(maintenance.get("maintained_session_count"), 1, "maintenance.maintained count")
    gate.equal(maintenance.get("deferred_session_count"), 0, "maintenance.deferred count")
    gate.require(maintenance.get("reached_no_work") is True, "maintenance did not reach noWork")
    gate.equal(maintenance.get("lifecycle_after_maintenance"), "ready", "maintenance.lifecycle")
    gate.equal(
        maintenance.get("pending_session_count_after_maintenance"),
        0,
        "maintenance.pending sessions",
    )
    gate.equal(
        maintenance.get("canonical_frame_count_after_maintenance"),
        expected_post_frames,
        "maintenance.canonical frame count",
    )
    gate.equal(
        maintenance.get("segment_count_after_maintenance"),
        expected_post_segments,
        "maintenance.segment count",
    )
    gate.equal(
        maintenance.get("expected_segment_count_after_maintenance"),
        expected_post_segments,
        "maintenance.expected segment count",
    )
    for flag in (
        "post_maintenance_equals_dirty_overlay",
        "post_maintenance_revision_equals_dirty_overlay",
        "retrieval_available_after_maintenance",
    ):
        gate.require(maintenance.get(flag) is True, f"maintenance.{flag} must be true")
    gate.equal(maintenance.get("retrieval_omission_reasons"), [], "maintenance omissions")
    maintenance_latency = validate_latency(gate, maintenance.get("latency"), "maintenance.latency")
    if not correctness_only and maintenance_latency is not None:
        maintenance_limit = 20.0 if profile == "million" else 500.0
        gate.at_most(
            maintenance_latency.get("p95_milliseconds"),
            maintenance_limit,
            "maintenance.latency.p95_milliseconds",
        )
        if maintenance.get("attempt_count", 0) < 20:
            gate.at_most(
                maintenance_latency.get("maximum_milliseconds"),
                maintenance_limit,
                "maintenance.latency.maximum_milliseconds",
            )

    observed = {
        "profile": profile,
        "run_ordinal": run_ordinal,
        "generated_at": generated_at if isinstance(generated_at, str) else None,
        "initial_rebuild_ms": index.get("initial_rebuild_milliseconds"),
        "verification_rebuild_ms": index.get("verification_rebuild_milliseconds"),
        "shadow_overhead_ratio": storage.get("shadow_overhead_ratio"),
        "shadow_bytes_per_frame": storage.get("shadow_bytes_per_frame"),
        "initial_shadow_object_live_bytes": storage_object_byte_mapping(
            initial_snapshot
        ),
        "maintenance_capture_wal_amplification": storage.get(
            "maintenance_to_capture_wal_amplification"
        ),
        "workload_p95_ms": {
            name: item.get("latency", {}).get("p95_milliseconds")
            for name, item in workloads.items()
        },
        "workload_first_page_hydrated_canonical_frames": workload_hydration_maxima,
        "fresh_first_page_hydrated_canonical_frames": fresh_hydration.get(
            "maximum_hydrated_canonical_frame_count"
        ) if fresh_hydration is not None else None,
        "fresh_open_and_first_p95_ms": fresh.get("open_and_first_latency", {}).get(
            "p95_milliseconds"
        ),
    }
    return gate.failures, observed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument(
        "--correctness-only",
        action="store_true",
        help="enforce the full frozen protocol but skip numeric time/footprint ceilings",
    )
    arguments = parser.parse_args()

    failures: list[str] = []
    observed_runs: list[dict[str, Any]] = []
    for path in arguments.reports:
        try:
            report = load_report(path)
        except (OSError, json.JSONDecodeError, ValueError) as error:
            failures.append(f"{path}: cannot read benchmark JSON: {error}")
            continue
        report_failures, observed = validate_report(
            report,
            path,
            arguments.correctness_only,
        )
        failures.extend(report_failures)
        if observed:
            observed_runs.append(observed)

    profiles = {run.get("profile") for run in observed_runs}
    if len(profiles) != 1:
        failures.append("reports must all use one benchmark profile")
        profile = None
    else:
        profile = next(iter(profiles), None)
    if profile in PROFILE_PROTOCOLS:
        required_runs = PROFILE_PROTOCOLS[profile]["configuration"]["required_run_count"]
        if len(arguments.reports) != required_runs:
            failures.append(
                f"{profile} protocol requires exactly {required_runs} report(s); "
                f"got {len(arguments.reports)}"
            )
        ordinals = [run.get("run_ordinal") for run in observed_runs]
        if not all(isinstance(value, int) and not isinstance(value, bool) for value in ordinals) \
                or sorted(ordinals) != list(range(1, required_runs + 1)):
            failures.append(
                f"{profile} run ordinals must be exactly 1...{required_runs}; got {ordinals}"
            )
        timestamps = [run.get("generated_at") for run in observed_runs]
        if not all(isinstance(value, str) for value in timestamps) \
                or len(set(timestamps)) != len(timestamps):
            failures.append("every report must have a distinct generated_at timestamp")

    workload_names = sorted(
        {
            name
            for run in observed_runs
            for name in run.get("workload_p95_ms", {})
        }
    )
    worst_workload_p95 = {
        name: maximum_numeric(
            run["workload_p95_ms"].get(name)
            for run in observed_runs
            if isinstance(run.get("workload_p95_ms"), dict)
        )
        for name in workload_names
    }
    worst_workload_hydration = {
        name: maximum_numeric(
            run["workload_first_page_hydrated_canonical_frames"].get(name)
            for run in observed_runs
            if isinstance(run.get("workload_first_page_hydrated_canonical_frames"), dict)
        )
        for name in sorted(WORKLOAD_SHAPES)
    }
    worst_initial_object_bytes = {
        name: maximum_numeric(
            run["initial_shadow_object_live_bytes"].get(name)
            for run in observed_runs
            if isinstance(run.get("initial_shadow_object_live_bytes"), dict)
        )
        for name in MEMORY_SEGMENT_DBSTAT_OBJECTS
    }
    summary = {
        "gate": "chronicle-memory-segments-store-only-v3",
        "profile": profile,
        "report_count": len(arguments.reports),
        "correctness_only": arguments.correctness_only,
        "passed": not failures,
        "limits": {
            "full_rebuild_milliseconds": REBUILD_LIMIT_MS,
            "million_shadow_overhead_ratio": INDEX_OVERHEAD_RATIO_LIMIT,
            "million_shadow_bytes_per_frame": INDEX_BYTES_PER_FRAME_LIMIT,
            "maintenance_to_capture_wal_amplification": (
                MAINTENANCE_CAPTURE_WAL_AMPLIFICATION_LIMIT
            ),
            "first_page_hydrated_canonical_frames": (
                50 * MAXIMUM_FRAMES_PER_SEGMENT
            ),
        },
        "worst_observed": {
            "initial_rebuild_milliseconds": maximum_numeric(
                run.get("initial_rebuild_ms") for run in observed_runs
            ),
            "verification_rebuild_milliseconds": maximum_numeric(
                run.get("verification_rebuild_ms") for run in observed_runs
            ),
            "shadow_overhead_ratio": maximum_numeric(
                run.get("shadow_overhead_ratio") for run in observed_runs
            ),
            "shadow_bytes_per_frame": maximum_numeric(
                run.get("shadow_bytes_per_frame") for run in observed_runs
            ),
            "initial_shadow_object_live_bytes": worst_initial_object_bytes,
            "maintenance_to_capture_wal_amplification": maximum_numeric(
                run.get("maintenance_capture_wal_amplification")
                for run in observed_runs
            ),
            "fresh_open_and_first_p95_milliseconds": maximum_numeric(
                run.get("fresh_open_and_first_p95_ms") for run in observed_runs
            ),
            "fresh_first_page_hydrated_canonical_frames": maximum_numeric(
                run.get("fresh_first_page_hydrated_canonical_frames")
                for run in observed_runs
            ),
            "workload_first_page_hydrated_canonical_frames": worst_workload_hydration,
            "workload_p95_milliseconds": worst_workload_p95,
        },
        "failures": failures,
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
