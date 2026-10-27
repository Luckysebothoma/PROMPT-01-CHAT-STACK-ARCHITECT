import { test } from "node:test";
import assert from "node:assert/strict";

process.env.AI_DEFAULT_PROVIDER = process.env.AI_DEFAULT_PROVIDER || "";
process.env.AI_DEFAULT_MODEL = process.env.AI_DEFAULT_MODEL || "";

const { getProvider, providerHealthMap } = await import("../api/src/providers/provider.registry.js");
const { listModels, CATEGORIES } = await import("../api/src/providers/model.registry.js");
const { resolveTarget } = await import("../api/src/providers/resolver.js");

test("provider registry exposes the groq adapter", () => {
  const p = getProvider("groq");
  assert.ok(p);
  const m = p.metadata();
  assert.equal(m.name, "groq");
  assert.ok(!("apiKey" in m), "metadata must never expose credentials");
  assert.ok(!JSON.stringify(m).includes(process.env.GROQ_API_KEY || "__none__"));
});

test("provider health never performs a live call and never leaks secrets", () => {
  const h = providerHealthMap();
  assert.ok(h.groq);
  assert.ok(["available", "disabled", "not_configured", "unavailable"].includes(h.groq.status));
  assert.equal(JSON.stringify(h).toLowerCase().includes("key"), false);
});

test("unknown provider fails in a controlled way", () => {
  const r = resolveTarget({ provider: "does-not-exist", model: "x" });
  assert.equal(r.ok, false);
  assert.equal(r.code, "unknown_provider");
});

test("no configuration yields no_provider_configured, never a fabricated answer", () => {
  const r = resolveTarget({ provider: null, model: null });
  if (!process.env.AI_DEFAULT_PROVIDER || !process.env.AI_DEFAULT_MODEL) {
    assert.equal(r.ok, false);
    assert.equal(r.code, "no_provider_configured");
  }
});

test("model registry only contains operator-declared models", () => {
  for (const m of listModels()) {
    assert.ok(CATEGORIES.includes(m.category));
    assert.equal(m.supports_streaming, false);
    assert.ok(m.context_window === null || typeof m.context_window === "number");
  }
});
