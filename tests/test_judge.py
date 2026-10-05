from betterweb.judge import heuristic_decisions, probe


def test_heuristic_thought_clears_expand_floor_on_essays():
    high = heuristic_decisions(
        "How kernels schedule threads",
        "I measured scheduler latency on Linux 6.1. Figure 2 shows the runqueue "
        "across a long enough sample that the page is not treated as chrome.",
        "https://example.org/kernel",
    )
    assert high["thought_quality"] >= 0.45
    assert "warrants_expand" not in high

    thin = heuristic_decisions("Sign in", "Sign in to like this video.", "https://www.youtube.com/ads/")
    assert thin["thought_quality"] < 0.45


def test_probe_without_judge_is_disabled():
    assert "heuristic" in probe(None)
