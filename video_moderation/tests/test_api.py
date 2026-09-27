from fastapi.testclient import TestClient

from app.main import app
from app.analyzer import safety_decision


def test_health() -> None:
    response = TestClient(app).get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_safety_decision_has_distinct_allowed_review_and_blocked_bands(monkeypatch) -> None:
    monkeypatch.setenv("REVIEW_THRESHOLD", "0.50")
    monkeypatch.setenv("UNSAFE_THRESHOLD", "0.75")
    assert safety_decision(0.49) == "allowed"
    assert safety_decision(0.50) == "review"
    assert safety_decision(0.74) == "review"
    assert safety_decision(0.75) == "blocked"


def test_safety_decision_rejects_overlapping_thresholds(monkeypatch) -> None:
    monkeypatch.setenv("REVIEW_THRESHOLD", "0.80")
    monkeypatch.setenv("UNSAFE_THRESHOLD", "0.75")
    try:
        safety_decision(0.60)
        assert False, "overlapping thresholds must fail"
    except ValueError:
        pass
