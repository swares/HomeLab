"""
protocol.py — canonical client for the M5Stack Core Framework HTTP AI protocol.

Wire format: fire-and-poll
  POST /api/{slug}/set?ask=<prompt>   # kick off (requires X-Requested-With header)
  GET  /api/{slug}                    # poll -> {readings: {connected,busy,done,timed_out,answer,...}}
  POST /api/{slug}/set?clear=1        # reset

Firmware CSRF guard: POST /set requires header X-Requested-With: XMLHttpRequest.
Firmware response format: poll fields are nested under "readings" key.

Slugs: 'llm' (Module LLM / NPU), 'route' (3-tier escalation router), 'claude' (direct Anthropic).
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
    """Pure: one poll payload + the previous answer -> (answer, delta, route, done).
    Unwraps nested 'readings' key present in firmware response format."""
    state = state.get("readings", state)  # firmware wraps fields under "readings"
    route = state.get("route_taken")
    new = state.get("answer") or ""
    if new and new != prev_answer:
        delta = new[len(prev_answer):] if new.startswith(prev_answer) else new
    else:
        delta = ""
    done = bool(state.get("done") or state.get("timed_out")
                or (not state.get("busy") and new))
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
        import requests
        return requests.get(url, params=params or None, auth=self.auth,
                            verify=self.verify, timeout=8, allow_redirects=False).json()

    def _post_json(self, url: str, **params):
        """POST to /set endpoints — device requires POST with X-Requested-With (CSRF guard)."""
        import requests
        return requests.post(url, params=params or None, auth=self.auth,
                             verify=self.verify, timeout=8, allow_redirects=False,
                             headers={"X-Requested-With": "XMLHttpRequest"}).json()

    def stream(self, slug: str, prompt: str, clear: bool = False):
        """Generator: ('delta', text, route) ... then ('final', '', route)."""
        if clear:
            try:
                self._post_json(set_url(self.base, slug), clear="1")
            except Exception:
                pass
        self._post_json(set_url(self.base, slug), ask=prompt)
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
        """Submit + poll until done; return the final text."""
        if idle is not None:
            self.idle = idle
        for attempt in range(retries + 1):
            try:
                answer = ""
                for kind, text, _route in self.stream(slug, prompt):
                    if kind == "delta":
                        answer += text
                return answer.strip() or "[empty reply]"
            except Exception as e:
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
        csrf = {"X-Requested-With": "XMLHttpRequest"}
        async with httpx.AsyncClient(verify=self.verify, auth=self.auth,
                                     timeout=30.0, headers=csrf) as c:
            if clear:
                try:
                    await c.post(set_url(self.base, slug), params={"clear": "1"})
                except Exception:
                    pass
            await c.post(set_url(self.base, slug), params={"ask": prompt})
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
