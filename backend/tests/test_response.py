import json

from shared import response


def test_json_response_shape():
    out = response.ok({"a": 1})
    assert out["statusCode"] == 200
    assert json.loads(out["body"]) == {"a": 1}
    assert out["headers"]["content-type"] == "application/json"


def test_parse_body_handles_garbage():
    assert response.parse_body({"body": "not json"}) == {}
    assert response.parse_body({"body": '{"x": 2}'}) == {"x": 2}
    assert response.parse_body({}) == {}


def test_http_method_v2_and_fallback():
    assert response.http_method({"requestContext": {"http": {"method": "PUT"}}}) == "PUT"
    assert response.http_method({}) == "GET"


def test_user_id_from_jwt_then_header_fallback():
    evt = {"requestContext": {"authorizer": {"jwt": {"claims": {"sub": "u-123"}}}}}
    assert response.user_id(evt) == "u-123"
    assert response.user_id({"headers": {"x-mango-user": "dave"}}) == "dave"
    assert response.user_id({}) == "local-dev-user"
