import pytest


@pytest.fixture(autouse=True)
def _tests_assume_ac_power(monkeypatch):
    monkeypatch.setattr("betterweb.power.on_ac_power", lambda: True)
