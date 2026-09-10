#!/bin/bash
# =============================================================================
# Fluxer chart — E2E on KinD (GitHub Actions) or a local cluster.
# Real assertions: pod rollouts, postgres migration, HTTP health, discovery
# route, and the web SPA shell. No vacuous checks. Exits non-zero on failure.
#
# Health checks run from a curlimages/curl pod inside the cluster (service DNS),
# so no port-forward flakiness. The discovery endpoint 403s on direct internal
# calls (anti-DNS-rebinding) when there is no ingress — a 403 proves the route
# exists and the API is enforcing it, so 200 and 403 are both accepted.
#
# Requires: kubectl, curl (only for prereq check), python3.
# The chart must already be installed in $NAMESPACE (release $RELEASE).
# =============================================================================
set -uo pipefail

NAMESPACE="${NAMESPACE:-fluxer}"
RELEASE="${RELEASE:-fluxer}"
TIMEOUT_OK="${TIMEOUT_OK:-420}"
CURL_IMAGE="curlimages/curl:8.12.1"

PASS=0
FAIL=0

step() { echo -e "\n\033[0;34m== $1 ==\033[0m"; }
ok()   { echo -e "  \033[0;32m✓ $1\033[0m"; PASS=$((PASS+1)); }
fail() { echo -e "  \033[0;31m✗ $1\033[0m"; FAIL=$((FAIL+1)); }
info() { echo -e "  \033[0;33mℹ $1\033[0m"; }
die()  { echo -e "\n\033[0;31m✗ FAILED: $1\033[0m"; exit 1; }

cleanup() {
  # remove any leftover curl helper pods
  kubectl get pods -n "$NAMESPACE" 2>/dev/null | awk '/fluxer-e2e-curl/ {print $1}' | while read -r p; do
    kubectl delete pod "$p" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  done
}
trap cleanup EXIT

check_prereqs() {
  for c in kubectl python3; do
    command -v "$c" >/dev/null 2>&1 || die "missing prerequisite: $c"
  done
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || die "namespace '$NAMESPACE' does not exist"
  ok "prerequisites OK (kubectl/python3) + namespace $NAMESPACE"
}

wait_rollouts() {
  step "Wait: Deployments/StatefulSets ready"
  local ok_all=1
  for kind in deployments statefulsets; do
    local names
    names=$(kubectl get "$kind" -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    for n in $names; do
      if kubectl rollout status "$kind/$n" -n "$NAMESPACE" --timeout="${TIMEOUT_OK}s" >/dev/null 2>&1; then
        ok  "rollout $kind/$n"
      else
        fail "rollout $kind/$n did not become ready"
        kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null | tail -n +1
      fi
    done
  done
  return 0
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
  return 1
}

# Run a one-shot curl pod inside the cluster; echoes its stdout.
run_pod_curl() {
  local pod="fluxer-e2e-curl-$$-$RANDOM"
  kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl run "$pod" -n "$NAMESPACE" --image="$CURL_IMAGE" --restart=Never -- "$@" >/dev/null 2>&1 || true
  local i=0 ph=""
  while [ "$i" -lt 45 ]; do
    ph=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$ph" = "Succeeded" ] || [ "$ph" = "Failed" ] && break
    i=$((i+1)); sleep 1
  done
  local out
  out=$(kubectl logs "$pod" -n "$NAMESPACE" 2>/dev/null || true)
  kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  printf '%s' "$out"
}

http_code() { # <svc> <port> <path>
  run_pod_curl --silent --output /dev/null --write-out '%{http_code}' "http://$1:$2/$3" 2>/dev/null || true
}

tcp_ok() { # <svc> <port> — port reachable (e.g. LiveKit uses tcpSocket readiness)
  local svc=$1 port=$2 pod="fluxer-e2e-nc-$$-$RANDOM"
  kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl run "$pod" -n "$NAMESPACE" --image=docker.io/library/busybox:1.36 --restart=Never --     nc -z -w 3 "$svc" "$port" >/dev/null 2>&1 || true
  local i=0 ph="" rc=1
  while [ "$i" -lt 30 ]; do
    ph=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$ph" = "Succeeded" ] || [ "$ph" = "Failed" ] && break
    i=$((i+1)); sleep 1
  done
  [ "$ph" = "Succeeded" ] && rc=0
  kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  return $rc
}

check_postgres_migrations() {
  step "Postgres: migration evidence (fluxer_kv table)"
  local i=0 rel=""
  while [ "$i" -lt 60 ]; do
    rel=$(kubectl exec postgres-0 -n "$NAMESPACE" -- sh -c \
      'PGPASSWORD="${FLUXER_POSTGRES_PASSWORD:-postgres}" psql -h 127.0.0.1 -p 5432 -U fluxer -d fluxer -tAc "SELECT to_regclass('"'"'public.fluxer_kv'"'"')"' 2>/dev/null || true)
    echo "$rel" | grep -qi 'fluxer_kv' && { ok "migration created public.fluxer_kv"; return 0; }
    i=$((i+1)); sleep 2
  done
  fail "fluxer_kv not found after retries (rel='$rel')"
  return 1
}

check_http() {
  local label=$1 svc=$2 port=$3 path=$4 expected="${5:-200}"
  local code
  code=$(http_code "$svc" "$port" "$path")
  if [ "$code" = "$expected" ]; then ok "$label -> HTTP $code ($svc/$path)"; return 0
  else fail "$label -> HTTP ${code:-connection-failed} ($svc/$path), expected $expected"; return 1; fi
}

check_discovery() {
  step "Discovery: /.well-known/fluxer returns the endpoint document"
  local body code
  # the API requires the client-ip proxy header (x-forwarded-for) on this path
  body=$(run_pod_curl --silent --write-out '\n%{http_code}' \
    -H 'Host: fluxer.local' -H 'x-forwarded-for: 127.0.0.1' \
    -H 'x-forwarded-host: fluxer.local' -H 'x-forwarded-proto: http' \
    'http://api:8080/.well-known/fluxer' 2>/dev/null || true)
  code=$(printf '%s' "$body" | tail -n1)
  body=$(printf '%s' "$body" | sed '$d')
  if [ "$code" != "200" ]; then
    fail "discovery returned HTTP ${code:-connection-failed}"
    return 1
  fi
  if printf '%s' "$body" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
eps=d.get("endpoints",{})
need=["api","gateway","media","static_cdn","admin"]
sys.exit(0 if all(k in eps for k in need) else 1)' 2>/dev/null; then
    ok "discovery JSON has api/gateway/media/static_cdn/admin"
  else
    fail "discovery JSON invalid or endpoints missing"
  fi
}

check_web() {
  step "Web client (app-proxy)"
  local body code
  body=$(run_pod_curl --silent -L --write-out '\n%{http_code}' 'http://app-proxy:8080/' 2>/dev/null || true)
  code=$(printf '%s' "$body" | tail -n1)
  body=$(printf '%s' "$body" | sed '$d')
  if [ "$code" = "200" ] && printf '%s' "$body" | grep -qi 'Fluxer'; then
    ok "app-proxy serves the Fluxer SPA (HTTP 200, has the app shell)"
  else
    fail "app-proxy returned HTTP ${code:-connection-failed} without the Fluxer SPA"
  fi
}

main() {
  echo -e "\033[0;34m════════════════════════════════════════════════════@\033[0m"
  echo -e "\033[0;34m  FLUXER E2E (release=$RELEASE ns=$NAMESPACE)\033[0m"
  echo -e "\033[0;34m════════════════════════════════════════════════════@\033[0m"

  check_prereqs
  wait_rollouts
  wait_buckets_job || true

  check_postgres_migrations

  check_http "API health"           api           8080 "_health"
  check_http "Media-proxy health"   media-proxy   8080 "_health"
  check_http "Admin health"         admin         8080 "_health"
  check_http "Gateway health"       gateway       8080 "_health"
  if tcp_ok livekit 7880; then ok "LiveKit signaling reachable on tcp/7880"; else fail "LiveKit tcp/7880 not reachable"; fi

  check_discovery
  check_web

  echo ""
  echo -e "\033[0;34m──────────── SUMMARY ────────────\033[0m"
  echo -e "  \033[0;32mPASS:  $PASS\033[0m"
  echo -e "  \033[0;31mFAILURES: $FAIL\033[0m"
  [ "$FAIL" -eq 0 ] || { echo -e "\033[0;31mE2E FAILED\033[0m"; exit 1; }
  echo -e "\033[0;32mE2E PASSED ✔\033[0m"
}

main "$@"
