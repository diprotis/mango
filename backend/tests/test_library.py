import json

from handlers import library


def _event(method, body=None, path_params=None, user="u-1"):
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {"x-mango-user": user},
        "pathParameters": path_params,
        "body": json.dumps(body) if body is not None else None,
    }


def test_empty_library_lists_nothing(aws):
    resp = library.handler(_event("GET"), None)
    body = json.loads(resp["body"])
    assert resp["statusCode"] == 200
    assert body["items"] == []


def test_add_then_list(aws):
    add = library.handler(_event("POST", {"bookId": "bk_123"}), None)
    assert add["statusCode"] == 200
    added = json.loads(add["body"])
    assert added["bookId"] == "bk_123"
    assert added["addedAt"]

    listed = json.loads(library.handler(_event("GET"), None)["body"])
    assert len(listed["items"]) == 1
    assert listed["items"][0]["bookId"] == "bk_123"
    assert listed["items"][0]["addedAt"]


def test_post_requires_book_id(aws):
    resp = library.handler(_event("POST", {}), None)
    assert resp["statusCode"] == 400


def test_delete_removes_item(aws):
    library.handler(_event("POST", {"bookId": "bk_abc"}), None)
    library.handler(_event("POST", {"bookId": "bk_def"}), None)

    resp = library.handler(_event("DELETE", path_params={"bookId": "bk_abc"}), None)
    assert resp["statusCode"] == 200
    assert json.loads(resp["body"])["deleted"] == "bk_abc"

    remaining = json.loads(library.handler(_event("GET"), None)["body"])["items"]
    ids = [it["bookId"] for it in remaining]
    assert ids == ["bk_def"]


def test_delete_requires_book_id_path_param(aws):
    resp = library.handler(_event("DELETE", path_params=None), None)
    assert resp["statusCode"] == 400


def test_library_is_per_user(aws):
    library.handler(_event("POST", {"bookId": "bk_u1"}, user="u-1"), None)
    library.handler(_event("POST", {"bookId": "bk_u2"}, user="u-2"), None)
    u1 = json.loads(library.handler(_event("GET", user="u-1"), None)["body"])["items"]
    u2 = json.loads(library.handler(_event("GET", user="u-2"), None)["body"])["items"]
    assert [it["bookId"] for it in u1] == ["bk_u1"]
    assert [it["bookId"] for it in u2] == ["bk_u2"]
