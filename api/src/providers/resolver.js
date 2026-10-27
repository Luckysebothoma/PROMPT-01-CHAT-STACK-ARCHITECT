import { providerEnv } from "../lib/providerEnv.js";
import { getProvider } from "./provider.registry.js";
import { findModel, findModelAnyProvider } from "./model.registry.js";

// Deterministic resolution order:
//   1. explicit provider   2. explicit model   3. (agent mapping: PROMPT-03)
//   4. AI_DEFAULT_PROVIDER 5. AI_DEFAULT_MODEL 6. controlled failure
export function resolveTarget({ provider, model }) {
  let providerName = provider || null;
  let modelKey = model || null;

  if (!providerName && modelKey) {
    const m = findModelAnyProvider(modelKey);
    if (m) providerName = m.provider;
  }
  if (!providerName) providerName = providerEnv.DEFAULT_PROVIDER || null;
  if (!modelKey) modelKey = providerEnv.DEFAULT_MODEL || null;

  if (!providerName || !modelKey) {
    return { ok: false, code: "no_provider_configured",
      message: "No AI provider or model is configured for this gateway" };
  }

  const adapter = getProvider(providerName);
  if (!adapter) {
    return { ok: false, code: "unknown_provider",
      message: `Provider '${providerName}' is not registered` };
  }
  const health = adapter.health();
  if (health.status !== "available") {
    return { ok: false, code: "provider_unavailable",
      message: `Provider '${providerName}' is ${health.status}` };
  }
  if (provider && model && !findModel(providerName, modelKey)) {
    return { ok: false, code: "unknown_model",
      message: `Model '${modelKey}' is not registered for provider '${providerName}'` };
  }

  return { ok: true, provider: providerName, model: modelKey, adapter };
}
