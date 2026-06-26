import json

from handlers import catalog
from shared.catalog_data import CATALOG, DUMMY_BOOK_ID


def _event(path_params=None):
    # Catalog routes are public (no auth header needed) — bare API-GW v2 shape.
    return {
        "requestContext": {"http": {"method": "GET"}},
        "pathParameters": path_params,
        "body": None,
    }


def test_list_returns_items_without_auth():
    resp = catalog.handler(_event(), None)
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert "items" in body
    assert len(body["items"]) == len(CATALOG)
    # Every list entry carries the preview fields...
    first = body["items"][0]
    for field in ("id", "title", "author", "excerpt", "coverHue", "wordCount", "estimatedMinutes"):
        assert field in first
    # ...but the heavy full text is omitted from the list for size.
    assert all("text" not in item for item in body["items"])


def test_list_includes_canonical_dummy_book():
    body = json.loads(catalog.handler(_event(), None)["body"])
    ids = [item["id"] for item in body["items"]]
    assert DUMMY_BOOK_ID in ids


def test_detail_returns_full_text():
    resp = catalog.handler(_event(path_params={"id": DUMMY_BOOK_ID}), None)
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["id"] == DUMMY_BOOK_ID
    assert isinstance(body.get("text"), str) and len(body["text"]) > 0
    assert body["wordCount"] == len(body["text"].split())


def test_detail_unknown_id_is_404():
    resp = catalog.handler(_event(path_params={"id": "does-not-exist"}), None)
    assert resp["statusCode"] == 404
    assert "error" in json.loads(resp["body"])
