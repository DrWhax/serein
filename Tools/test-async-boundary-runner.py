#!/usr/bin/env python3
"""Mutation accounting must attribute the expected assertion to the failing test."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("async_runner", Path(__file__).with_name("verify-async-boundaries.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class FailureAttributionTests(unittest.TestCase):
    def accepts(self, log):
        return runner.expected_failure(log, "target", "expected assertion")

    def test_exact_issue_with_inline_message(self):
        self.assertTrue(self.accepts("✘ Test target() recorded an issue at T.swift:3: expected assertion"))

    def test_parameterized_issue_with_continuation(self):
        self.assertTrue(self.accepts("✘ Test target(_:) recorded an issue with 1 argument at T.swift:3: Expectation failed\n↳ expected assertion\n✘ Test target(_:) failed after 0.1 seconds."))

    def test_passed_target_and_unrelated_failure_do_not_count(self):
        self.assertFalse(self.accepts("✔ Test target() passed after 0.1 seconds.\n✘ Test unrelated() recorded an issue at X.swift:1: expected assertion"))

    def test_target_start_cannot_supply_evidence(self):
        self.assertFalse(self.accepts("◇ Test target() started.\n✘ Test unrelated() recorded an issue at X.swift:1: expected assertion"))

    def test_unrelated_test_body_cannot_name_target(self):
        self.assertFalse(self.accepts("✘ Test unrelated() recorded an issue at X.swift:1: target() expected assertion"))

    def test_other_failure_in_target_does_not_count(self):
        self.assertFalse(self.accepts("✘ Test target() recorded an issue at T.swift:1: server unavailable\n✘ Test unrelated() recorded an issue at X.swift:1: expected assertion"))

    def test_test_events_end_issue_records(self):
        self.assertFalse(self.accepts("✘ Test target() recorded an issue at T.swift:1: server unavailable\n◇ Test unrelated() started.\n↳ expected assertion"))

    def test_compile_diagnostics_and_failed_summary_do_not_count(self):
        self.assertFalse(self.accepts('error: target(): expected assertion\n✘ Test target() failed after 0.1 seconds.'))

    def test_ansi_and_multiple_issues(self):
        self.assertTrue(self.accepts("✘ Test unrelated() recorded an issue at X.swift:1: server unavailable\n\x1b[31m✘ Test target() recorded an issue at T.swift:3: expected assertion\x1b[0m"))

    def test_prefix_match_is_not_an_exact_test_match(self):
        self.assertFalse(self.accepts("✘ Test targetOther() recorded an issue at X.swift:1: expected assertion"))


if __name__ == "__main__":
    unittest.main()
