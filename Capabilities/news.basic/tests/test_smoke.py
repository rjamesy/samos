import json
import subprocess


def test_smoke_contract_shape():
    payload = {
        "tool": "news.fetch",
        "args": {"time_window_hours": 72, "max_items": 5},
    }
    proc = subprocess.run(
        ["python3", "Capabilities/news.basic/server.py"],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
    )
    body = json.loads(proc.stdout)
    assert "generated_at" in body
    assert "items" in body
    assert isinstance(body["items"], list)
    for item in body["items"][:5]:
        assert "title" in item
        assert "url" in item
        assert "source" in item
