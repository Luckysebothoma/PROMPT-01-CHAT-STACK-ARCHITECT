import { ProviderAdapter, ProviderError } from "./provider.interface.js";
import { providerEnv, providerConfigured } from "../lib/providerEnv.js";

export class GroqProvider extends ProviderAdapter {
  constructor() {
    super("groq");
    this.cfg = providerEnv.groq;
  }

  metadata() {
    return {
      name: this.cfg.name,
      display_name: this.cfg.display_name,
      enabled: this.cfg.enabled,
      configured: providerConfigured(this.cfg),
      base_url: this.cfg.baseUrl,   // never the key
      supports_streaming: false,    // not implemented in this iteration
      supports_json: null,          // unknown per model; not fabricated
      supports_tools: null,
    };
  }

  // Lightweight configuration check only. No live API call.
  health() {
    const m = this.metadata();
    let status = "unavailable";
    if (!m.enabled) status = "disabled";
    else if (!m.configured) status = "not_configured";
    else status = "available";
    return { enabled: m.enabled, configured: m.configured, status };
  }

  async chat({ model, instruction, message, temperature }) {
    if (!providerConfigured(this.cfg)) {
      throw new ProviderError("provider_not_configured", "Provider is not configured");
    }
    const messages = [];
    if (instruction) messages.push({ role: "system", content: instruction });
    messages.push({ role: "user", content: message });

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), providerEnv.REQUEST_TIMEOUT_MS);
    let res;
    try {
      res = await fetch(`${this.cfg.baseUrl.replace(/\/$/, "")}/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.cfg.apiKey}`,
        },
        body: JSON.stringify({
          model,
          messages,
          ...(typeof temperature === "number" ? { temperature } : {}),
        }),
        signal: controller.signal,
      });
    } catch (err) {
      throw new ProviderError("provider_unreachable", "Upstream AI provider request failed");
    } finally {
      clearTimeout(timer);
    }

    if (!res.ok) {
      // Upstream body is deliberately NOT propagated to the client.
      throw new ProviderError("provider_error", "Upstream AI provider returned an error", res.status);
    }

    let payload;
    try { payload = await res.json(); }
    catch { throw new ProviderError("provider_bad_response", "Upstream AI provider returned an unreadable response"); }

    const content = payload?.choices?.[0]?.message?.content;
    if (typeof content !== "string") {
      throw new ProviderError("provider_bad_response", "Upstream AI provider returned no content");
    }

    const u = payload?.usage;
    const usage = u && typeof u.prompt_tokens === "number" && typeof u.completion_tokens === "number"
      ? {
          input_tokens: u.prompt_tokens,
          output_tokens: u.completion_tokens,
          total_tokens: typeof u.total_tokens === "number"
            ? u.total_tokens
            : u.prompt_tokens + u.completion_tokens,
        }
      : null;   // provider did not report usage -> explicitly unavailable

    return { content, model: payload?.model || model, usage };
  }
}
