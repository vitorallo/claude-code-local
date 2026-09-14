"""Anthropic Messages API <-> OpenAI chat/completions translation.

Pure functions, no I/O. Claude Code speaks Anthropic; nearly every hosted
provider (NVIDIA, Groq, OpenRouter, ...) speaks OpenAI. The rules are ported
from OmniRoute's claude-to-openai / openai-to-claude translators, cut down to
what Claude Code actually sends.
"""

import hashlib
import json
import re
import uuid

# Claude Code prepends this line to the system prompt; it changes per request
# and means nothing to other providers.
BILLING_HEADER = re.compile(r"^x-anthropic-billing-header:.*(?:\n|$)", re.MULTILINE)

# NVIDIA rejects tool-call ids that are not exactly 9 alphanumerics. Claude Code
# sends "toolu_..." ids, so every id is hashed down to that shape. The hash is
# deterministic, so a tool_use and its tool_result still match.
TOOL_ID = re.compile(r"^[A-Za-z0-9]{9}$")

STOP_REASONS = {
    "stop": "end_turn",
    "length": "max_tokens",
    "tool_calls": "tool_use",
    "function_call": "tool_use",
    "content_filter": "end_turn",
}

ERROR_TYPES = {
    400: "invalid_request_error",
    401: "authentication_error",
    403: "permission_error",
    404: "not_found_error",
    413: "request_too_large",
    429: "rate_limit_error",
    529: "overloaded_error",
}


def tool_id(original):
    if not original or TOOL_ID.match(original):
        return original
    return hashlib.sha256(original.encode()).hexdigest()[:9]


def new_message_id():
    return "msg_" + uuid.uuid4().hex[:24]


def new_tool_id():
    return uuid.uuid4().hex[:9]


def error_body(status, message):
    return {"type": "error", "error": {"type": ERROR_TYPES.get(status, "api_error"), "message": message}}


def estimate_tokens(body):
    return max(1, len(json.dumps(body, ensure_ascii=False)) // 4)


# --------------------------------------------------------------------------
# Request: Anthropic -> OpenAI
# --------------------------------------------------------------------------

def _text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")


def _image_part(block):
    source = block.get("source") or {}
    if source.get("type") == "base64":
        url = f"data:{source.get('media_type', 'image/png')};base64,{source.get('data', '')}"
    else:
        url = source.get("url", "")
    return {"type": "image_url", "image_url": {"url": url}}


def _user_content(parts):
    if all(p["type"] == "text" for p in parts):
        return "\n".join(p["text"] for p in parts)
    return parts


def convert_messages(body):
    out = []
    # Claude Code also puts system-role messages inside messages[] (environment
    # info, reminders). Many OpenAI-style servers reject a system message that
    # isn't first, so they are hoisted into the one system prompt at the top.
    system_parts = [_text_of(body.get("system") or "")]
    system_parts += [_text_of(m.get("content")) for m in body.get("messages") or [] if m.get("role") == "system"]
    system_text = BILLING_HEADER.sub("", "\n\n".join(p for p in system_parts if p.strip())).strip()
    if system_text:
        out.append({"role": "system", "content": system_text})

    for message in body.get("messages") or []:
        role = message.get("role", "user")
        if role == "system":
            continue
        content = message.get("content")
        if isinstance(content, str):
            out.append({"role": role, "content": content})
            continue

        if role == "assistant":
            texts, calls = [], []
            for block in content or []:
                kind = block.get("type")
                if kind == "text":
                    texts.append(block.get("text", ""))
                elif kind == "tool_use":
                    calls.append({
                        "id": tool_id(block.get("id")),
                        "type": "function",
                        "function": {
                            "name": block.get("name"),
                            "arguments": json.dumps(block.get("input") or {}, ensure_ascii=False),
                        },
                    })
                # thinking / redacted_thinking blocks are dropped: other
                # providers can't verify Anthropic's signatures.
            entry = {"role": "assistant", "content": "".join(texts)}
            if calls:
                entry["tool_calls"] = calls
            out.append(entry)
            continue

        # user turn: tool results first, then images lifted out of them, then text
        results, lifted, parts = [], [], []
        for block in content or []:
            kind = block.get("type")
            if kind == "tool_result":
                result = block.get("content")
                if isinstance(result, list):
                    text = "\n".join(x.get("text", "") for x in result if x.get("type") == "text")
                    lifted += [_image_part(x) for x in result if x.get("type") == "image"]
                else:
                    text = result or ""
                if block.get("is_error"):
                    text = "Error: " + text
                results.append({"role": "tool", "tool_call_id": tool_id(block.get("tool_use_id")), "content": text or "(empty)"})
            elif kind == "text":
                parts.append({"type": "text", "text": block.get("text", "")})
            elif kind == "image":
                parts.append(_image_part(block))
        out += results
        if lifted:
            out.append({"role": "user", "content": [{"type": "text", "text": "Images returned by the tool:"}] + lifted})
        if parts:
            out.append({"role": "user", "content": _user_content(parts)})

    return fix_tool_sequence(out)


def fix_tool_sequence(messages):
    """Put each tool result right after the assistant message that asked for it.

    OpenAI-compatible servers reject a `tool` message that doesn't directly
    follow its tool_calls. Claude Code can split parallel results across turns,
    so results are regrouped, orphans dropped, and missing ones filled in.
    """
    results = {}
    for m in messages:
        if m["role"] == "tool":
            results.setdefault(m["tool_call_id"], m)
    out = []
    for m in messages:
        if m["role"] == "tool":
            continue
        out.append(m)
        for call in m.get("tool_calls") or []:
            out.append(results.pop(call["id"], None)
                       or {"role": "tool", "tool_call_id": call["id"], "content": "[No response received]"})
    return out


def convert_tools(tools):
    out = []
    for tool in tools or []:
        if not tool.get("name") or "input_schema" not in tool:
            continue  # Anthropic server tools (web_search_...) have no schema
        schema = dict(tool.get("input_schema") or {"type": "object"})
        if schema.get("type") == "object" and "properties" not in schema:
            schema["properties"] = {}
        out.append({"type": "function", "function": {
            "name": tool["name"], "description": tool.get("description") or "", "parameters": schema}})
    return out


def convert_tool_choice(choice):
    kind = (choice or {}).get("type")
    if kind == "tool":
        return {"type": "function", "function": {"name": choice.get("name")}}
    return {"auto": "auto", "any": "required", "none": "none"}.get(kind)


def _merge(dst, src):
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            _merge(dst[key], value)
        else:
            dst[key] = value


def to_openai(body, model, max_output=None, extra_body=None):
    stream = bool(body.get("stream"))
    request = {"model": model, "messages": convert_messages(body), "stream": stream}
    if body.get("max_tokens"):
        request["max_tokens"] = min(body["max_tokens"], max_output) if max_output else body["max_tokens"]
    for key in ("temperature", "top_p"):
        if body.get(key) is not None:
            request[key] = body[key]
    if body.get("stop_sequences"):
        request["stop"] = body["stop_sequences"]
    tools = convert_tools(body.get("tools"))
    if tools:
        request["tools"] = tools
        choice = convert_tool_choice(body.get("tool_choice"))
        if choice:
            request["tool_choice"] = choice
    if stream:
        request["stream_options"] = {"include_usage": True}
    if extra_body:
        _merge(request, extra_body)
    return request


# --------------------------------------------------------------------------
# Response: OpenAI -> Anthropic
# --------------------------------------------------------------------------

def parse_arguments(raw):
    """Tool arguments are a JSON string. Never drop a broken one silently:
    hand Claude Code something that fails its schema check, so the model sees
    the error and retries, instead of a Write that quietly never happens."""
    if isinstance(raw, dict):
        return raw
    if not raw or not raw.strip():
        return {}
    try:
        value = json.loads(raw, strict=False)  # strict=False: raw newlines inside strings
    except json.JSONDecodeError as e:
        return {"_ccrouter_error": f"provider sent invalid JSON tool arguments ({e.msg} at char {e.pos})",
                "_raw_arguments": raw}
    return value if isinstance(value, dict) else {"value": value}


def usage_of(usage):
    usage = usage or {}
    return {"input_tokens": int(usage.get("prompt_tokens") or 0),
            "output_tokens": int(usage.get("completion_tokens") or 0)}


def stop_reason_of(finish_reason, has_tools):
    if has_tools and finish_reason != "length":
        return "tool_use"  # some providers say "stop" after a tool call
    return STOP_REASONS.get(finish_reason, "end_turn")


def from_openai(response, model):
    choice = (response.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content = []
    if message.get("content"):
        content.append({"type": "text", "text": message["content"]})
    for call in message.get("tool_calls") or []:
        fn = call.get("function") or {}
        content.append({"type": "tool_use", "id": call.get("id") or new_tool_id(),
                        "name": fn.get("name"), "input": parse_arguments(fn.get("arguments"))})
    has_tools = any(b["type"] == "tool_use" for b in content)
    return {
        "id": new_message_id(), "type": "message", "role": "assistant", "model": model,
        "content": content or [{"type": "text", "text": ""}],
        "stop_reason": stop_reason_of(choice.get("finish_reason"), has_tools),
        "stop_sequence": None,
        "usage": usage_of(response.get("usage")),
    }


def sse(event):
    return f"event: {event['type']}\ndata: {json.dumps(event, ensure_ascii=False)}\n\n".encode()


class StreamTranslator:
    """Feed OpenAI stream chunks in, get Anthropic SSE events out.

    Text streams through as it arrives. Tool calls are buffered and emitted
    whole at the end: their arguments get validated as JSON first, and it
    sidesteps providers that send the id and name in separate chunks or resend
    the whole growing argument string.
    """

    def __init__(self, model):
        self.model = model
        self.message_id = new_message_id()
        self.started = False
        self.closed = False
        self.next_index = 0
        self.text_index = None
        self.tools = {}
        self.finish_reason = None
        self.usage = {}
        self.text = []
        self.pending_space = ""
        self.reasoning_chars = 0

    def _slot(self, call):
        index = call.get("index")
        if index is None:
            same = [k for k, s in self.tools.items() if call.get("id") and s["id"] == call["id"]]
            index = same[0] if same else (len(self.tools) if call.get("id") or not self.tools else max(self.tools))
        return self.tools.setdefault(index, {"id": "", "name": "", "args": ""})

    def feed(self, chunk):
        events = []
        if not self.started:
            self.started = True
            events.append({"type": "message_start", "message": {
                "id": self.message_id, "type": "message", "role": "assistant", "model": self.model,
                "content": [], "stop_reason": None, "stop_sequence": None,
                "usage": {"input_tokens": 0, "output_tokens": 0}}})
        if chunk.get("usage"):
            self.usage = chunk["usage"]
        for choice in chunk.get("choices") or []:
            delta = choice.get("delta") or {}
            reasoning = delta.get("reasoning_content") or delta.get("reasoning")
            if reasoning:
                self.reasoning_chars += len(reasoning)  # counted and logged, not shown
            content = delta.get("content")
            if content and self.text_index is None and not content.strip():
                self.pending_space += content  # e.g. NVIDIA's lone "\n" before a tool call
                content = ""
            elif content and self.text_index is None:
                content, self.pending_space = self.pending_space + content, ""
            if content:
                delta = {**delta, "content": content}
                if self.text_index is None:
                    self.text_index = self.next_index
                    self.next_index += 1
                    events.append({"type": "content_block_start", "index": self.text_index,
                                   "content_block": {"type": "text", "text": ""}})
                self.text.append(delta["content"])
                events.append({"type": "content_block_delta", "index": self.text_index,
                               "delta": {"type": "text_delta", "text": delta["content"]}})
            for call in delta.get("tool_calls") or []:
                slot = self._slot(call)
                fn = call.get("function") or {}
                if call.get("id") and not slot["id"]:
                    slot["id"] = call["id"]
                if fn.get("name") and not slot["name"]:
                    slot["name"] = fn["name"]
                fragment = fn.get("arguments")
                if isinstance(fragment, dict):
                    fragment = json.dumps(fragment, ensure_ascii=False)
                if fragment:
                    if slot["args"] and fragment.startswith(slot["args"]):
                        slot["args"] = fragment  # provider resent the whole string
                    else:
                        slot["args"] += fragment
            if choice.get("finish_reason"):
                self.finish_reason = choice["finish_reason"]
        return events

    def tool_blocks(self):
        return [{"type": "tool_use", "id": s["id"] or new_tool_id(), "name": s["name"],
                 "input": parse_arguments(s["args"])}
                for _, s in sorted(self.tools.items())]

    def stop_reason(self):
        return stop_reason_of(self.finish_reason, bool(self.tools))

    def close(self):
        if self.closed:
            return []
        events = [] if self.started else self.feed({})
        self.closed = True
        if self.text_index is not None:
            events.append({"type": "content_block_stop", "index": self.text_index})
        self._tool_blocks = self.tool_blocks()
        for block in self._tool_blocks:
            index = self.next_index
            self.next_index += 1
            events += [
                {"type": "content_block_start", "index": index,
                 "content_block": {"type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}},
                {"type": "content_block_delta", "index": index,
                 "delta": {"type": "input_json_delta", "partial_json": json.dumps(block["input"], ensure_ascii=False)}},
                {"type": "content_block_stop", "index": index},
            ]
        if self.next_index == 0:
            events += [{"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
                       {"type": "content_block_stop", "index": 0}]
        events += [
            {"type": "message_delta", "delta": {"stop_reason": self.stop_reason(), "stop_sequence": None},
             "usage": usage_of(self.usage)},
            {"type": "message_stop"},
        ]
        return events

    def message(self):
        """The assembled response, for logging."""
        content = [{"type": "text", "text": "".join(self.text)}] if self.text else []
        content += getattr(self, "_tool_blocks", None) or self.tool_blocks()
        return {"id": self.message_id, "model": self.model, "content": content,
                "stop_reason": self.stop_reason(), "finish_reason": self.finish_reason,
                "usage": usage_of(self.usage), "reasoning_chars": self.reasoning_chars}
