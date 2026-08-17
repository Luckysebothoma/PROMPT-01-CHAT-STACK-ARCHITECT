# Security - ai-gateway-1-of-10-chat

## Principles

- No authentication is implemented in this iteration; do not expose this
  service directly to untrusted networks.
- No secrets are committed to this repository. .env is gitignored;
  only .env.example (with empty values) is tracked.
- No API keys, passwords, or Authorization headers are logged or
  persisted to the database.
- Raw prompts/messages are not persisted; only request metadata
  (operation, agent_name, provider, model, status, timing) is stored.
- docker-compose.yml uses environment variable substitution only; it
  never contains literal credentials.

## Secret scanning

The `test` command runs a basic repository grep for patterns such as
API_KEY, SECRET, PASSWORD, TOKEN, AUTHORIZATION, PRIVATE_KEY outside of
.env.example and reports any matches for manual review.

## Reporting

This is an internal/self-hosted project artifact. Review findings from
`./deploy-ai-gateway-1-of-10-chat.sh test` before any deployment beyond
a local/trusted network.
