#!/bin/bash

# Deployment script for Docker image for Telemt - a fast Rust-based MTProxy (MTProto) server
# telemt-from-image-mu.sh # enhanced 2026-09-08
# Changelog: multi-user, validated ad_tag, automatic 32-hex secrets, local API, safer deployment

# Exit if any command in a pipeline fails
set -o pipefail

# Check for root privileges
[ "$EUID" -ne 0 ] && { echo -e "[ERROR] Please run as root"; exit 1; }

# --- Docker images: --------------------------------------------
# 1 # Build https://github.com/telemt/telemt by whn0thacked = latest
IMAGE_NAME="whn0thacked/telemt-docker:latest" # https://github.com/An0nX/telemt-docker/blob/master/README.md
# 2 # Build https://github.com/telemt/telemt by whn0thacked = Copy at 2026-02
# IMAGE_NAME="exalon/telemt-docker:latest"  # https://hub.docker.com/repository/docker/exalon/telemt-docker/general

# External script
BUILD_SCRIPT_URL="https://raw.githubusercontent.com/nolaxe/install-MTProxy/main/telemt-from-source.sh"
SCRIPT_NAME=$(basename "$BUILD_SCRIPT_URL")

# Files
FILE_CONFIG_TELEMT="telemt.toml"; FILE_CONFIG_COMPOSE="docker-compose.yml"; FILE_PROXY_LINK_LIST="proxy_link.txt"

# random domain
VALUE_DEF_SITE=$(curl -s https://raw.githubusercontent.com/nolaxe/install-MTProxy/main/site.txt | shuf -n 1)
VALUE_DEF_SITE=${VALUE_DEF_SITE:-"google.com"}
VALUE_DEF_SITE="duckduckgo.com"

AD_TAG=""
AD_TAG_DISABLED="#"

# --- Default Telemt Conf ---
VALUE_DEF_MAX_USERS=16
VALUE_DEF_USER_COUNT=2
VALUE_DEF_VALUE_PORT="443"

# get ip
CUR_IP4=$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
CUR_IP4=${CUR_IP4:-"YOUR_IP"}

# Set protocol
PROTO_TLS="true"; PROTO_CLASSIC="false"; PROTO_SECURE="false"
# 1. TLS Mode: Uses "ee" prefix + secret + hex domain.       # link_tls     ="tg://proxy?server=$ip&port=$p&secret=ee${s}${domain_hex}"
# 2. Secure Mode: Uses "dd" prefix + secret.                 # link_secure  ="tg://proxy?server=$ip&port=$p&secret=dd${s}"
# 3. Classic Mode: Raw 32-char secret without any prefixes.  # link_classic ="tg://proxy?server=$ip&port=$p&secret=${s}"
MAIN_RAW_SECRET=""; MAIN_FULL_SECRET=""; ADDIT_RAW_SECRET=""; ADDIT_CONFIG=""; ADDIT_FULL_SECRET="";

# --- Default script conf ---
FAST_SETUP="false"
RENEW_SETTINGS=""
RENEW_SECRET=""

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Eye candy
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ACHTUNG]${NC} $*"; };  ask()   { echo -ne "${YELLOW}[?]${NC} $*"; }
# test_printout()   { echo -e "${CYAN}rem > $*${NC}"; }

test_print_all_values() {
    local vars=(
        "$PROTO_TLS        - $PROTO_SECURE - $PROTO_CLASSIC"
        "VALUE_DEF_VALUE_PORT        - $VALUE_DEF_VALUE_PORT"
        "VALUE_DEF_SITE        - $VALUE_DEF_SITE"
        "CUR_IP4           - $CUR_IP4"
        "MAIN_RAW_SECRET   - $MAIN_RAW_SECRET"
        "MAIN_FULL_SECRET  - $MAIN_FULL_SECRET"
        "ADDIT_RAW_SECRET  - $ADDIT_RAW_SECRET"
        "ADDIT_FULL_SECRET - $ADDIT_FULL_SECRET"
        "ADDIT_CONFIG      - $ADDIT_CONFIG"
    )
    for item in "${vars[@]}"; do echo -e "${CYAN}$item${NC}"; done
}

# Check if container is running
is_running() { [ "$(docker inspect -f '{{.State.Running}}' telemt 2>/dev/null)" == "true" ]; }

# Telemt secrets and @MTProxybot ad tags are 16 random bytes represented by
# exactly 32 hexadecimal characters. Try multiple local CSPRNG tools so a
# transient OpenSSL problem never creates an empty or malformed secret.
generate_secret() {
    local secret=""
    command -v openssl >/dev/null 2>&1 && secret=$(openssl rand -hex 16 2>/dev/null || true)
    if [[ ! "$secret" =~ ^[0-9a-fA-F]{32}$ ]]; then
        secret=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    fi
    [[ "$secret" =~ ^[0-9a-fA-F]{32}$ ]] || { err "Unable to generate a secure 32-character secret"; return 1; }
    printf '%s\n' "${secret,,}"
}

validate_ad_tag() { [[ -z "$1" || "$1" =~ ^[0-9a-fA-F]{32}$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
validate_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }

backup_configs() {
    local stamp backup_dir
    stamp=$(date +%Y%m%d-%H%M%S)
    backup_dir="backup-$stamp"
    if [ -f "$FILE_CONFIG_TELEMT" ] || [ -f "$FILE_CONFIG_COMPOSE" ] || [ -f "$FILE_PROXY_LINK_LIST" ]; then
        mkdir -p "$backup_dir"
        for file in "$FILE_CONFIG_TELEMT" "$FILE_CONFIG_COMPOSE" "$FILE_PROXY_LINK_LIST"; do
            [ -f "$file" ] && cp -a "$file" "$backup_dir/"
        done
        info "Existing files backed up to $backup_dir"
    fi
}

get_from_file_settings() {  # Extract port, domain
    if [ -f "$FILE_CONFIG_TELEMT" ]; then
        VALUE_DEF_VALUE_PORT=$(sed -n '/\[server\]/,/port =/p' "$FILE_CONFIG_TELEMT" | grep "^port =" | awk -F'=' '{print $2}' | tr -d '[:space:]"')
        VALUE_DEF_SITE=$(grep "tls_domain =" "$FILE_CONFIG_TELEMT" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "')
        AD_TAG=$(grep -E '^[[:space:]]*ad_tag[[:space:]]*=' "$FILE_CONFIG_TELEMT" | head -n 1 | cut -d'"' -f2)
        [ -n "$AD_TAG" ] && AD_TAG_DISABLED="" || AD_TAG_DISABLED="#"
        PROTO_CLASSIC=$(grep -E '^[[:space:]]*classic[[:space:]]*=' "$FILE_CONFIG_TELEMT" | head -n 1 | awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}')
        PROTO_SECURE=$(grep -E '^[[:space:]]*secure[[:space:]]*=' "$FILE_CONFIG_TELEMT" | head -n 1 | awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}')
        PROTO_TLS=$(grep -E '^[[:space:]]*tls[[:space:]]*=' "$FILE_CONFIG_TELEMT" | head -n 1 | awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}')
    fi
}
get_from_file_secrets() { # Extract secrets
    if [ -f "$FILE_CONFIG_TELEMT" ]; then
        MAIN_RAW_SECRET=$(grep "docker =" "$FILE_CONFIG_TELEMT" | awk -F'=' '{print $2}' | tr -d ' "')
        ADDIT_RAW_SECRET=$(sed -n '/docker =/,$p' "$FILE_CONFIG_TELEMT" | grep -v "docker =" | sed 's/^/\n/')
    fi
}

deploy_container() { # Pull image and (re)start the Docker container
    info "Pulling latest image..."
    docker compose pull || { warn "Failed to pull the Telemt image"; exit 1; }
    info "Applying configuration..."
    docker compose up -d --remove-orphans || { warn "Failed to deploy. Docker environment is not ready!"; exit 1; }
}

start_container() {
    info "Starting container..."
    docker compose up -d || { warn "Start failed!"; exit 1; } #  docker compose up -d --force-recreate || { err "Start failed!"; exit 1; }
}

del_config_files() {
    err "This will remove ALL telemt files (telemt.toml, docker-compose.yml, proxy_link.txt, .install_date, .dependencies_done)"
    read -p "[?] Are you sure? Press [ENTER] to confirm or type anything to cancel: " -r
    if [[ -z "$REPLY" ]]; then
        # Check if 'telemt' container exists and force remove it
        if [ "$(docker ps -aq -f name=telemt)" ]; then
            info "Stopping and removing container 'telemt'..."
            docker rm -f telemt >/dev/null 2>&1
        fi
        # Cleanup firewall rules before deleting the config file
        [ -f "$FILE_CONFIG_TELEMT" ] && {
            OLD_PORT=$(grep "port =" "$FILE_CONFIG_TELEMT" 2>/dev/null | awk -F'=' '{print $2}' | tr -d '[:space:]"')
            # Delete UFW rule if port is found and UFW is installed
            [ -n "$OLD_PORT" ] && command -v ufw >/dev/null && ufw delete allow "$OLD_PORT"/tcp || true
            }
        # Shutdown compose project and wipe images, volumes, and orphan containers
        [ -f "$FILE_CONFIG_COMPOSE" ] && { info "Cleaning Docker..."; docker compose down --rmi all --volumes --remove-orphans;}
        # Remove all configuration and hidden state files
        rm -f "$FILE_CONFIG_TELEMT" "$FILE_CONFIG_COMPOSE" "$FILE_PROXY_LINK_LIST" ".install_date" ".dependencies_done"
        info "Uninstall complete. System is clean."
    else
        info "Uninstall cancelled."
    fi
}

# Check and install Docker, Docker Compose, and dependencies
check_and_install() {

    if [ -f ".dependencies_done" ]; then
    info "Environment is already set up"; return 0
    fi
    # User confirmation to proceed or skip dependency check
    info "This script can check & install dependencies (Update, Docker, Compose, OpenSSL, lsof, jq, column)"
    ask "Press [ENTER] to check/install or ANY OTHER KEY to skip: "
    IFS= read -n 1 -s REPLY; echo ""
    [[ -n "$REPLY" ]] && { info "Dependency check skipped by user"; return 0; }
    # Synchronize package repositories
    echo -ne "[>] Updating package lists... "
    apt-get update -y >/dev/null 2>&1 && echo -e "${GREEN}Done${NC}" || echo -e "${RED}Failed${NC} (Check internet)"
    # Docker Engine check and automated installation
    echo -ne "[>] Checking Docker... "
    if command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN}Found${NC}"
    else
        echo -e "${YELLOW}Installing...${NC}"
        if curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
            systemctl enable --now docker >/dev/null 2>&1
        else
            warn "Failed to install Docker.";  exit 1
        fi
    fi
    # Docker Compose Plugin check (modern V2 version)
    echo -ne "[>] Checking Docker Compose... "
    if docker compose version >/dev/null 2>&1; then
        echo -e "${GREEN}Found${NC}"
    else
        echo -e "${YELLOW}Installing...${NC}"
        if apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
            echo -e "${GREEN}Done${NC}"
        else
            warn "Failed to install Docker Compose plugin."; exit 1
        fi
    fi
    # OpenSSL check for security and certificate operations
    echo -ne "[>] Checking OpenSSL... "
    if command -v openssl >/dev/null 2>&1; then
        echo -e "${GREEN}Found${NC}"
    else
        echo -e "${YELLOW}Installing...${NC}"
        if apt-get install -y openssl >/dev/null 2>&1; then
            echo -e "${GREEN}Done${NC}"
        else
            warn "Could not install OpenSSL. Check your package manager."; exit 1
        fi
    fi
    # LSOF check for port and process monitoring
    echo -ne "[>] Checking lsof... "
    if command -v lsof >/dev/null 2>&1; then
        echo -e "${GREEN}Found${NC}"
    else
        echo -e "${YELLOW}Installing...${NC}"
        if apt-get install -y lsof >/dev/null 2>&1; then
            echo -e "${GREEN}Done${NC}"
        else
            warn "Could not install lsof."; exit 1
        fi
    fi
    # Finalize installation and create a flag file
    if ! command -v jq >/dev/null 2>&1 || ! command -v column >/dev/null 2>&1; then
        echo -ne "[>] Installing statistics tools... "
        apt-get install -y jq bsdextrautils >/dev/null 2>&1 || apt-get install -y jq util-linux >/dev/null 2>&1 || {
            warn "Could not install jq/column; proxy will work but the statistics menu may be unavailable"
        }
        echo -e "${GREEN}Done${NC}"
    fi
    info "Environment is ready!"; touch .dependencies_done
}

select_protocol() {
    PROTO_TLS="false"; PROTO_SECURE="false"; PROTO_CLASSIC="false"
    echo -e "Select proxy protocol:"
    echo -e " 1) ${GREEN}TLS Mode${NC}"     #  (tls = true,  secure = false, classic = false)
    echo -e " 2) ${YELLOW}Secure Mode${NC}" #  (tls = false, secure = true,  classic = false)
    echo -e " 3) Classic Mode"              #  (tls = false, secure = false, classic = true )
    ask "Enter choice (default: 1) TLS): "
    read -r proto_choice
    case "$proto_choice" in
        2) PROTO_SECURE="true"; info "Selected: Secure Mode" ;;
        3) PROTO_CLASSIC="true"; info "Selected: Classic Mode" ;;
        1|*) PROTO_TLS="true"; info "Selected: TLS Mode (default)" ;;
    esac
}

write_file_config_telemt() { # telemt.toml
cat > "$FILE_CONFIG_TELEMT" <<EOF
[general]
fast_mode = true
${AD_TAG_DISABLED}ad_tag = "$AD_TAG"
use_middle_proxy = true
[general.modes]
classic = $PROTO_CLASSIC
secure = $PROTO_SECURE
tls = $PROTO_TLS
[general.links]
show = "*"
[server]
port = $VALUE_DEF_VALUE_PORT
listen_addr_ipv4 = "0.0.0.0"
listen_addr_ipv6 = "::"
[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
[[server.listeners]]
ip = "0.0.0.0"
[censorship]
tls_domain = "$VALUE_DEF_SITE"
mask = true
tls_emulation = true
[access.users]
docker = "$MAIN_RAW_SECRET"$ADDIT_CONFIG
EOF
echo -e "${GREEN}File $FILE_CONFIG_TELEMT has been updated.${NC}"
}

write_file_config_compose() { # docker-compose.yml
cat > "$FILE_CONFIG_COMPOSE" <<EOF
services:
  telemt:
    image: $IMAGE_NAME
    container_name: telemt
    restart: unless-stopped
    volumes:
      - ./$FILE_CONFIG_TELEMT:/etc/telemt.toml:ro
    network_mode: "host"
    init: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    security_opt:
     - no-new-privileges:true
    tmpfs:
      - /run/telemt:rw,nosuid,nodev,noexec,mode=1777,size=1m
      - /tmp:rw,nosuid,nodev,noexec,size=16m
      - /etc/telemt:rw,nosuid,nodev,noexec,size=1m
    deploy:
      resources:
        limits:
          memory: 128M
    pids_limit: 256
    ulimits:
       nofile:
         soft: 65536
         hard: 65536
    logging:
       driver: json-file
       options:
         max-size: "10m"
         max-file: "3"
EOF
echo -e "${GREEN}File $FILE_CONFIG_COMPOSE has been updated.${NC}"
}

show_stats() {
    local s
    s=$(curl -fsS --max-time 5 http://127.0.0.1:9091/v1/users) || {
        warn "Local Telemt API is unavailable; check: docker logs --tail 100 telemt"
        return 1
    }
    echo -e "${CYAN}USER  CONNS  TRAFFIC  RECENT_IPs${NC}"
    echo "$s" | jq -r '.data[] | "\(.username) \(.current_connections) \(.total_octets/1024|floor)KB \(.recent_unique_ips_list|join(","))"' | \
    column -t | GREP_COLORS="mt=${GREEN//[^0-9;]/}" grep --color=always -E "^[^ ]+[[:space:]]+[1-9][0-9]*.*$|$"
}

print_proxy_link() {
echo -e ""
    if [ -f "$FILE_CONFIG_TELEMT" ]; then
        get_from_file_settings
        get_from_file_secrets
        # Select prefix and suffix based on active mode
        [ "$PROTO_TLS" = "true" ] && { prefix="ee"; suffix=$(echo -n "$VALUE_DEF_SITE" | od -A n -t x1 | tr -d ' \n'); }
        [ "$PROTO_SECURE" = "true" ] && prefix="dd"
        [ "$PROTO_CLASSIC" = "true" ] && prefix=""
        # Main user (docker)
        local link="tg://proxy?server=$CUR_IP4&port=$VALUE_DEF_VALUE_PORT&secret=${prefix}${MAIN_RAW_SECRET}${suffix}"
        echo -e "\n Main user link"
        echo -e "Docker: ${GREEN}$link${NC}"
        echo "Default: $link" > "$FILE_PROXY_LINK_LIST" # в файл
        # Additional users. Locate the [access.users] section and process all lines containing '='
        local users_list
        users_list=$(sed -n '/\[access.users\]/,$p' "$FILE_CONFIG_TELEMT" | grep "=" | grep -v "docker =")
        if [[ -n "$users_list" ]]; then
            echo -e " Additional users "
            echo "$users_list" | while read -r line
                    do
                    local VALUE_USER_NAME u_secret
                    VALUE_USER_NAME=$(echo "$line" | cut -d'=' -f1 | tr -d ' ')
                    u_secret=$(echo "$line" | cut -d'"' -f2)
                    local u_link="tg://proxy?server=$CUR_IP4&port=$VALUE_DEF_VALUE_PORT&secret=${prefix}${u_secret}${suffix}"
                    echo -e "$VALUE_USER_NAME ${CYAN}$u_link${NC}"
                    echo "$VALUE_USER_NAME: $u_link" >> "$FILE_PROXY_LINK_LIST"
                    done
            echo -e " ... all links saved to $FILE_PROXY_LINK_LIST"
        else
            echo -e " There are no additional users"
        fi
        echo -e "Metrics: $CUR_IP4:9091/metrics"
        echo -e "-------------------------------------------------------"
    else
        echo -e " no links available "
    fi
}

gui_top() {
echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════╗"
echo "║              MTProxy (Telemt) Installer            ║"
echo "╚════════════════════════════════════════════════════╝"
echo -e "${NC}image name: $IMAGE_NAME"
}

get_status() {
# GUI # Config files [●] |  Active [●]
# GUI # 3) Turn OFF Proxy           (Status: active)
    # 1. Check if the compose configuration file exists and Docker is installed
    if [ -f "$FILE_CONFIG_COMPOSE" ] && command -v docker >/dev/null 2>&1; then
        INST_ICON="${GREEN}●${NC}"; local config_exists=true
    else
        INST_ICON="${YELLOW}○${NC}"
    fi
    # 2. Check if the container is running (Independent of config file check)
    if command -v docker >/dev/null 2>&1 && is_running; then
        ACT_ICON="${GREEN}●${NC}"
        STATUS_MSG="(Status: ${GREEN}active${NC})"
        TOGGLE_ACTION="Turn OFF Proxy   "
    else
        ACT_ICON="${YELLOW}○${NC}"
        if [ "$config_exists" = true ]; then
            STATUS_MSG="(Status: ${YELLOW}stopped${NC})"; TOGGLE_ACTION="Turn ON  Proxy   "
        else
            STATUS_MSG='(not available)'; TOGGLE_ACTION="Turn ON|OFF Proxy"
        fi
    fi
local inst_date; [ -f ".install_date" ] && inst_date="Last deploy date $(cat .install_date)"
GUI_INFO="\n CURRENT SERVER STATE:\nConfig files [${INST_ICON}] |  Active [${ACT_ICON}]\n$inst_date"
}

gui_main_menu() {
    echo -e "$GUI_INFO"
    #[ -n "$EXISTING_LINK" ] && echo -e "$EXISTING_LINK"
    print_proxy_link
     echo -e "\n\nSelect action:\n"
    echo -e " 1) ${CYAN}Custom Install${NC}           (Custom Port, Domain ...)${NC}"
    echo -e " 2) Fast Install             (Port: $VALUE_DEF_VALUE_PORT, Domain: $VALUE_DEF_SITE)"
    echo -e " 3) ${YELLOW}${TOGGLE_ACTION}${NC}        $STATUS_MSG"
    echo -e " 5) ${GREEN}Update Image${NC}             (Pull latest & Restart)"
    echo -e " 7) Show stats               (curl -s http://127.0.0.1:9091/v1/users)${NC}"
    # echo -e " 99) Run external script"
    echo -e " 0) ${RED}Full Uninstall${NC}           (Stop & Remove All)\n"
    echo -e ""; ask "Choose option: "; read -r INSTALL_MODE
}

# START
clear; get_status; gui_top; gui_main_menu

case $INSTALL_MODE in
    1)
        check_and_install && info "Mode: Custom Install"
        FAST_SETUP="false" ;;
    2)
        check_and_install && info "Mode: Fast Install\n"
        FAST_SETUP="true" ;;
    3)
        if [ -f "$FILE_CONFIG_COMPOSE" ]; then
            if is_running; then
                info "Stopping container..."; docker compose stop && info "Stopped."; exit 0
            else
                start_container; exit 0
            fi
        else
            warn "Proxy is not installed yet"
        fi ;;
    5)
        info "Updating Telemt image..."
        if [ -f "$FILE_CONFIG_COMPOSE" ]; then
            docker compose pull && docker compose up -d --remove-orphans
            info "Update complete. Running latest version."
        else
            warn "Configuration not found. Install proxy first."
        fi
        exit 0 ;;
    7)
        show_stats; exit 0 ;;
    0)
        del_config_files; exit 0 ;;

    99)
        info "Fetching build script..."
        curl -sLO "$BUILD_SCRIPT_URL" || { warn "Failed to download script."; exit 1; }
        chmod +x "./$SCRIPT_NAME" && exec "./$SCRIPT_NAME" ;;
    88)
        test_print_all_values; exit 0 ;;
    *) warn "Invalid option."; exit 1 ;;
esac

# If configuration file telemt.toml already exists
if [ -f "$FILE_CONFIG_TELEMT" ]; then
            if [ "$FAST_SETUP" = false ]; then
                # Menu 2
                echo "═══════════════════════════════════════════════════════════════"
                echo -e "\n${YELLOW}[!] Existing configuration found${NC}"
                echo -e "  1) Keep ALL (update container)     →  Settings ${GREEN}●${NC}  |  Secret ${GREEN}●${NC}"
                #echo -e "  2) Change settings, keep secret    →  Settings ${RED}X${NC}  |  Secret ${GREEN}●${NC}"
                echo -e "  0) Full RESET                      →  Settings ${RED}X${NC}  |  Secret ${RED}X${NC}"
                ask "Choose option [1-3]: "
                read -r INSTALL_MODE_2
                case "${INSTALL_MODE_2}" in
                    #2) for what?
                    #    # Settings X  |  Secret ●
                    #    RENEW_SETTINGS=true
                    #    info "Reset settings"
                    ##    ;;
                    0)
                        # Settings X  |  Secret X
                        RENEW_SETTINGS=true; RENEW_SECRET=true
                        warn "Full reset: new secret will be generated"
                        ;;

                    1|*)
                        # Settings ●  |  Secret ●
                        info "Keep settings"
                        ;;
                esac
            else
                EXISTING_FILES=$(for f in "$FILE_CONFIG_TELEMT" "$FILE_CONFIG_COMPOSE" "$FILE_PROXY_LINK_LIST"; do [ -f "$f" ] && echo -n "$f "; done)
                warn "Existing configuration found > $EXISTING_FILES"
                warn "Please run Full Uninstall first (4)"
                exit
            fi
else
    # If file doesn't exist - clean install
    RENEW_SETTINGS=true; RENEW_SECRET=true
fi

# Генерация токенов
if [ "$RENEW_SECRET" = true ]; then
    # Main token
    MAIN_RAW_SECRET=$(generate_secret) || exit 1
    info "Generated a secure 32-character MAIN secret"
    # Additional users
    read -p "[?] How many additional users to add? <$VALUE_DEF_MAX_USERS (default $VALUE_DEF_USER_COUNT): " value_user_input
    value_user_input=${value_user_input:-$VALUE_DEF_USER_COUNT}
    if [[ ! "$value_user_input" =~ ^[0-9]+$ ]]; then
        warn "Invalid user count; using default $VALUE_DEF_USER_COUNT"
        value_user_input=$VALUE_DEF_USER_COUNT
    fi
    if (( value_user_input > $VALUE_DEF_MAX_USERS )); then
        value_user_input=$VALUE_DEF_MAX_USERS
        echo -e "${YELLOW}[!] Limited to $VALUE_DEF_MAX_USERS users.${NC}"
    fi
    for (( i=1; i<=value_user_input; i++ )); do
        # ask "[!] If you just press Enter, the name will be Bastard$i\n"
        ask "Enter name for user №$i (letters, digits, _ or -, default user$i): "; read -r VALUE_USER_NAME
        VALUE_USER_NAME=${VALUE_USER_NAME:-user$i}
        if [[ ! "$VALUE_USER_NAME" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
            warn "Invalid name; using user$i"
            VALUE_USER_NAME="user$i"
        fi
        NEW_SECRET=$(generate_secret) || exit 1
        info "Added $VALUE_USER_NAME with an automatic 32-character secret"
        ADDIT_CONFIG+=$'\n'"$VALUE_USER_NAME = \"$NEW_SECRET\""
    done
    [[ -n "$ADDIT_CONFIG" ]] && echo -e " Additional user list\n$ADDIT_CONFIG"
else
    # Extract existing users
    get_from_file_secrets
fi

if [ "$RENEW_SETTINGS" = true ]; then

            # Port # Start a loop to ensure the selected port is actually available            
            while true; do
                ask "Enter port (default $VALUE_DEF_VALUE_PORT): "; read -r input_port
                VALUE_DEF_VALUE_PORT=${input_port:-$VALUE_DEF_VALUE_PORT}
                if ! validate_port "$VALUE_DEF_VALUE_PORT"; then
                    warn "Port must be an integer from 1 to 65535"
                    continue
                fi
                # Check if port is privileged (<1024) and script is NOT running as root
                if [[ "$VALUE_DEF_VALUE_PORT" -lt 1024 ]]; then
                    warn "Port $VALUE_DEF_VALUE_PORT is privileged (needs root). Might not be able to verify if occupied."
                    # echo -e "${YELLOW}  Please check manually or use port > 1024${NC}"
                    # continue
                fi
                # Occupancy check. If lsof finds a process, it returns 0 (true) and enters the warning block
                if sudo lsof -i :"$VALUE_DEF_VALUE_PORT" -sTCP:LISTEN -t >/dev/null ; then
                    warn "Port $VALUE_DEF_VALUE_PORT is already occupied!"
                    sudo lsof -i :"$VALUE_DEF_VALUE_PORT" -sTCP:LISTEN
                    echo -e "${YELLOW}Please choose a different port or stop the service above OR Turn OFF current Proxy ${NC}"
                else
                    info "Port $VALUE_DEF_VALUE_PORT is available."
                    break # PORT IS FREE - exit the loop
                fi
            done
            
            while true; do
                ask "Enter TLS camouflage domain (default $VALUE_DEF_SITE): "; read -r input_site
                VALUE_DEF_SITE=${input_site:-$VALUE_DEF_SITE}
                validate_domain "$VALUE_DEF_SITE" && break
                warn "Enter a hostname such as www.cloudflare.com, without https:// or a path"
            done
            # Display connection details for the user before Ad_tag prompt
            echo -e "\n${CYAN}- To set up an Ad Tag, provide the settings above to @MTProxybot - ${NC}"
            echo -e "host:port: ${GREEN}$CUR_IP4:$VALUE_DEF_VALUE_PORT${NC}"
            echo -e "Secret:  ${GREEN}$MAIN_RAW_SECRET${NC}"
            echo -e "${CYAN}--------------------------------${NC}"
            while true; do
                ask "Enter the 32-hex ad_tag from @MTProxybot (ENTER disables it): "; read -r input_tag
                input_tag=${input_tag,,}
                if validate_ad_tag "$input_tag"; then break; fi
                warn "ad_tag must contain exactly 32 hexadecimal characters"
            done
            AD_TAG="$input_tag"
            if [[ -z "$AD_TAG" ]]; then
                AD_TAG_DISABLED="#"; warn "Ad tag is disabled"
            else
                AD_TAG_DISABLED=""; info "Ad tag enabled"
            fi
            # Select protocol
            select_protocol
    else
    get_from_file_settings
fi

# Open port in firewall
if command -v ufw >/dev/null && ufw status | grep -q "active"; then
    info "Opening port $VALUE_DEF_VALUE_PORT..."
    ufw allow "$VALUE_DEF_VALUE_PORT"/tcp
fi

# Make a files
if [[ "$RENEW_SECRET" == "true" || "$RENEW_SETTINGS" == "true" ]]; then
    backup_configs
    write_file_config_telemt
    write_file_config_compose
elif [ ! -f "$FILE_CONFIG_COMPOSE" ]; then
    write_file_config_compose
fi

info "Config ready: $FILE_CONFIG_COMPOSE, $FILE_CONFIG_TELEMT"
[ ! -f ".install_date" ] && date +"%Y-%m-%d" > .install_date

deploy_container && { info "🎉 Proxy is ready to use!"; }
print_proxy_link
#mn#
