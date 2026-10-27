#!/usr/bin/env bash
# Day-2 helpers sourced by deploy-ai-gateway-1-of-10.sh
# Provides: validate_provider_config, dependency_matrix, scan_secrets_day2,
#           test_provider_day2

validate_provider_config() {
  log_step "INIT: AI provider configuration"
  local dp="${AI_DEFAULT_PROVIDER:-}" dm="${AI_DEFAULT_MODEL:-}"
  local ge="${GROQ_ENABLED:-false}" gk="${GROQ_API_KEY:-}"
  if [ "$ge" = "true" ] && [ -n "$gk" ]; then
    log_ok "groq: enabled and configured (key present, value never printed)"
  elif [ "$ge" = "true" ]; then
    log_warn "groq: enabled but GROQ_API_KEY is empty -> status not_configured"
  else
    log_skip "groq: disabled"
  fi
  if [ -n "$dp" ] && [ -n "$dm" ]; then
    log_ok "default routing: provider=$dp model=$dm"
  else
    log_warn "No AI_DEFAULT_PROVIDER/AI_DEFAULT_MODEL: /v1/chat will return a controlled no_provider_configured response"
  fi
  # Never a hard failure: the stack must start without any cloud provider.
  return 0
}

# Dependency diagnostics that state WHERE the test ran.
_probe() {  # _probe <location> <host> <port>
  local loc="$1" host="$2" port="$3" dns="UNKNOWN" tcp="UNKNOWN"
  case "$loc" in
    host)
      if getent hosts "$host" >/dev/null 2>&1 || ping -c1 -W1 "$host" >/dev/null 2>&1; then dns=PASS; else dns=FAIL; fi
      if [ "$dns" = "PASS" ] && (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then tcp=PASS; else tcp=FAIL; fi
      ;;
    container)
      local cname="${APP_NAME:-ai-gateway-1-of-10-chat}-api"
      if docker exec "$cname" node -e "require('dns').lookup('$host',e=>process.exit(e?1:0))" >/dev/null 2>&1; then dns=PASS; else dns=FAIL; fi
      if [ "$dns" = "PASS" ] && docker exec "$cname" node -e "const s=require('net').connect($port,'$host');s.on('connect',()=>{s.end();process.exit(0)});s.on('error',()=>process.exit(1));setTimeout(()=>process.exit(1),3000)" >/dev/null 2>&1; then tcp=PASS; else tcp=FAIL; fi
      ;;
  esac
  printf "  TEST LOCATION: %-9s TARGET: %s:%s  DNS: %s  TCP: %s\n" "$loc" "$host" "$port" "$dns" "$tcp" >&2
  [ "$tcp" = "PASS" ]
}

dependency_matrix() {
  log_step "TEST: dependency diagnostics (host vs container)"
  local ok_any=0
  local ph="${POSTGRES_HOST:-}" pp="${POSTGRES_PORT:-5432}"
  local rh="${REDIS_HOST:-}"   rp="${REDIS_PORT:-6379}"
  local cname="${APP_NAME:-ai-gateway-1-of-10-chat}-api"
  local have_container=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname" && have_container=1

  for pair in "postgres $ph $pp" "redis $rh $rp"; do
    set -- $pair
    local svc="$1" host="${2:-}" port="${3:-}"
    if [ -z "$host" ]; then log_skip "$svc: no host configured"; continue; fi
    echo "  --- $svc ---" >&2
    _probe host "$host" "$port" || true
    if [ "$have_container" = "1" ]; then
      if _probe container "$host" "$port"; then ok_any=1; log_ok "$svc reachable from the API container"; \
      else log_fail "$svc NOT reachable from the API container"; fi
    else
      log_skip "$svc: container probe NOT AVAILABLE (API container not running)"
    fi
  done
  log_info "Host failure with container success is expected for Docker service names; do NOT hardcode IPs."
  return 0
}

# Secret scanner that distinguishes references from real credential material.
scan_secrets_day2() {
  log_step "TEST: secret scan (references vs assignments vs credentials)"
  local files findings=0
  if git -C "$ROOT_DIR" rev-parse >/dev/null 2>&1; then
    files=$(git -C "$ROOT_DIR" ls-files)
  else
    files=$(cd "$ROOT_DIR" && find . -type f -not -path "./.git/*" -not -path "./node_modules/*" -not -name ".env" | sed 's|^\./||')
  fi

  if git -C "$ROOT_DIR" rev-parse >/dev/null 2>&1; then
    if git -C "$ROOT_DIR" check-ignore -q .env 2>/dev/null; then log_ok ".env is git-ignored"; \
    else log_fail ".env is NOT git-ignored"; findings=$((findings+1)); fi
  else
    grep -qx '\.env' "$ROOT_DIR/.gitignore" 2>/dev/null && log_ok ".env listed in .gitignore" || \
      { log_fail ".env not in .gitignore"; findings=$((findings+1)); }
  fi

  # Credential-looking material only (values, not references/placeholders).
  local cred='(gsk_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})'
  local assign='^[^:]+:[0-9]+:[[:space:]]*(export[[:space:]]+)?[A-Z0-9_]*(API_KEY|SECRET|PASSWORD|TOKEN)[A-Z0-9_]*[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9/+=_-]{8,}'
  local f n
  for f in $files; do
    [ -f "$ROOT_DIR/$f" ] || continue
    case "$f" in .env|*.day1.bak) continue ;; esac
    n=$(grep -InE "$cred" "$ROOT_DIR/$f" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
    if [ -n "$n" ]; then log_fail "Credential-like material in $f (lines: $n) — value not printed"; findings=$((findings+1)); fi
    n=$(grep -InE "(API_KEY|SECRET|PASSWORD|TOKEN)[A-Z0-9_]*[[:space:]]*=[[:space:]]*[\"']?[A-Za-z0-9/+=_-]{8,}" "$ROOT_DIR/$f" 2>/dev/null \
        | grep -vE '\$\{?[A-Za-z_]' | grep -vE '=[[:space:]]*(""|'"''"')?[[:space:]]*$' | cut -d: -f1 | tr '\n' ' ')
    if [ -n "$n" ]; then log_fail "Hardcoded secret assignment in $f (lines: $n) — value not printed"; findings=$((findings+1)); fi
  done
  if [ "$findings" -eq 0 ]; then
    log_ok "No credential material in tracked files (\${VAR} references are not leaks)"
    return 0
  fi
  return 1
}

test_provider_day2() {
  log_step "TEST: provider unit tests"
  if command -v node >/dev/null 2>&1; then
    if (cd "$ROOT_DIR" && node --test tests/*.test.mjs >/dev/null 2>&1); then
      log_ok "provider/model registry unit tests passed"
    else
      log_fail "provider/model registry unit tests failed (run: node --test tests/*.test.mjs)"
      return 1
    fi
  else
    log_skip "node not available; unit tests NOT AVAILABLE"
  fi
  log_step "TEST: provider API tests"
  if [ -x "$ROOT_DIR/tests/provider_test.sh" ]; then
    "$ROOT_DIR/tests/provider_test.sh" "http://127.0.0.1:${API_PORT:-4400}" || return 1
  else
    log_skip "tests/provider_test.sh missing"
  fi
  return 0
}
