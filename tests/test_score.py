from betterweb.schema import authorship_flags, numeric_decisions
from betterweb.score import authorship_terms, citation_promotion, craftrank_score


def test_synthetic_scores_below_human_dense_page():
    human = craftrank_score(
        {
            "is_human_generated": True,
            "is_ai_generated": False,
            "thought_quality": 0.9,
            "citation_use": 0.8,
            "commercial_bias": 0.0,
            "ad_use": 0.0,
            "commercial_promotion": 0.0,
        }
    )
    synthetic = craftrank_score(
        {
            "is_human_generated": False,
            "is_ai_generated": True,
            "thought_quality": 0.9,
            "citation_use": 0.8,
            "commercial_bias": 0.0,
            "ad_use": 0.0,
            "commercial_promotion": 0.0,
        }
    )
    assert human > synthetic
    assert human > 7.0
    assert synthetic < 5.5


def test_unknown_authorship_is_neutral_vs_unlabeled():
    base = {
        "thought_quality": 0.5,
        "citation_use": 0.0,
        "commercial_bias": 0.0,
        "ad_use": 0.0,
        "commercial_promotion": 0.0,
    }
    unknown = craftrank_score({**base, "is_human_generated": False, "is_ai_generated": False})
    missing = craftrank_score(base)
    assert unknown == missing


def test_both_true_clamps_to_unknown():
    is_human, is_ai = authorship_flags({"is_human_generated": True, "is_ai_generated": True})
    assert (is_human, is_ai) == (False, False)
    clamped = numeric_decisions({"is_human_generated": True, "is_ai_generated": True})
    assert clamped["authorship_likeness"] == "unknown"
    both = craftrank_score({"is_human_generated": True, "is_ai_generated": True, "thought_quality": 0.5})
    neither = craftrank_score({"is_human_generated": False, "is_ai_generated": False, "thought_quality": 0.5})
    assert both == neither


def test_low_citations_do_not_demote():
    none = citation_promotion(0.0)
    low = citation_promotion(0.2)
    high = citation_promotion(0.9)
    assert none == 0.0
    assert low == 0.0
    assert high > 0.5


def test_neither_does_not_demote_like_mixed():
    human, synthetic = authorship_terms({"is_human_generated": False, "is_ai_generated": False})
    assert (human, synthetic) == (0.0, 0.0)
    neither = craftrank_score({"is_human_generated": False, "is_ai_generated": False, "thought_quality": 0.5})
    synth = craftrank_score({"is_human_generated": False, "is_ai_generated": True, "thought_quality": 0.5})
    assert neither > synth
    assert neither == 5.0 + 3.0 * 0.5
