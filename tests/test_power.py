import subprocess
from types import SimpleNamespace

from betterweb.power import on_ac_power


def test_ac_power_true_on_wall(monkeypatch):
    monkeypatch.setattr("betterweb.power.sys.platform", "darwin")

    def fake_run(*_a, **_k):
        return SimpleNamespace(stdout="Now drawing from 'AC Power'\n")

    monkeypatch.setattr("betterweb.power.subprocess.run", fake_run)
    assert on_ac_power() is True


def test_ac_power_false_on_battery(monkeypatch):
    monkeypatch.setattr("betterweb.power.sys.platform", "darwin")

    def fake_run(*_a, **_k):
        return SimpleNamespace(stdout="Now drawing from 'Battery Power'\n")

    monkeypatch.setattr("betterweb.power.subprocess.run", fake_run)
    assert on_ac_power() is False


def test_ac_power_false_if_pmset_fails(monkeypatch):
    monkeypatch.setattr("betterweb.power.sys.platform", "darwin")

    def fake_run(*_a, **_k):
        raise subprocess.CalledProcessError(1, "pmset")

    monkeypatch.setattr("betterweb.power.subprocess.run", fake_run)
    assert on_ac_power() is False
