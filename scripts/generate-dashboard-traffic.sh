#!/bin/bash
# Generate traffic for MaaS observability dashboard demo
# Usage: ./generate-dashboard-traffic.sh [API_KEY]
#
# This script sends ~10 requests with various outcomes:
# - Successful authenticated requests (200)
# - Unauthenticated requests (401)
# - Invalid key requests (403)
# - Rate limit trigger attempts (429)

set -euo pipefail

# Configuration
MAAS_GW="${MAAS_GW:-maas.apps.cluster-6crhb.6crhb.sandbox1011.opentlc.com}"
MODEL="${MODEL:-gemma2-9b-fp8}"
API_KEY="${1:-${API_KEY:-}}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }

# Function to make a request and report status
make_request() {
    local description="$1"
    local auth_header="$2"
    local expected_code="$3"
    local prompt="${4:-What is 2+2?}"
    
    log "Request: $description"
    
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" -X POST "https://${MAAS_GW}/v1/chat/completions" \
        ${auth_header:+-H "Authorization: Bearer $auth_header"} \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${MODEL}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"$prompt\"}],
            \"max_tokens\": 50
        }" 2>/dev/null || echo -e "\n000")
    
    http_code=$(echo "$response" | tail -1)
    
    if [[ "$http_code" == "$expected_code" ]]; then
        success "Got expected $http_code"
    else
        fail "Expected $expected_code, got $http_code"
    fi
    
    echo ""
    sleep 1
}

echo ""
echo "=========================================="
echo "  MaaS Dashboard Traffic Generator"
echo "=========================================="
echo "Gateway: $MAAS_GW"
echo "Model:   $MODEL"
echo ""

if [[ -z "$API_KEY" ]]; then
    warn "No API_KEY provided. Skipping authenticated requests."
    warn "Usage: $0 <API_KEY> or export API_KEY=..."
    echo ""
fi

# === UNAUTHENTICATED REQUESTS (401) ===
echo "--- Unauthenticated Requests (expect 401) ---"
echo ""

make_request "No auth header" "" "401" "Hello"
make_request "Empty auth header" "" "401" "Hi there"

# === INVALID KEY REQUESTS (403) ===
echo "--- Invalid Key Requests (expect 403) ---"
echo ""

make_request "Invalid API key" "invalid-key-12345" "403" "Test invalid"
make_request "Malformed key" "not-a-valid-key" "403" "Test malformed"

# === AUTHENTICATED REQUESTS (200) ===
if [[ -n "$API_KEY" ]]; then
    echo "--- Authenticated Requests (expect 200) ---"
    echo ""
    
    make_request "Simple math question" "$API_KEY" "200" "What is 2+2?"
    make_request "Code question" "$API_KEY" "200" "Write hello world in Python"
    make_request "Short question" "$API_KEY" "200" "What is AI?"
    make_request "Greeting" "$API_KEY" "200" "Hello, how are you?"
    
    # === RATE LIMIT TEST (may get 429 if limits are low) ===
    echo "--- Rapid Fire (may trigger 429) ---"
    echo ""
    
    for i in {1..3}; do
        log "Rapid request $i"
        curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "https://${MAAS_GW}/v1/chat/completions" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Quick $i\"}], \"max_tokens\": 10}" &
    done
    wait
    echo ""
fi

# === SUMMARY ===
echo "=========================================="
echo "  Traffic Generation Complete"
echo "=========================================="
echo ""
echo "Requests sent:"
echo "  - 2x Unauthenticated (401)"
echo "  - 2x Invalid key (403)"
if [[ -n "$API_KEY" ]]; then
    echo "  - 4x Authenticated (200)"
    echo "  - 3x Rapid fire (200 or 429)"
fi
echo ""
echo "View metrics in RHOAI Dashboard:"
echo "  https://rh-ai.apps.cluster-6crhb.6crhb.sandbox1011.opentlc.com/observe-and-monitor/dashboard"
echo ""
