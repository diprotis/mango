import pytest

from shared.http import _host_is_blocked, fetch_url


def test_blocks_loopback_and_private():
    assert _host_is_blocked("localhost") is True
    assert _host_is_blocked("127.0.0.1") is True
    assert _host_is_blocked("10.0.0.5") is True


def test_blocks_cloud_metadata_ip():
    assert _host_is_blocked("169.254.169.254") is True


def test_rejects_non_http_scheme():
    with pytest.raises(ValueError):
        fetch_url("ftp://example.com/resource")


def test_rejects_private_host_before_network():
    with pytest.raises(ValueError):
        fetch_url("http://127.0.0.1/secrets")
