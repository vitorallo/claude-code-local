import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import translate as tr  # noqa: E402


class RequestTests(unittest.TestCase):
    def test_system_blocks_and_billing_header(self):
        body = {"system": [{"type": "text", "text": "x-anthropic-billing-header: cc_version=1;\nYou are helpful."}],
                "messages": [{"role": "user", "content": "hi"}]}
        msgs = tr.convert_messages(body)
        self.assertEqual(msgs[0], {"role": "system", "content": "You are helpful."})
        self.assertEqual(msgs[1], {"role": "user", "content": "hi"})

    def test_system_messages_inside_messages_are_hoisted(self):
        body = {"system": "Base.",
                "messages": [{"role": "user", "content": "hi"},
                             {"role": "system", "content": [{"type": "text", "text": "# Environment\ncwd: /x"}]},
                             {"role": "system", "content": "Reminder."}]}
        msgs = tr.convert_messages(body)
        self.assertEqual(msgs[0], {"role": "system", "content": "Base.\n\n# Environment\ncwd: /x\n\nReminder."})
        self.assertEqual([m["role"] for m in msgs], ["system", "user"])

    def test_tool_ids_are_nine_alphanumerics_and_stable(self):
        tid = tr.tool_id("toolu_01ABCdef")
        self.assertRegex(tid, r"^[A-Za-z0-9]{9}$")
        self.assertEqual(tid, tr.tool_id("toolu_01ABCdef"))
        self.assertEqual(tr.tool_id("abc123XYZ"), "abc123XYZ")

    def test_tool_use_and_result_round_trip(self):
        body = {"messages": [
            {"role": "user", "content": "read it"},
            {"role": "assistant", "content": [
                {"type": "thinking", "thinking": "hmm", "signature": "s"},
                {"type": "text", "text": "Reading."},
                {"type": "tool_use", "id": "toolu_1", "name": "Read", "input": {"file_path": "/a"}},
                {"type": "tool_use", "id": "toolu_2", "name": "Read", "input": {"file_path": "/b"}}]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_2", "content": "B"},
                {"type": "text", "text": "and?"}]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_orphan", "content": "X"}]},
        ]}
        msgs = tr.convert_messages(body)
        roles = [m["role"] for m in msgs]
        self.assertEqual(roles, ["user", "assistant", "tool", "tool", "user"])
        assistant = msgs[1]
        self.assertEqual(assistant["content"], "Reading.")
        ids = [c["id"] for c in assistant["tool_calls"]]
        self.assertEqual([msgs[2]["tool_call_id"], msgs[3]["tool_call_id"]], ids)
        self.assertEqual(msgs[2]["content"], "[No response received]")  # toolu_1 never answered
        self.assertEqual(msgs[3]["content"], "B")
        self.assertEqual(json.loads(assistant["tool_calls"][0]["function"]["arguments"]), {"file_path": "/a"})
        self.assertEqual(msgs[4]["content"], "and?")

    def test_tool_result_blocks_error_and_images(self):
        body = {"messages": [
            {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": "Shot", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "is_error": True, "content": [
                {"type": "text", "text": "boom"},
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AAA"}}]}]}]}
        msgs = tr.convert_messages(body)
        self.assertEqual(msgs[1]["content"], "Error: boom")
        self.assertEqual(msgs[2]["content"][1]["image_url"]["url"], "data:image/png;base64,AAA")

    def test_to_openai_tools_clamp_and_extra_body(self):
        body = {"model": "claude", "max_tokens": 32000, "stream": True, "temperature": 1,
                "stop_sequences": ["END"], "tool_choice": {"type": "any"},
                "messages": [{"role": "user", "content": "x"}],
                "tools": [{"name": "Bash", "description": None, "input_schema": {"type": "object"}},
                          {"type": "web_search_20250305", "name": "web_search"}]}
        req = tr.to_openai(body, "nvidia/m", max_output=16384,
                           extra_body={"chat_template_kwargs": {"enable_thinking": False}})
        self.assertEqual(req["model"], "nvidia/m")
        self.assertEqual(req["max_tokens"], 16384)
        self.assertEqual(req["stop"], ["END"])
        self.assertEqual(req["tool_choice"], "required")
        self.assertEqual(len(req["tools"]), 1)
        self.assertEqual(req["tools"][0]["function"]["parameters"], {"type": "object", "properties": {}})
        self.assertEqual(req["tools"][0]["function"]["description"], "")
        self.assertEqual(req["stream_options"], {"include_usage": True})
        self.assertFalse(req["chat_template_kwargs"]["enable_thinking"])
        self.assertNotIn("stream_options", tr.to_openai({**body, "stream": False}, "m"))


class ResponseTests(unittest.TestCase):
    def test_non_stream_tool_call(self):
        resp = {"choices": [{"finish_reason": "stop", "message": {"content": "ok", "tool_calls": [
            {"id": "abc", "function": {"name": "Write", "arguments": '{"content": "a\nb"}'}}]}}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 3}}
        msg = tr.from_openai(resp, "claude")
        self.assertEqual(msg["stop_reason"], "tool_use")
        self.assertEqual(msg["content"][1]["input"], {"content": "a\nb"})  # raw newline tolerated
        self.assertEqual(msg["usage"], {"input_tokens": 10, "output_tokens": 3})

    def test_invalid_arguments_are_not_silently_dropped(self):
        parsed = tr.parse_arguments('{"content": "unterminated')
        self.assertIn("_ccrouter_error", parsed)
        self.assertIn("_raw_arguments", parsed)

    def test_stream_text_then_split_tool_call_then_usage(self):
        st = tr.StreamTranslator("claude")
        chunks = [
            {"choices": [{"index": 0, "delta": {"role": "assistant", "reasoning_content": "think"}}]},
            {"choices": [{"index": 0, "delta": {"content": "Let me "}}]},
            {"choices": [{"index": 0, "delta": {"content": "write."}}]},
            {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call12345"}]}}]},
            {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"name": "Write", "arguments": '{"file_'}}]}}]},
            {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": 'path": "/x"}'}}]}}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
            {"choices": [], "usage": {"prompt_tokens": 7, "completion_tokens": 9}},
        ]
        events = []
        for c in chunks:
            events += st.feed(c)
        events += st.close()
        types = [e["type"] for e in events]
        self.assertEqual(types, ["message_start", "content_block_start", "content_block_delta", "content_block_delta",
                                 "content_block_stop", "content_block_start", "content_block_delta",
                                 "content_block_stop", "message_delta", "message_stop"])
        tool_start = events[5]["content_block"]
        self.assertEqual((tool_start["id"], tool_start["name"], events[5]["index"]), ("call12345", "Write", 1))
        self.assertEqual(json.loads(events[6]["delta"]["partial_json"]), {"file_path": "/x"})
        self.assertEqual(events[8]["delta"]["stop_reason"], "tool_use")
        self.assertEqual(events[8]["usage"], {"input_tokens": 7, "output_tokens": 9})
        self.assertEqual(st.message()["reasoning_chars"], 5)
        self.assertEqual(st.close(), [])  # idempotent

    def test_stream_resent_growing_arguments_are_deduplicated(self):
        st = tr.StreamTranslator("claude")
        st.feed({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "i", "function": {"name": "Bash", "arguments": '{"command"'}}]}}]})
        st.feed({"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": '{"command": "ls"}'}}]}}]})
        self.assertEqual(st.tool_blocks()[0]["input"], {"command": "ls"})

    def test_leading_whitespace_before_tool_call_is_not_a_text_block(self):
        st = tr.StreamTranslator("c")
        events = st.feed({"choices": [{"delta": {"content": "\n"}}]})
        events += st.feed({"choices": [{"delta": {"content": "", "tool_calls": [
            {"index": 0, "id": "call-1", "function": {"name": "get_weather", "arguments": '{"city":"Rome"}'}}]},
            "finish_reason": "tool_calls"}]})
        events += st.close()
        starts = [e["content_block"]["type"] for e in events if e["type"] == "content_block_start"]
        self.assertEqual(starts, ["tool_use"])
        st2 = tr.StreamTranslator("c")
        st2.feed({"choices": [{"delta": {"content": "\n"}}]})
        st2.feed({"choices": [{"delta": {"content": "Hi"}}]})
        self.assertEqual("".join(st2.text), "\nHi")

    def test_empty_stream_still_valid(self):
        types = [e["type"] for e in tr.StreamTranslator("c").close()]
        self.assertEqual(types, ["message_start", "content_block_start", "content_block_stop",
                                 "message_delta", "message_stop"])

    def test_length_with_text_maps_to_max_tokens(self):
        st = tr.StreamTranslator("c")
        st.feed({"choices": [{"delta": {"content": "a"}, "finish_reason": "length"}]})
        self.assertEqual(st.stop_reason(), "max_tokens")


if __name__ == "__main__":
    unittest.main()
