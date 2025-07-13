#!/usr/bin/env bash
set -euo pipefail

# ---- Colours -------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ---- Config --------------------------------------------------------------
CONFIG_DIR="$HOME/.cloudflared"
CONFIG_FILE="$CONFIG_DIR/tunnel-config.json"
HISTORY_FILE="$CONFIG_DIR/tunnel-history.json"
SCRIPT_NAME=$(basename "$0")

# ---- Helper --------------------------------------------------------------
print_banner() {
  echo -e "${BLUE}╔═════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  Cloudflare Tunnel Pipe  v1.0        ║${NC}"
  echo -e "${BLUE}╚═════════════════════════════════════════╝${NC}"
}
print_error()   { echo -e "${RED}❌ ERROR: $1${NC}" >&2; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_info()    { echo -e "${CYAN}ℹ️  $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

check_requirements() {
  for cmd in cloudflared jq curl openssl; do
    command -v "$cmd" >/dev/null || {
      print_error "Missing: $cmd"; exit 1
    }
  done
}

# ---- API token helpers ------------------------------------------------------
get_api_token() {
  [[ -z ${CF_API_TOKEN:-} ]] && { print_error "Set CF_API_TOKEN env var or export it"; exit 1; }
  echo "$CF_API_TOKEN"
}

# ---- Generate unique ID ------------------------------------------------------
generate_unique_id() {
  local prefix="${1:-slug}"
  local ts=$(date +%H%M%S)
  local rnd=$(openssl rand -hex 3 2>/dev/null || printf '%05d' "$RANDOM")
  echo "${prefix}-${ts}-${rnd}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}

# ---- Port list ------------------------------------------------------------
detect_port() {
  local ports=(
    3000 3001 3002 3003 8000 8080 5000
    5173 5174 4321 4322 24678 4173 6006 7000 9000 9001
  )
  for p in "${ports[@]}"; do
    lsof -i:"$p" -sTCP:LISTEN -t >/dev/null 2>&1 && { echo "$p"; return; }
  done
  echo 3000
}

# ---- Save to history ------------------------------------------------------------
save_to_history() {
    local hostname="$1"
    local port="$2"
    local project="$3"
    local directory="$4"

    # Build one JSON object
    local entry
    entry=$(jq -n \
        --arg dir  "$directory" \
        --arg proj "$project" \
        --arg host "$hostname" \
        --arg port "$port" \
        --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{directory:$dir, project:$proj, hostname:$host, port:$port, timestamp:$time}')

    # Create or append atomically
    if [[ -s "$HISTORY_FILE" ]]; then
        jq --argjson entry "$entry" \
           '. + [$entry] | .[-100:]' \
           "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" \
        && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    else
        jq --argjson entry "$entry" -n '[ $entry ]' > "$HISTORY_FILE"
    fi
}

# ---- Setup ---------------------------------------------------------------
setup_tunnel() {
  check_requirements
  print_banner; echo -e "\n${CYAN}Initial Setup${NC}\n"
  api_token=$(get_api_token)
  [[ -z ${api_token// } ]] && { print_error "API token missing or empty"; exit 1; }

  account_id=""
  [[ -n ${CF_ACCOUNT_ID:-} ]] && account_id="$CF_ACCOUNT_ID" || read -r -p "Account ID: " account_id

  zones_resp=$(curl -sS -H "Authorization: Bearer $api_token" \
    "https://api.cloudflare.com/client/v4/zones?status=active")
  zones=()
  while IFS= read -r z; do [[ -n $z ]] && zones+=("$z"); done \
    < <(echo "$zones_resp" | jq -r '.result[]?.name // empty' | sort)
  [[ ${#zones[@]} -eq 0 ]] && { print_error "No zones or invalid token"; exit 1; }

  echo -e "\nDomains:"
  printf '%s\n' "${zones[@]}" | nl -w2 -s'. '
  read -r -p "Select domain number: " idx
  root_domain=${zones[$((idx-1))]}
  zone_id=$(echo "$zones_resp" | jq -r --arg d "$root_domain" '.result[] | select(.name==$d) | .id')

  # Create tunnel
  t_name="cftpipe-$(date +%s)"
  t_resp=$(curl -sS -X POST \
    "https://api.cloudflare.com/client/v4/accounts/$account_id/cfd_tunnel" \
    -H "Authorization: Bearer $api_token" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$t_name\",\"config_src\":\"cloudflare\"}")
  t_id=$(echo "$t_resp" | jq -r '.result.id')
  t_token=$(echo "$t_resp" | jq -r '.result.token')

  mkdir -p "$CONFIG_DIR"
  jq -n \
    --arg d "$root_domain" --arg z "$zone_id" \
    --arg tid "$t_id" --arg tname "$t_name" --arg ttoken "$t_token" \
    '{
      domain: $d, zone_id: $z,
      tunnel_id: $tid, tunnel_name: $tname, token: $ttoken,
      created_at: now
    }' > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"

  # history (safe append)
  dir=$(pwd)
  proj=$(basename "$dir")
  slug="setup"
  hostname="${slug}.${root_domain}"
  port="N/A"

  save_to_history "$hostname" "$port" "$proj" "$dir"

  print_success "Setup complete. Run: $SCRIPT_NAME run"
}

# ---- Run -----------------------------------------------------------------
run_tunnel() {
  check_requirements
  [[ ! -f $CONFIG_FILE ]] && { print_error "Run setup first"; exit 1; }

  port=""
  slug=""
  reuse=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p|--port) port=$2; shift 2 ;;
      -s|--name) slug=$2; shift 2 ;;
      -r|--reuse) reuse=true; shift ;;
      *[0-9]*) port=$1; shift ;;
      *) shift ;;
    esac
  done

  root=$(jq -r '.domain' "$CONFIG_FILE")
  token=$(jq -r '.token' "$CONFIG_FILE")
  zone_id=$(jq -r '.zone_id' "$CONFIG_FILE")
  tunnel_id=$(jq -r '.tunnel_id' "$CONFIG_FILE")

  dir=$(pwd)
  proj=$(basename "$dir")

  [[ -z $port ]] && port=$(detect_port)
  [[ -z $slug ]] && slug=$(generate_unique_id "$proj")

  if [[ $reuse == true && -s "$HISTORY_FILE" ]]; then
    slug=$(jq -r --arg d "$dir" \
            '[ .[] | select(.directory==$d) | .hostname ][-1] // empty' \
            "$HISTORY_FILE" | cut -d. -f1)
  fi
  [[ -z $slug ]] && slug=$(generate_unique_id "$proj")

  hostname="${slug}.${root}"

  # Ensure per-slug CNAME
  api_token=$(get_api_token)
  [[ -z ${api_token// } ]] && { print_error "API token missing or empty"; exit 1; }

  exists=$(curl -sS -H "Authorization: Bearer $api_token" \
    "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=CNAME&name=$hostname" \
    | jq -r '.result | length')
  if [[ $exists -eq 0 ]]; then
    print_info "Creating CNAME $hostname → $tunnel_id.cfargotunnel.com"
    curl -sS -X POST \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
      -H "Authorization: Bearer $api_token" \
      -H "Content-Type: application/json" \
      -d "{
        \"type\":\"CNAME\",
        \"name\":\"$hostname\",
        \"content\":\"$tunnel_id.cfargotunnel.com\",
        \"proxied\":true
      }" >/dev/null
  else
    print_info "CNAME already exists"
  fi

  # history (safe append)
  save_to_history "$hostname" "$port" "$proj" "$dir"

  # sanity-check variables
  [[ -z $token ]] && { print_error "No tunnel token in config"; exit 1; }
  [[ -z $port  ]] && { print_error "Port not specified/detected"; exit 1; }

  echo -e "${CYAN}↪  Starting cloudflared …${NC}"
  cloudflared tunnel run \
    --token "$token" \
    --url   "http://localhost:$port"
}

# ---- Destroy --------------------------------------------------------------
destroy_tunnel() {
  check_requirements
  [[ ! -f $CONFIG_FILE ]] && { print_error "Run setup first"; exit 1; }
  [[ $# -eq 0 ]] && { print_error "Usage: $SCRIPT_NAME destroy <slug>"; exit 1; }

  slug=$1
  root=$(jq -r '.domain // empty' "$CONFIG_FILE")
  zone_id=$(jq -r '.zone_id // empty' "$CONFIG_FILE")
  tunnel_id=$(jq -r '.tunnel_id // empty' "$CONFIG_FILE")
  [[ -z $root || -z $zone_id ]] && { print_error "Config broken"; exit 1; }

  hostname="${slug}.${root}"

  api_token=$(get_api_token)
  [[ -z ${api_token// } ]] && { print_error "API token missing or empty"; exit 1; }

  rec_id=$(curl -sS -H "Authorization: Bearer $api_token" \
    "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=CNAME&name=$hostname" \
    | jq -r '.result[0].id // empty')
  if [[ -n $rec_id ]]; then
    curl -sS -X DELETE \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$rec_id" \
      -H "Authorization: Bearer $api_token" >/dev/null
    print_success "Deleted CNAME $hostname"
  else
    print_warning "CNAME not found"
  fi

  read -r -p "Delete tunnel $tunnel_id too? (y/N): " del
  if [[ $del =~ ^[Yy]$ ]]; then
    account_id=$(curl -sS -H "Authorization: Bearer $api_token" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id" | jq -r '.result.account.id')
    curl -sS -X DELETE \
      "https://api.cloudflare.com/client/v4/accounts/$account_id/cfd_tunnel/$tunnel_id" \
      -H "Authorization: Bearer $api_token" >/dev/null
    print_success "Deleted tunnel $tunnel_id"
  fi
}

# ---- Main ----------------------------------------------------------------
main() {
  check_requirements
  cmd=${1:-run}; shift || true
  case $cmd in
    setup) setup_tunnel ;;
    run) run_tunnel "$@" ;;
    destroy) destroy_tunnel "$@" ;;
    list) [[ -f $HISTORY_FILE ]] && \
      jq -r '.[-20:][] | "\(.timestamp) | \(.project) | https://\(.hostname) | port \(.port)"' "$HISTORY_FILE" \
      2>/dev/null || echo "No history" ;;
    status) [[ -f $CONFIG_FILE ]] && jq -r . "$CONFIG_FILE" || echo "No config" ;;
    help|-h|--help) echo "Usage: $SCRIPT_NAME {setup|run|destroy <slug>|list|status}" ;;
    *) print_error "Unknown command '$cmd'"; exit 1 ;;
  esac
}

main "$@"
