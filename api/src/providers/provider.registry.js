import { GroqProvider } from "./groq.provider.js";

const adapters = new Map();
adapters.set("groq", new GroqProvider());
// Additional adapters (gemini, openai, ...) register here in later iterations.

export function getProvider(name) {
  return adapters.get(String(name || "").toLowerCase()) || null;
}
export function listProviders() {
  return Array.from(adapters.values());
}
export function providerHealthMap() {
  const out = {};
  for (const a of adapters.values()) out[a.name] = a.health();
  return out;
}
export function anyProviderAvailable() {
  return listProviders().some((a) => a.health().status === "available");
}
