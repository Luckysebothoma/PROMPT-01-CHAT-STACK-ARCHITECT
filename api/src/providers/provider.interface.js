// ProviderAdapter contract. Every adapter MUST implement:
//   metadata() -> { name, display_name, enabled, configured, base_url }
//   health()   -> { enabled, configured, status }   (no live network call)
//   chat({ model, instruction, message, temperature })
//        -> { content, model, usage: { input_tokens, output_tokens, total_tokens } | null }
// usage MUST be null when the provider does not report it. Never estimate.
export class ProviderAdapter {
  constructor(name) { this.name = name; }
  metadata() { throw new Error("metadata() not implemented"); }
  health() { throw new Error("health() not implemented"); }
  async chat() { throw new Error("chat() not implemented"); }
}

export class ProviderError extends Error {
  constructor(code, message, providerStatus) {
    super(message);
    this.code = code;                     // safe, non-leaking code
    this.providerStatus = providerStatus || null;
  }
}
