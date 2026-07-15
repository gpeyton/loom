//! Resource usage parsing and cost calculation.
//!
//! This module provides functionality for:
//! - Parsing token usage from Claude Code terminal output
//! - Calculating costs based on model pricing
//! - Creating `ResourceUsage` records
//!
//! # Usage
//!
//! ```ignore
//! use loom_daemon::activity::resource_usage::{parse_resource_usage, ModelPricing};
//!
//! let output = "Tokens: 1,234 in / 567 out\nModel: claude-3-5-sonnet";
//! if let Some(usage) = parse_resource_usage(output, Some(1500)) {
//!     println!("Cost: ${:.4}", usage.cost_usd);
//! }
//! ```

use chrono::{DateTime, Utc};
use regex::Regex;
use std::sync::LazyLock;

/// Parsed resource usage data from terminal output
#[derive(Debug, Clone, Default)]
pub struct ResourceUsage {
    pub input_id: Option<i64>,
    pub model: String,
    pub tokens_input: i64,
    pub tokens_output: i64,
    pub tokens_cache_read: Option<i64>,
    pub tokens_cache_write: Option<i64>,
    pub cost_usd: f64,
    pub duration_ms: Option<i64>,
    pub provider: String,
    pub timestamp: DateTime<Utc>,
}

/// Model pricing configuration (cost per 1000 tokens)
#[derive(Debug, Clone)]
#[allow(clippy::struct_field_names)]
pub struct ModelPricing {
    pub input_cost_per_1k: f64,
    pub output_cost_per_1k: f64,
    pub cache_read_cost_per_1k: f64,
    pub cache_write_cost_per_1k: f64,
}

/// A single row of the data-driven pricing table.
///
/// `match_substrings` are tested (in table order) against the lowercased model
/// name; the first entry with any matching substring wins. Adding a new model
/// is therefore a one-line data change rather than a new `if` branch.
struct PricingEntry {
    match_substrings: &'static [&'static str],
    pricing: ModelPricing,
}

/// Pricing for a model we don't recognize.
///
/// Historically unknown models were silently billed at Claude Sonnet rates
/// (issue #21). With Codex/GPT/o-series workers now in the mix, that would
/// misattribute cost across providers. Instead we price unknown models at zero
/// and log a warning, so a mystery model is visibly un-costed rather than
/// wrongly attributed to Anthropic.
const UNKNOWN_PRICING: ModelPricing = ModelPricing {
    input_cost_per_1k: 0.0,
    output_cost_per_1k: 0.0,
    cache_read_cost_per_1k: 0.0,
    cache_write_cost_per_1k: 0.0,
};

/// Data-driven model pricing table (USD per 1,000 tokens).
///
/// Order matters: more specific substrings must precede broader ones (e.g.
/// `codex` before `gpt-5`, since a `gpt-5-codex` id contains both).
///
/// OpenAI figures follow the OpenAI pricing reference
/// (developers.openai.com/api/docs/pricing); OpenAI does not surcharge cache
/// writes, so `cache_write` mirrors the input rate. Claude figures are the
/// pre-existing Anthropic rates. Prices are point-in-time and may drift.
const PRICING_TABLE: &[PricingEntry] = &[
    // --- Anthropic (Claude) ---
    PricingEntry {
        match_substrings: &["claude-3-5-sonnet", "claude-sonnet-4"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.003,
            output_cost_per_1k: 0.015,
            cache_read_cost_per_1k: 0.0003,
            cache_write_cost_per_1k: 0.00375,
        },
    },
    PricingEntry {
        match_substrings: &["claude-3-opus", "claude-opus-4"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.015,
            output_cost_per_1k: 0.075,
            cache_read_cost_per_1k: 0.0015,
            cache_write_cost_per_1k: 0.01875,
        },
    },
    PricingEntry {
        match_substrings: &["claude-3-haiku"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.00025,
            output_cost_per_1k: 0.00125,
            cache_read_cost_per_1k: 0.00003,
            cache_write_cost_per_1k: 0.0003,
        },
    },
    // --- OpenAI Codex / GPT-5 / o-series (issue #21) ---
    // `codex` MUST precede `gpt-5`: a Codex model id also contains `gpt-5`.
    PricingEntry {
        match_substrings: &["codex"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.001_75,
            output_cost_per_1k: 0.014,
            cache_read_cost_per_1k: 0.000_175,
            cache_write_cost_per_1k: 0.001_75,
        },
    },
    PricingEntry {
        match_substrings: &["gpt-5"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.001_25,
            output_cost_per_1k: 0.010,
            cache_read_cost_per_1k: 0.000_125,
            cache_write_cost_per_1k: 0.001_25,
        },
    },
    PricingEntry {
        match_substrings: &["o4-mini"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.001_1,
            output_cost_per_1k: 0.004_4,
            cache_read_cost_per_1k: 0.000_275,
            cache_write_cost_per_1k: 0.001_1,
        },
    },
    PricingEntry {
        match_substrings: &["o3"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.002,
            output_cost_per_1k: 0.008,
            cache_read_cost_per_1k: 0.000_5,
            cache_write_cost_per_1k: 0.002,
        },
    },
    PricingEntry {
        match_substrings: &["o1"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.015,
            output_cost_per_1k: 0.060,
            cache_read_cost_per_1k: 0.007_5,
            cache_write_cost_per_1k: 0.015,
        },
    },
    // --- OpenAI GPT-4 family (pre-existing rates) ---
    PricingEntry {
        match_substrings: &["gpt-4o"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.005,
            output_cost_per_1k: 0.015,
            cache_read_cost_per_1k: 0.0025, // 50% discount for cached
            cache_write_cost_per_1k: 0.005,
        },
    },
    PricingEntry {
        match_substrings: &["gpt-4-turbo"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.01,
            output_cost_per_1k: 0.03,
            cache_read_cost_per_1k: 0.005,
            cache_write_cost_per_1k: 0.01,
        },
    },
    PricingEntry {
        match_substrings: &["gpt-3.5"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.0005,
            output_cost_per_1k: 0.0015,
            cache_read_cost_per_1k: 0.00025,
            cache_write_cost_per_1k: 0.0005,
        },
    },
    // --- Google (Gemini) ---
    PricingEntry {
        match_substrings: &["gemini"],
        pricing: ModelPricing {
            input_cost_per_1k: 0.001_25,
            output_cost_per_1k: 0.005,
            cache_read_cost_per_1k: 0.000_312_5,
            cache_write_cost_per_1k: 0.001_25,
        },
    },
];

impl ModelPricing {
    /// Get pricing for a given model from the data-driven [`PRICING_TABLE`].
    ///
    /// Unknown models return [`UNKNOWN_PRICING`] (zero cost + a warning) rather
    /// than silently defaulting to Claude Sonnet rates (issue #21).
    pub fn for_model(model: &str) -> Self {
        let model_lower = model.to_lowercase();
        for entry in PRICING_TABLE {
            if entry
                .match_substrings
                .iter()
                .any(|needle| model_lower.contains(needle))
            {
                return entry.pricing.clone();
            }
        }

        log::warn!("Unknown model '{model}', pricing as zero-cost (unknown) — not Claude Sonnet");
        UNKNOWN_PRICING.clone()
    }

    /// Calculate total cost for given token counts
    #[allow(clippy::cast_precision_loss)]
    pub fn calculate_cost(
        &self,
        input_tokens: i64,
        output_tokens: i64,
        cache_read_tokens: Option<i64>,
        cache_write_tokens: Option<i64>,
    ) -> f64 {
        let input_cost = (input_tokens as f64 / 1000.0) * self.input_cost_per_1k;
        let output_cost = (output_tokens as f64 / 1000.0) * self.output_cost_per_1k;

        let cache_read_cost =
            cache_read_tokens.map_or(0.0, |t| (t as f64 / 1000.0) * self.cache_read_cost_per_1k);

        let cache_write_cost =
            cache_write_tokens.map_or(0.0, |t| (t as f64 / 1000.0) * self.cache_write_cost_per_1k);

        input_cost + output_cost + cache_read_cost + cache_write_cost
    }
}

/// Detect provider from model name.
///
/// Schema (issue #21): provider is one of `anthropic` | `openai` | `google`,
/// with `meta` retained for local Llama/Mistral models and `unknown` for
/// anything unrecognized. Codex, GPT, and o-series ids all map to `openai`;
/// truly-unknown ids are returned as `unknown`, never silently attributed to
/// Anthropic.
pub fn detect_provider(model: &str) -> &'static str {
    let model_lower = model.to_lowercase();
    if model_lower.contains("claude") {
        "anthropic"
    } else if is_openai_model(&model_lower) {
        "openai"
    } else if model_lower.contains("gemini") {
        "google"
    } else if model_lower.contains("llama") || model_lower.contains("mistral") {
        "meta"
    } else {
        "unknown"
    }
}

/// Whether a (lowercased) model id belongs to OpenAI: GPT, Codex, ChatGPT, or
/// the o-series (o1 / o3 / o4-mini / …) reasoning models.
fn is_openai_model(model_lower: &str) -> bool {
    model_lower.contains("gpt")
        || model_lower.contains("codex")
        || model_lower.contains("chatgpt")
        || O_SERIES_PATTERN.is_match(model_lower)
}

/// Matches OpenAI o-series ids (o1, o3, o4-mini, …): an `o` immediately
/// followed by a digit at a word boundary. `gpt-4o` (its `o` is preceded by a
/// digit) is NOT matched here — it's already caught by the `gpt` check.
#[allow(clippy::expect_used)]
static O_SERIES_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(^|[^a-z0-9])o[0-9]").expect("Invalid regex"));

// Regex patterns for parsing Claude Code output
// These are compiled once and reused
// Note: expect() is appropriate here since these are compile-time constant patterns

/// Pattern: "Total tokens: 1,234 in / 567 out"
#[allow(clippy::expect_used)]
static TOKEN_PATTERN_SLASH: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)(?:total\s+)?tokens?:\s*([\d,]+)\s*(?:in|input)\s*/\s*([\d,]+)\s*(?:out|output)",
    )
    .expect("Invalid regex")
});

/// Pattern: "Input: 1,234 tokens, Output: 567 tokens"
#[allow(clippy::expect_used)]
static TOKEN_PATTERN_LABELED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)input:\s*([\d,]+)\s*tokens?.*?output:\s*([\d,]+)\s*tokens?")
        .expect("Invalid regex")
});

/// Pattern: "Cache read: 1,234 tokens" or `cache_read_input_tokens`: 1234
#[allow(clippy::expect_used)]
static CACHE_READ_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
    // Match both "cache read: 200 tokens" and "cache_read_input_tokens: 200"
    Regex::new(r"(?i)cache[_\s]*read[_\s]*(?:input[_\s]*)?(?:tokens?)?[:\s]*([\d,]+)")
        .expect("Invalid regex")
});

/// Pattern: "Cache write: 1,234 tokens" or `cache_creation_input_tokens`: 1234
#[allow(clippy::expect_used)]
static CACHE_WRITE_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
    // Match both "cache write: 50 tokens" and "cache_creation_input_tokens: 50"
    Regex::new(r"(?i)cache[_\s]*(?:write|creation)[_\s]*(?:input[_\s]*)?(?:tokens?)?[:\s]*([\d,]+)")
        .expect("Invalid regex")
});

/// Pattern: Model name detection - "Model: claude-3-5-sonnet" or "using claude-sonnet-4"
#[allow(clippy::expect_used)]
static MODEL_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:model[:\s]+|using\s+)(claude[a-z0-9-]+|gpt-[a-z0-9.-]+|codex[a-z0-9-]*|o[0-9][a-z0-9-]*|gemini[a-z0-9-]*)")
        .expect("Invalid regex")
});

/// Pattern for extracting duration: "Duration: 5.2s" or "took 5200ms"
#[allow(clippy::expect_used)]
static DURATION_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:duration|took|time)[:\s]*([\d.]+)\s*(ms|s|seconds?|milliseconds?)")
        .expect("Invalid regex")
});

/// Parse a number that may contain commas
fn parse_token_count(s: &str) -> Option<i64> {
    s.replace(',', "").parse().ok()
}

/// Parse resource usage from terminal output
///
/// Attempts to extract token usage, model information, and timing from
/// Claude Code or similar AI tool output.
pub fn parse_resource_usage(output: &str, duration_ms: Option<i64>) -> Option<ResourceUsage> {
    // Try to extract input/output tokens
    let (tokens_input, tokens_output) = extract_tokens(output)?;

    // Extract cache tokens (optional)
    let tokens_cache_read = CACHE_READ_PATTERN
        .captures(output)
        .and_then(|c| c.get(1))
        .and_then(|m| parse_token_count(m.as_str()));

    let tokens_cache_write = CACHE_WRITE_PATTERN
        .captures(output)
        .and_then(|c| c.get(1))
        .and_then(|m| parse_token_count(m.as_str()));

    // Extract model name. When no model is detectable, use an explicit
    // "unknown" marker (issue #21) rather than silently attributing the usage
    // to Claude Sonnet — provider detection and pricing then treat it as
    // unknown (zero-cost) instead of mispricing it as Anthropic.
    let model = MODEL_PATTERN
        .captures(output)
        .and_then(|c| c.get(1))
        .map_or_else(|| "unknown".to_string(), |m| m.as_str().to_string());

    // Extract or use provided duration
    let duration = duration_ms.or_else(|| extract_duration(output));

    // Determine provider
    let provider = detect_provider(&model).to_string();

    // Calculate cost
    let pricing = ModelPricing::for_model(&model);
    let cost_usd =
        pricing.calculate_cost(tokens_input, tokens_output, tokens_cache_read, tokens_cache_write);

    Some(ResourceUsage {
        input_id: None,
        model,
        tokens_input,
        tokens_output,
        tokens_cache_read,
        tokens_cache_write,
        cost_usd,
        duration_ms: duration,
        provider,
        timestamp: Utc::now(),
    })
}

/// Extract input and output token counts from text
fn extract_tokens(text: &str) -> Option<(i64, i64)> {
    // Try "X in / Y out" pattern first
    if let Some(caps) = TOKEN_PATTERN_SLASH.captures(text) {
        let input = caps.get(1).and_then(|m| parse_token_count(m.as_str()))?;
        let output = caps.get(2).and_then(|m| parse_token_count(m.as_str()))?;
        return Some((input, output));
    }

    // Try "Input: X, Output: Y" pattern
    if let Some(caps) = TOKEN_PATTERN_LABELED.captures(text) {
        let input = caps.get(1).and_then(|m| parse_token_count(m.as_str()))?;
        let output = caps.get(2).and_then(|m| parse_token_count(m.as_str()))?;
        return Some((input, output));
    }

    None
}

/// Extract duration from text
#[allow(clippy::cast_possible_truncation)]
fn extract_duration(text: &str) -> Option<i64> {
    let caps = DURATION_PATTERN.captures(text)?;
    let value: f64 = caps.get(1)?.as_str().parse().ok()?;
    let unit = caps.get(2)?.as_str().to_lowercase();

    let ms = if unit.starts_with("ms") || unit.starts_with("milli") {
        value as i64
    } else {
        // Assume seconds
        (value * 1000.0) as i64
    };

    Some(ms)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_tokens_slash_format() {
        let output = "Tokens: 1,234 in / 567 out";
        let usage = parse_resource_usage(output, None).unwrap();
        assert_eq!(usage.tokens_input, 1234);
        assert_eq!(usage.tokens_output, 567);
    }

    #[test]
    fn test_parse_tokens_labeled_format() {
        let output = "Input: 1500 tokens, Output: 800 tokens";
        let usage = parse_resource_usage(output, None).unwrap();
        assert_eq!(usage.tokens_input, 1500);
        assert_eq!(usage.tokens_output, 800);
    }

    #[test]
    fn test_parse_cache_tokens() {
        let output = "Tokens: 1000 in / 500 out\nCache read: 200 tokens\nCache write: 50 tokens";
        let usage = parse_resource_usage(output, None).unwrap();
        assert_eq!(usage.tokens_input, 1000);
        assert_eq!(usage.tokens_output, 500);
        assert_eq!(usage.tokens_cache_read, Some(200));
        assert_eq!(usage.tokens_cache_write, Some(50));
    }

    #[test]
    fn test_parse_model_name() {
        let output = "Model: claude-3-5-sonnet\nTokens: 1000 in / 500 out";
        let usage = parse_resource_usage(output, None).unwrap();
        assert_eq!(usage.model, "claude-3-5-sonnet");
    }

    #[test]
    fn test_detect_provider() {
        assert_eq!(detect_provider("claude-3-5-sonnet"), "anthropic");
        assert_eq!(detect_provider("gpt-4o"), "openai");
        assert_eq!(detect_provider("gemini-pro"), "google");
        assert_eq!(detect_provider("unknown-model"), "unknown");
    }

    #[test]
    fn test_calculate_cost_sonnet() {
        let pricing = ModelPricing::for_model("claude-3-5-sonnet");
        // 1000 input tokens @ $0.003/1k = $0.003
        // 500 output tokens @ $0.015/1k = $0.0075
        // Total = $0.0105
        let cost = pricing.calculate_cost(1000, 500, None, None);
        assert!((cost - 0.0105).abs() < 0.0001);
    }

    #[test]
    fn test_calculate_cost_with_cache() {
        let pricing = ModelPricing::for_model("claude-3-5-sonnet");
        // 1000 input @ $0.003/1k = $0.003
        // 500 output @ $0.015/1k = $0.0075
        // 200 cache read @ $0.0003/1k = $0.00006
        // 50 cache write @ $0.00375/1k = $0.0001875
        // Total = $0.0108375
        let cost = pricing.calculate_cost(1000, 500, Some(200), Some(50));
        assert!((cost - 0.010_837_5).abs() < 0.0001);
    }

    #[test]
    fn test_parse_duration_seconds() {
        let output = "Tokens: 1000 in / 500 out\nDuration: 5.2s";
        let usage = parse_resource_usage(output, None).unwrap();
        assert_eq!(usage.duration_ms, Some(5200));
    }

    #[test]
    fn test_parse_duration_milliseconds() {
        let output = "Tokens: 1000 in / 500 out\ntook 3500ms";
        let usage = parse_resource_usage(output, None).unwrap();
        assert_eq!(usage.duration_ms, Some(3500));
    }

    #[test]
    fn test_provided_duration_overrides() {
        let output = "Tokens: 1000 in / 500 out\nDuration: 5s";
        let usage = parse_resource_usage(output, Some(1234)).unwrap();
        assert_eq!(usage.duration_ms, Some(1234));
    }

    #[test]
    fn test_no_tokens_returns_none() {
        let output = "Some random output without token information";
        assert!(parse_resource_usage(output, None).is_none());
    }

    #[test]
    fn test_cost_calculation_included() {
        let output = "Model: claude-3-5-sonnet\nTokens: 1000 in / 500 out";
        let usage = parse_resource_usage(output, None).unwrap();
        assert!(usage.cost_usd > 0.0);
        assert!((usage.cost_usd - 0.0105).abs() < 0.0001);
    }

    #[test]
    fn test_provider_set_correctly() {
        let output = "Model: claude-opus-4\nTokens: 1000 in / 500 out";
        let usage = parse_resource_usage(output, None).unwrap();
        assert_eq!(usage.provider, "anthropic");
    }

    // ------------------------------------------------------------------
    // Non-Claude pricing + unknown-model fallback (issue #21)
    // ------------------------------------------------------------------

    #[test]
    fn test_detect_provider_openai_codex_and_o_series() {
        // Codex, GPT-5, and o-series ids must all map to openai.
        assert_eq!(detect_provider("gpt-5-codex"), "openai");
        assert_eq!(detect_provider("codex-mini-latest"), "openai");
        assert_eq!(detect_provider("gpt-5"), "openai");
        assert_eq!(detect_provider("o3"), "openai");
        assert_eq!(detect_provider("o4-mini"), "openai");
        assert_eq!(detect_provider("o1-preview"), "openai");
        // gpt-4o still openai (the trailing "o" must not be read as o-series).
        assert_eq!(detect_provider("gpt-4o"), "openai");
    }

    #[test]
    fn test_detect_provider_unknown_is_not_anthropic() {
        // A truly-unknown model must be "unknown", never silently "anthropic".
        assert_eq!(detect_provider("unknown"), "unknown");
        assert_eq!(detect_provider("some-mystery-model"), "unknown");
    }

    #[test]
    fn test_codex_pricing_is_openai_specific_not_sonnet() {
        // gpt-5-codex must resolve to the Codex row, not Claude Sonnet.
        let codex = ModelPricing::for_model("gpt-5-codex");
        assert!((codex.input_cost_per_1k - 0.001_75).abs() < 1e-9);
        assert!((codex.output_cost_per_1k - 0.014).abs() < 1e-9);

        // Distinct from Sonnet pricing (the historical wrong default).
        let sonnet = ModelPricing::for_model("claude-3-5-sonnet");
        assert!((codex.input_cost_per_1k - sonnet.input_cost_per_1k).abs() > 1e-9);
    }

    #[test]
    fn test_o_series_pricing() {
        let o3 = ModelPricing::for_model("o3");
        assert!((o3.input_cost_per_1k - 0.002).abs() < 1e-9);
        assert!((o3.output_cost_per_1k - 0.008).abs() < 1e-9);

        let o4 = ModelPricing::for_model("o4-mini");
        assert!((o4.input_cost_per_1k - 0.001_1).abs() < 1e-9);
        assert!((o4.output_cost_per_1k - 0.004_4).abs() < 1e-9);
    }

    #[test]
    fn test_gpt4o_pricing_unchanged() {
        // Regression: existing GPT-4o entry preserved.
        let p = ModelPricing::for_model("gpt-4o");
        assert!((p.input_cost_per_1k - 0.005).abs() < 1e-9);
        assert!((p.output_cost_per_1k - 0.015).abs() < 1e-9);
    }

    #[test]
    fn test_unknown_model_priced_as_zero_not_sonnet() {
        // The core issue-#21 guarantee: an unknown model is NOT priced as
        // Claude Sonnet. It gets explicit zero-cost pricing.
        let unknown = ModelPricing::for_model("totally-made-up-model");
        assert!(unknown.input_cost_per_1k.abs() < f64::EPSILON);
        assert!(unknown.output_cost_per_1k.abs() < f64::EPSILON);
        assert!(unknown.cache_read_cost_per_1k.abs() < f64::EPSILON);
        assert!(unknown.cache_write_cost_per_1k.abs() < f64::EPSILON);

        let cost = unknown.calculate_cost(1000, 500, Some(200), Some(50));
        assert!(
            cost.abs() < f64::EPSILON,
            "unknown model must contribute zero cost, not Sonnet cost"
        );
    }

    #[test]
    fn test_parse_without_model_defaults_to_unknown_not_claude() {
        // Output with tokens but no detectable model name must fall back to an
        // explicit "unknown" model + provider, priced at zero (issue #21).
        let output = "Tokens: 1000 in / 500 out";
        let usage = parse_resource_usage(output, None).unwrap();
        assert_eq!(usage.model, "unknown");
        assert_eq!(usage.provider, "unknown");
        assert!(usage.cost_usd.abs() < f64::EPSILON);
    }

    #[test]
    fn test_parse_codex_model_from_output() {
        let output = "Model: gpt-5-codex\nTokens: 1000 in / 500 out";
        let usage = parse_resource_usage(output, None).unwrap();
        assert_eq!(usage.model, "gpt-5-codex");
        assert_eq!(usage.provider, "openai");
        // 1000 in @ 0.00175/1k + 500 out @ 0.014/1k = 0.00175 + 0.007 = 0.00875
        assert!((usage.cost_usd - 0.008_75).abs() < 1e-6);
    }
}
