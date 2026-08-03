#!/usr/bin/env python3
"""Focused regressions for benchmark report accounting rules."""

from __future__ import annotations

import runpy
import unittest
from pathlib import Path


CHECKER = runpy.run_path(
    str(Path(__file__).resolve().parents[1] / "check-memory-segment-benchmark.py"),
    run_name="passage_memory_segment_checker_under_test",
)
SQLITE_PENDING_BYTE = CHECKER["SQLITE_PENDING_BYTE"]
expected_dbstat_live_bytes = CHECKER["expected_dbstat_live_bytes"]
sqlite_reserved_locking_page_count = CHECKER["sqlite_reserved_locking_page_count"]


class SQLiteReservedLockingPageAccountingTests(unittest.TestCase):
    def test_smoke_scale_and_exact_pending_byte_boundary_have_no_reserved_page(self) -> None:
        page_size = 4_096
        boundary_page_count = SQLITE_PENDING_BYTE // page_size

        self.assertEqual(sqlite_reserved_locking_page_count(10_000, page_size), 0)
        self.assertEqual(
            sqlite_reserved_locking_page_count(boundary_page_count, page_size),
            0,
        )
        self.assertEqual(
            expected_dbstat_live_bytes(boundary_page_count, page_size, 7),
            page_size * (boundary_page_count - 7),
        )

    def test_first_page_past_pending_byte_is_reserved_from_dbstat(self) -> None:
        page_size = 4_096
        page_count = SQLITE_PENDING_BYTE // page_size + 1

        self.assertEqual(sqlite_reserved_locking_page_count(page_count, page_size), 1)
        self.assertEqual(
            expected_dbstat_live_bytes(page_count, page_size, 7),
            page_size * (page_count - 7 - 1),
        )


if __name__ == "__main__":
    unittest.main()
