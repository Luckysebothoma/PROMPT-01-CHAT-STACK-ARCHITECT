import { providerEnv } from "../lib/providerEnv.js";

// Supported categories. Only categories that are actually implemented are
// used; the structure allows more to be added without schema changes.
export const CATEGORIES = [
  "chat", "reasoning", "code", "json", "writing",
  "content", "analysis", "vision", "embedding", "audio", "voice",
];

// Models are declared by the operator via <PROVIDER>_MODELS, e.g.
//   GROQ_MODELS=some-provider-model-id:chat,another-model-id:reasoning
// No model identifiers are invented by the gateway.
function parseModels(providerName, spec) {
  const out = [];
  for (const raw of String(spec || "").split(",")) {
    const item = raw.trim();
    if (!item) continue;
    const [key, category] = item.split(":").map((s) => (s || "").trim());
    if (!key) continue;
    out.push({
      provider: providerName,
      model_key: key,
      display_name: key,
      category: CATEGORIES.includes(category) ? category : "chat",
      enabled: true,
      temperature_default: null,   // unknown unless declared
      context_window: null,        // unknown -> null, never fabricated
      supports_streaming: false,   // streaming not implemented this iteration
      supports_json: null,
      supports_tools: null,
    });
  }
  return out;
}

let registry = null;

export function buildRegistry() {
  const models = [...parseModels("groq", providerEnv.groq.models)];
  // The configured default model is always resolvable even if not listed.
  const dp = providerEnv.DEFAULT_PROVIDER;
  const dm = providerEnv.DEFAULT_MODEL;
  if (dp && dm && !models.some((m) => m.provider === dp && m.model_key === dm)) {
    models.push({
      provider: dp, model_key: dm, display_name: dm, category: "chat",
      enabled: true, temperature_default: null, context_window: null,
      supports_streaming: false, supports_json: null, supports_tools: null,
    });
  }
  return models;
}

export function listModels() {
  if (!registry) registry = buildRegistry();
  return registry;
}
export function findModel(provider, modelKey) {
  return listModels().find(
    (m) => m.provider === provider && m.model_key === modelKey && m.enabled
  ) || null;
}
export function findModelAnyProvider(modelKey) {
  return listModels().find((m) => m.model_key === modelKey && m.enabled) || null;
}
export function resetRegistry() { registry = null; }
