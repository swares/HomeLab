"""
protocol.py — the one canonical client for the M5Stack Core Framework's HTTP AI protocol.

Imported by BOTH orchestrator.py and openai_adapter/ so the wire format lives in exactly one
place and cannot drift from the firmware. The framework serves AI as fire-and-poll:

    GET /api/{slug}/set?ask=<prompt>   # kick off (returns immediately)
    GET /api/{slug}                    # poll -> {connected,busy,done,timed_out,answer,route_taken,...}
    GET /api/{slug}/set?clear=1        # reset

Slugs: 'llm' (Module LLM / NPU), 'route' (3-tier escalation router), 'claude' (direct Anthropic).

Design: the protocol *knowledge* — URLs, field names, delta extraction, the done/idle decision —
is transport-free and shared (set_url/poll_url/parse_state/stop_for_timeout). Two thin wrappers
add I/O: DeviceClient (sync, `requests`) for orchestrator.py and AsyncDeviceClient (async,
`httpx`) for the adapter. The third-party libs are imported LAZILY, so the sync caller needs only
`requests` and the async caller only `httpx` — neither drags in the other.
"""
from __future__ import annotations
import time
from dataclasses import dataclass
from typing import Optional

DEFAULT_POLL_INTERVAL = 0.4
DEFAULT_IDLE  = 90.0
DEFAULT_TOTAL = 1800.0


def set_url(base: str, slug: str) -> str:
    return f"{base.rstrip('/')}/api/{slug}/set"


def poll_url(base: str, slug: str) -> str:
    return f"{base.rstrip('/')}/api/{slug}"


@dataclass
class PollResult:
    answer: str
    delta: str
    route: Optional[str]
    done: bool


def parse_state(state: dict, prev_answer: str) -> PollResult:
    """Pure: one poll payload + the previous answer -> (answer, delta, route, done)."""
    route = state.get("route_taken")
    new = state.get("answer") or ""
    if new and new != prev_answer:
        delta = new[len(prev_answer):] if new.startswith(prev_answer) else new
    else:
        delta = ""
    done = bool(state.get("done") or state.get("timed_out")
                or (state.get("busy") is False and new))
    return PollResult(answer=new or prev_answer, delta=delta, route=route, done=done)


def stop_for_timeout(now: float, start: float, last_change: float,
                     idle: float, total: float) -> bool:
    return (now - last_change) > idle or (now - start) > total


class DeviceClient:
    """Synchronous client (uses `requests`). Convenient for orchestrator.py."""

    def __init__(self, base: str, auth=None, verify: bool = False,
                 poll_interval: float = 0.3, idle: float = DEFAULT_IDLE,
                 total: float = DEFAULT_TOTAL):
        self.base, self.auth, self.verify = base, auth, verify
        self.poll_interval, self.idle, self.total = poll_interval, idle, total

    def _get_json(self, url: str, **params):
        import requests  # lazy: only the sync caller needs it
        # allow_redirects=False is defence-in-depth: the JSON API never legitimately
        # 3xx-redirects, so refusing redirects stops a spoofed/compromised Core (TLS is
        # unverified on the LAN) bouncing us to an internal address (SSRF-by-redirect).
        return requests.get(url, params=params or None, auth=self.auth,
                            verify=self.verify, timeout=8, allow_redirects=False).json()

    def stream(self, slug: str, prompt: str, clear: bool = False):
        """Generator: ('delta', text, route) ... then ('final', '', route)."""
        if clear:
            try:
                self._get_json(set_url(self.base, slug), clear="1")
            except Exception:
                pass
        self._get_json(set_url(self.base, slug), ask=prompt)  # may raise -> ask() retries
        start = last_change = time.time()
        answer, route = "", None
        while True:
            time.sleep(self.poll_interval)
            try:
                r = parse_state(self._get_json(poll_url(self.base, slug)), answer)
            except Exception:
                if time.time() - start > self.total:
                    yield ("final", "", route)
                    return
                continue
            route = r.route or route
            if r.delta:
                answer, last_change = r.answer, time.time()
                yield ("delta", r.delta, route)
            if r.done:
                yield ("final", "", route)
                return
            if stop_for_timeout(time.time(), start, last_change, self.idle, self.total):
                yield ("final", "", route)
                return

    def ask(self, prompt: str, slug: str = "llm", idle: Optional[float] = None,
            retries: int = 2) -> str:
        """Submit + poll until done; return the final text. Mirrors orchestrator semantics."""
        if idle is not None:
            self.idle = idle
        for attempt in range(retries + 1):
            try:
                answer = ""
                for kind, text, _route in self.stream(slug, prompt):
                    if kind == "delta":
                        answer += text
                return answer.strip() or "[empty reply]"
            except Exception as e:  # transport failed before/at the initial set
                if attempt == retries:
                    return f"[core unreachable: {e}]"
                time.sleep(1.0 * (attempt + 1))


class AsyncDeviceClient:
    """Asynchronous client (uses `httpx`). Used by the OpenAI adapter."""

    def __init__(self, base: str, auth=None, verify: bool = False,
                 poll_interval: float = DEFAULT_POLL_INTERVAL,
                 idle: float = DEFAULT_IDLE, total: float = DEFAULT_TOTAL):
        self.base, self.auth, self.verify = base, auth, verify
        self.poll_interval, self.idle, self.total = poll_interval, idle, total

    async def stream(self, slug: str, prompt: str, clear: bool = False):
        """Async generator: ('delta', text, route) ... then ('final', '', route)."""
        import httpx
        import asyncio
        async with httpx.AsyncClient(verify=self.verify, auth=self.auth, timeout=30.0) as c:
            if clear:
                try:
                    await c.get(set_url(self.base, slug), params={"clear": "1"})
                except Exception:
                    pass
            await c.get(set_url(self.base, slug), params={"ask": prompt})
            start = last_change = time.time()
            answer, route = "", None
            while True:
                await asyncio.sleep(self.poll_interval)
                try:
                    resp = await c.get(poll_url(self.base, slug))
                    r = parse_state(resp.json(), answer)
                except Exception:
                    if time.time() - start > self.total:
                        yield ("final", "", route)
                        return
                    continue
                route = r.route or route
                if r.delta:
                    answer, last_change = r.answer, time.time()
                    yield ("delta", r.delta, route)
                if r.done:
                    yield ("final", "", route)
                    return
                if stop_for_timeout(time.time(), start, last_change, self.idle, self.total):
                    yield ("final", "", route)
                    return
