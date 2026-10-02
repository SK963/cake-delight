#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Cake Delight – Start All Services
# Usage: ./start.sh [--infra-only | --all | --stop]
# ═══════════════════════════════════════════════════════════════════════════

set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BOLD}═══ $1 ═══${NC}\n"; }

# ── Help ─────────────────────────────────────────────────────────────────
usage() {
  echo ""
  echo -e "${BOLD}Cake Delight – Service Launcher${NC}"
  echo ""
  echo "Usage: ./start.sh [option]"
  echo ""
  echo "Options:"
  echo "  --infra-only    Start only MongoDB + Kafka (data layer)"
  echo "  --all           Start infra via Docker + all Node services locally"
  echo "  --stop          Stop all running services"
  echo "  --help          Show this help message"
  echo ""
  echo "Default (no args): Start infra + all Node services + UI dev server"
  echo ""
}

# ── Wait for a service to be healthy ─────────────────────────────────────
wait_for_healthy() {
  local container=$1
  local max_wait=${2:-60}
  local elapsed=0

  info "Waiting for ${BOLD}$container${NC} to be healthy..."
  while [ $elapsed -lt $max_wait ]; do
    local status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    if [ "$status" = "healthy" ]; then
      log "$container is healthy"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  err "$container did not become healthy within ${max_wait}s"
  return 1
}

# ── Start Infrastructure ─────────────────────────────────────────────────
start_infra() {
  header "Starting Data Layer (MongoDB + Kafka KRaft)"

  docker compose -f docker-compose.infra.yml up -d
  echo ""

  wait_for_healthy cake-mongo 30
  wait_for_healthy cake-kafka 60

  log "Infrastructure is ready"
  echo ""
  echo -e "  MongoDB : ${CYAN}mongodb://localhost:27017${NC}"
  echo -e "  Kafka   : ${CYAN}localhost:29092${NC} (external) / ${CYAN}kafka:9092${NC} (internal)"
  echo ""
}

# ── Start a Node service in background ───────────────────────────────────
start_service() {
  local name=$1
  local dir=$2
  local port=$3

  if [ ! -d "$dir" ]; then
    err "Directory $dir not found – skipping $name"
    return 1
  fi

  # Install deps if needed
  if [ ! -d "$dir/node_modules" ]; then
    info "Installing dependencies for $name..."
    (cd "$dir" && npm install --silent) || { err "npm install failed for $name"; return 1; }
  fi

  # Kill existing process on this port (if any)
  local pid=$(lsof -ti :"$port" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    warn "Port $port in use (PID $pid) – killing..."
    kill -9 $pid 2>/dev/null || true
    sleep 1
  fi

  # Start in background
  info "Starting ${BOLD}$name${NC} on port $port..."
  (cd "$dir" && npm start > /tmp/cake-${name}.log 2>&1 &)
  sleep 2

  # Verify it started
  local new_pid=$(lsof -ti :"$port" 2>/dev/null || true)
  if [ -n "$new_pid" ]; then
    log "$name running (PID $new_pid) → http://localhost:$port"
  else
    err "$name failed to start – check /tmp/cake-${name}.log"
  fi
}

# ── Start all Node services ──────────────────────────────────────────────
start_services() {
  header "Starting Microservices"

  start_service "catalog-service"      "$ROOT_DIR/catalog-service"      3001
  start_service "order-service"        "$ROOT_DIR/order-service"        3002
  start_service "rating-service"       "$ROOT_DIR/rating-service"       3003
  start_service "notification-service" "$ROOT_DIR/notification-service" 3004
  start_service "api-gateway"          "$ROOT_DIR/api-gateway"          3000
}

# ── Start UI dev server ──────────────────────────────────────────────────
start_ui() {
  header "Starting UI Dev Server"

  local ui_dir="$ROOT_DIR/UI"
  if [ ! -d "$ui_dir" ]; then
    err "UI directory not found"
    return 1
  fi

  if [ ! -d "$ui_dir/node_modules" ]; then
    info "Installing UI dependencies..."
    (cd "$ui_dir" && npm install --silent)
  fi

  # Kill existing Vite server
  local pid=$(lsof -ti :5173 2>/dev/null || true)
  if [ -n "$pid" ]; then
    warn "Port 5173 in use – killing..."
    kill -9 $pid 2>/dev/null || true
    sleep 1
  fi

  info "Starting Vite dev server..."
  (cd "$ui_dir" && npx vite --host > /tmp/cake-ui.log 2>&1 &)
  sleep 3

  local new_pid=$(lsof -ti :5173 2>/dev/null || true)
  if [ -n "$new_pid" ]; then
    log "UI running (PID $new_pid) → http://localhost:5173"
  else
    err "UI failed to start – check /tmp/cake-ui.log"
  fi
}

# ── Stop everything ──────────────────────────────────────────────────────
stop_all() {
  header "Stopping All Services"

  # Stop Node services
  for port in 3000 3001 3002 3003 3004 5173; do
    local pid=$(lsof -ti :"$port" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      kill -9 $pid 2>/dev/null || true
      log "Stopped process on port $port"
    fi
  done

  # Stop Docker infra
  info "Stopping Docker containers..."
  docker compose -f docker-compose.infra.yml down 2>/dev/null || true
  log "All services stopped"
}

# ── Print status ─────────────────────────────────────────────────────────
print_status() {
  header "Service Status"
  echo -e "  ${BOLD}Service               Port    Status${NC}"
  echo -e "  ─────────────────────────────────────"

  for entry in "MongoDB:27017" "Kafka:29092" "Catalog:3001" "Order:3002" "Rating:3003" "Notification:3004" "API Gateway:3000" "UI (Vite):5173"; do
    local name="${entry%%:*}"
    local port="${entry##*:}"
    local pid=$(lsof -ti :"$port" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      echo -e "  ${name}$(printf '%*s' $((22 - ${#name})) '')${port}    ${GREEN}● Running${NC}"
    else
      echo -e "  ${name}$(printf '%*s' $((22 - ${#name})) '')${port}    ${RED}○ Stopped${NC}"
    fi
  done
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────
case "${1:-}" in
  --infra-only)
    start_infra
    ;;
  --stop)
    stop_all
    ;;
  --help|-h)
    usage
    ;;
  --all|"")
    start_infra
    start_services
    start_ui

    header "All Systems Ready"
    print_status

    echo -e "  ${BOLD}Quick Test:${NC}"
    echo -e "  ${CYAN}curl http://localhost:3000/health | jq${NC}"
    echo -e "  ${CYAN}open http://localhost:5173${NC}  (UI)"
    echo -e "  ${CYAN}open http://localhost:3000/api-docs${NC}  (Swagger)"
    echo ""
    echo -e "  ${BOLD}Logs:${NC}  /tmp/cake-*.log"
    echo -e "  ${BOLD}Stop:${NC}  ./start.sh --stop"
    echo ""
    ;;
  *)
    err "Unknown option: $1"
    usage
    exit 1
    ;;
esac
