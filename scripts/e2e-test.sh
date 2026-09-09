#!/bin/bash
# =============================================================================
# Fluxer chart — E2E on KinD (GitHub Actions) or a local cluster.
# Real assertions: HTTP health, discovery JSON, postgres migration, SeaweedFS
# buckets, web client. No vacuous checks. Exits non-zero on failure.
#
# Requires: kubectl, curl, python3. The chart must already be installed in
# $NAMESPACE (release $RELEASE). Storage: KinD default `standard`.
# =============================================================================
set -uo pipefail

NAMESPACE="${NAMESPACE:-fluxer}"
RELEASE="${RELEASE:-fluxer}"
TIMEOUT_OK="${TIMEOUT_OK:-420}"

PASS=0
FAIL=0
PF_PIDS=()

step() { echo -e "\n\033[0;34m== $1 ==\033[0m"; }
ok()   { echo -e "  \033[0;32m✓ $1\033[0m"; PASS=$((PASS+1)); }
fail() { echo -e "  \033[0;31m✗ $1\033[0m"; FAIL=$((FAIL+1)); }
info() { echo -e "  \033[0;33mℹ $1\033[0m"; }
die()  { echo -e "\n\033[0;31m✗ FAILED: $1\033[0m"; exit 1; }

cleanup() {
  for p in "${PF_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  kubectl delete pod fluxer-e2e -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
}
trap cleanup EXIT

check_prereqs() {
  for c in kubectl curl python3; do
    command -v "$c" >/dev/null 2>&1 || die "missing prerequisite: $c"
  done
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || die "namespace '$NAMESPACE' does not exist"
  ok "prerequisites OK (kubectl/curl/python3) + namespace $NAMESPACE"
}

wait_rollouts() {
  step "Wait: Deployments/StatefulSets ready"
  for kind in deployments statefulsets; do
    local names
    names=$(kubectl get "$kind" -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    for n in $names; do
      if kubectl rollout status "$kind/$n" -n "$NAMESPACE" --timeout="${TIMEOUT_OK}s" >/dev/null 2>&1; then
        ok  "rollout $kind/$n"
      else
        fail "rollout $kind/$n did not become ready"
        kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null | tail -n +1
        return 1
      fi
    done
  done
}

wait_buckets_job() {
  step "Wait: seaweedfs-init Job (creates buckets)"
  local i=0
  while [ "$i" -lt 40 ]; do
    local s
    s=$(kubectl get job seaweedfs-init -n "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    if [ "${s:-0}" -ge 1 ]; then ok "seaweedfs-init Job completed (succeeded=${s})"; return 0; fi
    i=$((i+1)); sleep 5
  done
  fail "seaweedfs-init Job did not complete"
  kubectl get job seaweedfs-init -n "$NAMESPACE" -o yaml 2>/dev/null | tail -30 || true
  return 1
}

check_postgres_migrations() {
  step "Postgres: migration evidence (fluxer_kv table)"
  local rel
  rel=$(kubectl exec sts/postgres-0 -n "$NAMESPACE" -- sh -c \
    'PGPASSWORD="${FLUXER_POSTGRES_PASSWORD:-postgres}" psql -h 127.0.0.1 -p 5432 -U fluxer -d fluxer -tAc "SELECT to_regclass('"'"'public.fluxer_kv'"'"')"' 2>/dev/null || true)
  if echo "$rel" | grep -qi 'fluxer_kv'; then ok "migration created public.fluxer_kv"; else fail "fluxer_kv not found (rel='$rel')"; fi
}

http_assert() {
  local label=$1 svc=$2 tport=$3 lport=$4 path=$5
  kubectl port-forward -n "$NAMESPACE" "svc/$svc" "$lport:$tport" >/tmp/pf-"$svc".log 2>&1 &
  PF_PIDS+=("$!")
  local i=0 code=""
  while [ "$i" -lt 40 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$lport/$path" 2>/dev/null || echo 000)
    [ "$code" != "000" ] && break
    i=$((i+1)); sleep 1
  done
  if [ "$code" = "200" ]; then ok "$label -> HTTP $code ($path)"; return 0; else fail "$label -> HTTP ${code:-timeout} ($svc/$path)"; return 1; fi
}

check_discovery() {
  step "Discovery: /.well-known/fluxer (api/gateway/media/static/admin)"
  kubectl port-forward -n "$NAMESPACE" "svc/api" 18080:8080 >/tmp/pf-api.log 2>&1 &
  PF_PIDS+=("$!")
  local i=0 body=""
  while [ "$i" -lt 40 ]; do
    body=$(curl -s -H "Host: fluxer.local" -H "x-forwarded-host: fluxer.local" -H "x-forwarded-proto: http" "http://127.0.0.1:18080/.well-known/fluxer" 2>/dev/null || true)
    echo "$body" | grep -q 'well-known\|"api"' && break
    i=$((i+1)); sleep 1
  done
  if echo "$body" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
need=["api","gateway","media","static_cdn","admin"]
missing=[k for k in need if k not in d]
sys.exit(0 if not missing else 1)
' 2>/dev/null; then
    ok "discovery JSON has api/gateway/media/static_cdn/admin"
  else
    fail "discovery JSON invalid or endpoints missing: $(echo "$body" | head -c 300)"
  fi
}

check_web() {
  step "Web client (app-proxy) serves the SPA"
  local body="" i=0
  while [ "$i" -lt 40 ]; do
    body=$( { curl -s "http://127.0.0.1:58080/"; } 2>/dev/null || true )
    echo "$body" | grep -qi 'Fluxer' && break
    i=$((i+1)); sleep 1
  done
  if echo "$body" | grep -qi 'Fluxer' && echo "$body" | grep -qi '<html'; then
    ok "app-proxy serves HTML with Fluxer title/root"
  else
    fail "app-proxy did not return the expected SPA (len=${#body})"
  fi
}

main() {
  echo -e "\033[0;34m════════════════════════════════════════════════════@\033[0m"
  echo -e "\033[0;34m  FLUXER E2E (release=$RELEASE ns=$NAMESPACE)\033[0m"
  echo -e "\033[0;34m════════════════════════════════════════════════════@\033[0m"

  check_prereqs
  wait_rollouts || true
  wait_buckets_job || true

  check_postgres_migrations

  http_assert "API health"          api           8080 18081 "_health"
  http_assert "Media-proxy health"  media-proxy   8080 28081 "_health"
  http_assert "Admin health"        admin         8080 38081 "_health"
  http_assert "Gateway health"      gateway       8080 48081 "_health"
  http_assert "LiveKit signaling"   livekit       7880 67880 "_health"

  check_discovery

  kubectl port-forward -n "$NAMESPACE" "svc/app-proxy" 58080:8080 >/tmp/pf-appproxy.log 2>&1 &
  PF_PIDS+=("$!")
  sleep 3
  check_web

  echo ""
  echo -e "\033[0;34m──────────── SUMMARY ────────────\033[0m"
  echo -e "  \033[0;32mPASS:  $PASS\033[0m"
  echo -e "  \033[0;31mFAILURES: $FAIL\033[0m"
  [ "$FAIL" -eq 0 ] || { echo -e "\033[0;31mE2E FAILED\033[0m"; exit 1; }
  echo -e "\033[0;32mE2E PASSED ✔\033[0m"
}

main "$@"
