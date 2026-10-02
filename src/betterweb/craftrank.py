"""CraftRank: quality-weighted PageRank for the AI/SEO/ad/propaganda era."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class CraftNode:
    id: str
    prior: float  # q_i in (0, 1]
    propaganda: float = 0.0  # p_i in [0, 1]


@dataclass
class CraftEdge:
    src: str
    dst: str
    endorse: float = 1.0  # editorial strength
    farm: float = 0.0  # structural spam score in [0, 1]


def _clamp01(x: float) -> float:
    return max(0.0, min(1.0, float(x)))


def prior_from_hints(hints: dict[str, float], *, propaganda_flag: float = 0.0) -> float:
    """Map judgment ranking_hints → CraftRank page prior q_i."""
    quality = float(hints.get("thought_quality", 3.0)) / 5.0
    niche = float(hints.get("niche_bonus", 0.0))
    niche_term = min(niche / 1.6, 1.0) * 0.15
    slop = float(hints.get("slop_penalty", 0.0))
    malice = float(hints.get("malice_penalty", 0.0))
    q = 0.15 + 0.7 * quality + niche_term
    q *= max(0.05, 1.0 - 0.25 * slop)
    q *= max(0.02, 1.0 - 0.35 * malice)
    # Propaganda does not zero prior; graph damping handles amplification.
    _ = propaganda_flag
    return _clamp01(q)


def craftrank(
    nodes: list[CraftNode],
    edges: list[CraftEdge],
    *,
    damping: float = 0.85,
    alpha: float = 1.0,
    beta: float = 0.7,
    iters: int = 40,
    tol: float = 1e-8,
) -> dict[str, float]:
    """
    r = (1-d) * q_hat + d * W^T r

    Edge weight: endorse * q_src^alpha * (1-farm) * (1 - beta * p_src * p_dst)
    """
    if not nodes:
        return {}

    ids = [n.id for n in nodes]
    idx = {node_id: i for i, node_id in enumerate(ids)}
    q = [_clamp01(n.prior) for n in nodes]
    p = [_clamp01(n.propaganda) for n in nodes]
    n = len(nodes)

    q_sum = sum(q) or 1.0
    q_hat = [x / q_sum for x in q]

    # Build weighted out-edges, then column-stochastic W (rows = src).
    weights: list[list[tuple[int, float]]] = [[] for _ in range(n)]
    for e in edges:
        if e.src not in idx or e.dst not in idx:
            continue
        i, j = idx[e.src], idx[e.dst]
        w = (
            max(0.0, float(e.endorse))
            * (q[i] ** alpha)
            * (1.0 - _clamp01(e.farm))
            * (1.0 - beta * p[i] * p[j])
        )
        if w > 0:
            weights[i].append((j, w))

    # Row-normalize → transition; dangling nodes teleport via q_hat.
    trans: list[list[tuple[int, float]]] = [[] for _ in range(n)]
    dangling = [False] * n
    for i in range(n):
        total = sum(w for _, w in weights[i])
        if total <= 0:
            dangling[i] = True
            continue
        trans[i] = [(j, w / total) for j, w in weights[i]]

    r = q_hat[:]
    d = float(damping)
    for _ in range(iters):
        new_r = [(1.0 - d) * q_hat[i] for i in range(n)]
        # Dangling mass redistributed by quality teleport
        dangling_mass = d * sum(r[i] for i in range(n) if dangling[i])
        for i in range(n):
            new_r[i] += dangling_mass * q_hat[i]
        for i in range(n):
            if dangling[i]:
                continue
            ri = r[i]
            for j, pij in trans[i]:
                new_r[j] += d * ri * pij
        diff = sum(abs(new_r[i] - r[i]) for i in range(n))
        r = new_r
        if diff < tol:
            break

    return {ids[i]: r[i] for i in range(n)}


def blend_with_craftrank(
    relevance: float,
    hints: dict[str, float],
    craft: float,
    *,
    gamma_r: float = 4.0,
) -> float:
    """Query-time blend: judgment stub × (1 + gamma * CraftRank)."""
    from betterweb.rank import combine_score

    base = combine_score(relevance, hints)
    return base * (1.0 + gamma_r * float(craft))
