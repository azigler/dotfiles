"""Guard for the `rails-session-cookie` pattern (added 2026-07-26).

Why this exists: a live AO3 `_otwarchive_session` / `remember_user_token` pair
was pasted into a Claude Code session, and `scrub scan` reported **0 matches**
on the transcript 25 minutes before the hourly vault sync would have committed
it to git history. The value is an opaque base64 blob with no distinctive
prefix, so every prefix-anchored pattern missed it; only the COOKIE NAME is
high-confidence enough to anchor on without dropping to entropy (which redact
mode forbids by design).

The negatives matter as much as the positives. This pattern is in the
high-confidence set, so `redact --apply` will rewrite anything it matches — a
false positive corrupts real content.
"""

from __future__ import annotations

import pytest

import scrub

PATTERN = scrub.PATTERNS["rails-session-cookie"]

# Structurally identical to a real cookie (base64url body, %3D url-encoding,
# the `--<sha1>` signature tail) without being a real one.
BLOB = (
    "eyJfcmFpbHMiOnsibWVzc2FnZSI6ImV5SnpaWE56YVc5dVgybGtJam9pT0RSbVlqSmlZamN3In19"
    "%3D%3D-3c43bd95974cab30f187cbcaaf2027f84efe75c8"
)


@pytest.mark.parametrize(
    "text",
    [
        pytest.param(f"_otwarchive_session {BLOB}", id="bare-name-space-value"),
        pytest.param(f"remember_user_token={BLOB}", id="devise-remember-token"),
        pytest.param(
            f"Cookie: _otwarchive_session={BLOB}; path=/", id="http-cookie-header"
        ),
        pytest.param(f'"_session_id": "{BLOB}"', id="json-serialised"),
        pytest.param(f"_myapp_session:  {BLOB}", id="generic-rails-app-session"),
    ],
)
def test_matches_real_cookie_shapes(text: str) -> None:
    assert PATTERN.search(text), "a real session cookie must be detected"


@pytest.mark.parametrize(
    "text",
    [
        pytest.param("session started at 10am", id="prose"),
        pytest.param("my_session = 3", id="short-value"),
        pytest.param(
            "remember_user_token is the Devise cookie name",
            id="name-mentioned-in-prose",
        ),
        pytest.param("_otwarchive_session <redacted>", id="already-redacted"),
        pytest.param("session_id: abc123", id="short-id"),
        pytest.param(
            "the _otwarchive_session cookie expires in two weeks", id="documentation"
        ),
    ],
)
def test_does_not_match_benign_text(text: str) -> None:
    assert not PATTERN.search(text), (
        "false positive — this pattern is in the redact set, so a match here "
        "would rewrite legitimate content"
    )


def test_negative_control_the_guard_can_fail() -> None:
    """The pattern must be doing real work, not passing vacuously.

    If someone weakens the value-length floor, the benign cases start matching.
    This asserts the floor is load-bearing by constructing the failure.
    """
    import re

    weakened = re.compile(
        r"(?:_[a-z0-9_]*session|_?session_id|remember_[a-z0-9_]*token)"
        r"[\"'=:\s]+[A-Za-z0-9%._-]{3,}"  # floor dropped 40 -> 3
    )
    assert weakened.search("session_id: abc123"), (
        "sanity: the weakened pattern SHOULD match benign text"
    )
    assert not PATTERN.search("session_id: abc123"), (
        "the shipped pattern's length floor is what prevents that match"
    )
