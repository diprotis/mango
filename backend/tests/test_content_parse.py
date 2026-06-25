import json

import boto3

from handlers import content_parse
from tests.conftest import BUCKET, TABLE


def _invoke(source):
    return content_parse.handler({"body": json.dumps({"source": source})}, None)


def test_parse_text_source_persists(aws):
    resp = _invoke({"type": "text", "value": "Discipline is choosing what you want most. " * 5})
    assert resp["statusCode"] == 200
    book = json.loads(resp["body"])
    assert book["wordCount"] > 0
    assert book["title"]

    item = (
        boto3.resource("dynamodb", region_name="us-east-1")
        .Table(TABLE)
        .get_item(Key={"PK": f"BOOK#{book['id']}", "SK": "META"})
        .get("Item")
    )
    assert item is not None
    stored = boto3.client("s3", region_name="us-east-1").get_object(
        Bucket=BUCKET, Key=book["contentRef"]
    )
    assert b"Discipline" in stored["Body"].read()


def test_parse_url_source_uses_fetcher(aws, monkeypatch):
    html = (
        "<html><title>Focus</title><body><p>" + ("Deep work matters. " * 20) + "</p></body></html>"
    )
    monkeypatch.setattr(content_parse, "fetch_url", lambda url, **kw: html)
    resp = _invoke({"type": "url", "value": "https://example.com/post"})
    assert resp["statusCode"] == 200
    book = json.loads(resp["body"])
    assert book["title"] == "Focus"
    assert "Deep work" in book["excerpt"]


def test_parse_rejects_bad_type(aws):
    resp = _invoke({"type": "audio", "value": "x"})
    assert resp["statusCode"] == 400


def test_parse_rejects_short_content(aws):
    resp = _invoke({"type": "text", "value": "tiny"})
    assert resp["statusCode"] == 400
