"""Load test for the 5,000-concurrent-request target (FR-12, REQUIREMENTS §7, docs/CAPACITY.md).

Each Locust user keeps exactly one streaming chat completion in flight at a time, so the number
of users is the number of concurrent requests. Reported per request:
  chat (stream)   time to response headers (Locust stops its clock there for streams)
  e2e             whole request, until the last token
  ttft            time to first token
  tpot            mean time per output token after the first

Run it in-cluster with k8s/tests/load-test/ (distributed, 5,000 users), or locally for a smoke run:
  LLM_API_KEY=sk-... locust -f scripts/locustfile.py --host http://localhost:4000 \
      --headless -u 50 -r 5 -t 5m
"""

import json
import os
import random
import time

from locust import HttpUser, constant, events, task

MODEL = os.environ.get("LLM_MODEL", "qwen2.5-7b-instruct")
API_KEY = os.environ["LLM_API_KEY"]
# Workload assumed by docs/CAPACITY.md: ~1,000 prompt tokens, ~300 output tokens.
PROMPT_TOKENS = int(os.environ.get("PROMPT_TOKENS", "1000"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "300"))
# Share of requests that start with the same system prompt (prefix-cache hits), like an internal
# platform where every app sends its own fixed instructions.
SHARED_PREFIX_RATIO = float(os.environ.get("SHARED_PREFIX_RATIO", "0.5"))

_WORDS = ("cluster node gpu latency token request queue model gateway scale metric replica "
          "budget alert trace prompt cache batch throughput service deploy").split()
_SYSTEM = "You are a helpful assistant for an internal developer platform. " * 20


def _filler(tokens: int) -> str:
    # ~1 token per short English word for Qwen's tokenizer; close enough for load shaping.
    return " ".join(random.choice(_WORDS) for _ in range(tokens))


class ChatUser(HttpUser):
    wait_time = constant(0)

    @task
    def chat_stream(self):
        shared = random.random() < SHARED_PREFIX_RATIO
        system = _SYSTEM if shared else _filler(200)
        body = {
            "model": MODEL,
            "stream": True,
            "max_tokens": MAX_TOKENS,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": _filler(max(PROMPT_TOKENS - 200, 50))
                 + "\nSummarize the above in detail."},
            ],
        }
        start = time.perf_counter()
        first = None
        chunks = 0
        with self.client.post(
            "/v1/chat/completions",
            data=json.dumps(body),
            headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
            name="chat (stream)",
            stream=True,
            timeout=(30, 600),
            catch_response=True,
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"HTTP {resp.status_code}")
                return
            for line in resp.iter_lines():
                if not line.startswith(b"data: ") or line == b"data: [DONE]":
                    continue
                if first is None:
                    first = time.perf_counter()
                chunks += 1
            if first is None:
                resp.failure("stream ended without a token")
                return
            resp.success()

        end = time.perf_counter()
        fire = events.request.fire
        fire(request_type="LLM", name="e2e", response_time=(end - start) * 1000,
             response_length=chunks, exception=None, context={})
        fire(request_type="LLM", name="ttft", response_time=(first - start) * 1000,
             response_length=0, exception=None, context={})
        if chunks > 1:
            fire(request_type="LLM", name="tpot", response_time=(end - first) * 1000 / (chunks - 1),
                 response_length=chunks, exception=None, context={})
