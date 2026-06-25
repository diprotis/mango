"""Stdlib HTTP GET with SSRF protection, used by the content-parse Lambda."""

import ipaddress
import socket
import urllib.error
import urllib.parse
import urllib.request

_USER_AGENT = "MangoBot/0.1 (+https://mango.app; reading companion)"


def _host_is_blocked(host: str) -> bool:
    """Block hosts that resolve to private / loopback / link-local / reserved IPs."""
    if not host:
        return True
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return True  # unresolvable → refuse
    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError:
            return True
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
            or ip.is_multicast
            or ip.is_unspecified
        ):
            return True
    return False


class _ValidatingRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Re-validate the destination of every redirect (defeats redirect-to-internal)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlparse(newurl)
        if parsed.scheme not in ("http", "https") or _host_is_blocked(parsed.hostname or ""):
            raise urllib.error.HTTPError(newurl, code, "blocked redirect target", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_url(url: str, timeout: int = 20, max_bytes: int = 5_000_000) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError("only http(s) URLs are supported")
    if _host_is_blocked(parsed.hostname or ""):
        raise ValueError("refusing to fetch a private, reserved, or unresolvable host")

    opener = urllib.request.build_opener(_ValidatingRedirectHandler)
    request = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
    with opener.open(request, timeout=timeout) as response:  # noqa: S310 (scheme + host checked)
        charset = response.headers.get_content_charset() or "utf-8"
        data = response.read(max_bytes)
    return data.decode(charset, errors="replace")
