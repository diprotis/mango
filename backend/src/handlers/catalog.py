"""GET /v1/catalog and GET /v1/catalog/{id} — the built-in public-domain shelf.

Both routes are **public** (no auth): the catalog is static, non-sensitive data so
a first-run app can browse a starter shelf before sign-in. The list omits each
book's full ``text`` (size); the detail route includes it so the app can POST it
inline to ``/v1/roadmaps/generate``. Thin handler over :mod:`shared.catalog_data`.
"""

from shared.catalog_data import get_item, list_items
from shared.response import not_found, ok


def _book_id_from_path(event: dict):
    params = event.get("pathParameters") or {}
    return params.get("id")


def handler(event, context):
    book_id = _book_id_from_path(event)

    # GET /v1/catalog/{id} — full item including text, 404 if unknown.
    if book_id:
        item = get_item(book_id)
        if item is None:
            return not_found("unknown catalog id")
        return ok(item)

    # GET /v1/catalog — list (text omitted for size).
    return ok({"items": list_items()})
