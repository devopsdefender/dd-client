//! Per-agent adapter for Claude Code's `--output-format stream-json`.
//!
//! When an agent is launched in a structured mode, we get lossless blocks
//! instead of scraping a TUI. This adapter consumes newline-delimited JSON
//! events and maps them to blocks:
//!   * `assistant` message text  → Markdown (one block per assistant turn)
//!   * `assistant` `tool_use`    → a Markdown header + a Code block of the input
//!   * `user` `tool_result`      → a Code block (the tool output)
//!   * `result`                  → a final Markdown block
//!
//! It targets the default (non-partial) event stream; incremental
//! `content_block_delta` streaming is a future enrichment. A line that doesn't
//! parse is surfaced as Markdown rather than dropped, so nothing is lost. If
//! parsing mostly fails, [`confidence`](Adapter::confidence) drops and the
//! engine can fall back to the floor.

use serde_json::Value;

use crate::block::{BlockId, BlockKind, BlockPatch};

use super::{Adapter, BlockSink, Confidence};

#[derive(Default)]
pub struct ClaudeCodeAdapter {
    buf: Vec<u8>,
    /// Open Markdown block accumulating assistant text, if any.
    text_block: Option<BlockId>,
    events_ok: u32,
    parse_errors: u32,
}

impl ClaudeCodeAdapter {
    pub fn new() -> Self {
        Self::default()
    }

    fn close_text(&mut self, sink: &mut dyn BlockSink) {
        if let Some(id) = self.text_block.take() {
            sink.finalize(id);
        }
    }

    fn push_markdown(&mut self, text: &str, sink: &mut dyn BlockSink) {
        let id = match self.text_block {
            Some(id) => id,
            None => {
                let id = sink.append(BlockKind::Markdown);
                self.text_block = Some(id);
                id
            }
        };
        sink.patch(id, BlockPatch::AppendText(text.to_string()));
    }

    fn push_code(&mut self, lang: Option<&str>, text: &str, sink: &mut dyn BlockSink) {
        self.close_text(sink);
        let _ = lang; // lang carried for future styling; block records text now
        let id = sink.append(BlockKind::Code);
        sink.patch(id, BlockPatch::AppendText(text.to_string()));
        sink.finalize(id);
    }

    fn handle_event(&mut self, v: &Value, sink: &mut dyn BlockSink) {
        match v.get("type").and_then(Value::as_str) {
            Some("assistant") => self.handle_assistant(v, sink),
            Some("user") => self.handle_tool_result(v, sink),
            Some("result") => {
                self.close_text(sink);
                if let Some(text) = v.get("result").and_then(Value::as_str) {
                    let id = sink.append(BlockKind::Markdown);
                    sink.patch(id, BlockPatch::AppendText(format!("{text}\n")));
                    sink.finalize(id);
                }
            }
            // system/init and unknown types carry no user-facing content.
            _ => {}
        }
    }

    fn handle_assistant(&mut self, v: &Value, sink: &mut dyn BlockSink) {
        let Some(content) = v.pointer("/message/content").and_then(Value::as_array) else {
            return;
        };
        for block in content {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => {
                    if let Some(text) = block.get("text").and_then(Value::as_str) {
                        self.push_markdown(&format!("{text}\n"), sink);
                    }
                }
                Some("tool_use") => {
                    let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
                    self.push_markdown(&format!("⚙ {name}\n"), sink);
                    let input = block
                        .get("input")
                        .map(|i| serde_json::to_string_pretty(i).unwrap_or_default())
                        .unwrap_or_default();
                    if !input.is_empty() {
                        self.push_code(Some("json"), &format!("{input}\n"), sink);
                    }
                }
                _ => {}
            }
        }
    }

    fn handle_tool_result(&mut self, v: &Value, sink: &mut dyn BlockSink) {
        let Some(content) = v.pointer("/message/content").and_then(Value::as_array) else {
            return;
        };
        for block in content {
            if block.get("type").and_then(Value::as_str) == Some("tool_result") {
                let text = match block.get("content") {
                    Some(Value::String(s)) => s.clone(),
                    Some(other) => serde_json::to_string_pretty(other).unwrap_or_default(),
                    None => continue,
                };
                self.push_code(None, &format!("{text}\n"), sink);
            }
        }
    }
}

impl Adapter for ClaudeCodeAdapter {
    fn name(&self) -> &str {
        "claude-code"
    }

    fn feed(&mut self, bytes: &[u8], sink: &mut dyn BlockSink) {
        self.buf.extend_from_slice(bytes);
        while let Some(pos) = self.buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.buf.drain(..=pos).collect();
            let line = &line[..line.len() - 1];
            if line.iter().all(|b| b.is_ascii_whitespace()) {
                continue;
            }
            match serde_json::from_slice::<Value>(line) {
                Ok(v) => {
                    self.events_ok += 1;
                    self.handle_event(&v, sink);
                }
                Err(_) => {
                    // Don't drop anything we couldn't parse.
                    self.parse_errors += 1;
                    let text = String::from_utf8_lossy(line).into_owned();
                    self.push_markdown(&format!("{text}\n"), sink);
                }
            }
        }
    }

    fn flush(&mut self, sink: &mut dyn BlockSink) {
        if !self.buf.is_empty() {
            let rest: Vec<u8> = std::mem::take(&mut self.buf);
            if let Ok(v) = serde_json::from_slice::<Value>(&rest) {
                self.events_ok += 1;
                self.handle_event(&v, sink);
            }
        }
        self.close_text(sink);
    }

    fn confidence(&self) -> Confidence {
        match (self.events_ok, self.parse_errors) {
            (0, _) => Confidence::Low,
            (_, 0) => Confidence::High,
            _ => Confidence::Medium,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block::Block;
    use crate::stream::BlockLog;

    #[derive(Default)]
    struct TestSink {
        log: BlockLog,
    }
    impl BlockSink for TestSink {
        fn append(&mut self, kind: BlockKind) -> BlockId {
            self.log.append(kind).0
        }
        fn patch(&mut self, id: BlockId, patch: BlockPatch) {
            self.log.patch(id, patch);
        }
        fn finalize(&mut self, id: BlockId) {
            self.log.finalize(id);
        }
        fn truncate(&mut self, from: BlockId) {
            self.log.truncate(from);
        }
    }

    fn derive(input: &[u8]) -> Vec<Block> {
        let mut a = ClaudeCodeAdapter::new();
        let mut sink = TestSink::default();
        a.feed(input, &mut sink);
        a.flush(&mut sink);
        sink.log.snapshot()
    }

    #[test]
    fn assistant_text_becomes_markdown() {
        let line =
            br#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello there"}]}}"#;
        let mut input = line.to_vec();
        input.push(b'\n');
        assert_eq!(
            derive(&input),
            vec![Block::Markdown {
                text: "Hello there\n".into(),
                complete: true
            }]
        );
    }

    #[test]
    fn tool_use_becomes_header_plus_code() {
        let line = br#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#;
        let mut input = line.to_vec();
        input.push(b'\n');
        let blocks = derive(&input);
        assert_eq!(
            blocks[0],
            Block::Markdown {
                text: "⚙ Bash\n".into(),
                complete: true
            }
        );
        match &blocks[1] {
            Block::Code { text, .. } => assert!(text.contains("\"command\": \"ls\"")),
            other => panic!("expected code block, got {other:?}"),
        }
    }

    #[test]
    fn result_event_is_final_markdown() {
        let line = br#"{"type":"result","subtype":"success","result":"done"}"#;
        let mut input = line.to_vec();
        input.push(b'\n');
        assert_eq!(
            derive(&input),
            vec![Block::Markdown {
                text: "done\n".into(),
                complete: true
            }]
        );
    }

    #[test]
    fn unparseable_line_is_surfaced_not_dropped() {
        let blocks = derive(b"not json at all\n");
        assert_eq!(
            blocks,
            vec![Block::Markdown {
                text: "not json at all\n".into(),
                complete: true
            }]
        );
    }

    #[test]
    fn confidence_high_on_clean_parse_low_on_none() {
        let mut a = ClaudeCodeAdapter::new();
        assert_eq!(a.confidence(), Confidence::Low);
        let mut sink = TestSink::default();
        a.feed(b"{\"type\":\"system\"}\n", &mut sink);
        assert_eq!(a.confidence(), Confidence::High);
    }

    #[test]
    fn json_split_across_feeds() {
        let mut a = ClaudeCodeAdapter::new();
        let mut sink = TestSink::default();
        a.feed(
            br#"{"type":"assistant","message":{"content":[{"type":"text",""#,
            &mut sink,
        );
        a.feed(b"text\":\"hi\"}]}}\n", &mut sink);
        assert_eq!(
            sink.log.snapshot(),
            vec![Block::Markdown {
                text: "hi\n".into(),
                complete: false
            }]
        );
    }
}
