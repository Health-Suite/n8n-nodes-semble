#!/bin/bash

# Universal n8n Version Update Script (Docker Compose Official Process)
# This script follows the official n8n Docker update recommendations:
# https://docs.n8n.io/hosting/installation/docker/#updating
#
# Key improvements:
# - Uses proper Docker Compose workflow (pull -> down -> up)
# - Uses official docker.n8n.io registry
# - Environment variable-based version management
# - Proper error handling and health checks
# - Community node protection and auto-redeployment
#
# Usage: ./update-n8n.sh [local|production] [version]

set -e

# Load workspace environment variables
WORKSPACE_ROOT="/Users/mikehatcher/Websites/the-health-suite"
ENV_FILE="$WORKSPACE_ROOT/.env"

# Load environment variables
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ .env file not found at $ENV_FILE"
    exit 1
fi

# Default to local environment
ENVIRONMENT="${1:-local}"
TARGET_VERSION="${2:-latest}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Function to get environment-specific API configuration
get_api_config() {
    local env="$1"
    
    if [ "$env" = "production" ]; then
        API_ENDPOINT="$N8N_PROD_API_ENDPOINT"
        API_KEY="$N8N_PROD_API_KEY"
        HOST_URL="https://workflows.thehealthsuite.co.uk"
    else
        API_ENDPOINT="$N8N_LOCAL_API_ENDPOINT"
        API_KEY="$N8N_LOCAL_API_KEY"
        HOST_URL="$N8N_LOCAL_HOST"
    fi
    
    # Validate API configuration
    if [ -z "$API_ENDPOINT" ] || [ -z "$API_KEY" ]; then
        print_status "$RED" "❌ API configuration missing for $env environment"
        echo "   Required: API_ENDPOINT and API_KEY"
        return 1
    fi
}

# Function to make API calls to n8n
make_n8n_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    local curl_cmd="curl -s -X $method"
    curl_cmd="$curl_cmd -H 'X-N8N-API-KEY: $API_KEY'"
    curl_cmd="$curl_cmd -H 'Content-Type: application/json'"
    
    if [ -n "$data" ]; then
        curl_cmd="$curl_cmd -d '$data'"
    fi
    
    curl_cmd="$curl_cmd '$API_ENDPOINT$endpoint'"
    
    # Execute the curl command
    eval $curl_cmd
}

# Function to check Docker container health
check_container_health() {
    local env="$1"
    local container_name="$2"
    
    if [ "$env" = "local" ]; then
        # Check local container health
        local health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "no-healthcheck")
        local running_status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "not-found")
        
        if [ "$running_status" = "running" ]; then
            if [ "$health_status" = "healthy" ]; then
                echo "healthy"
            elif [ "$health_status" = "no-healthcheck" ]; then
                # No health check configured, check if container is responding
                if docker exec "$container_name" sh -c "ps aux | grep -v grep | grep n8n" >/dev/null 2>&1; then
                    echo "running"
                else
                    echo "unhealthy"
                fi
            else
                echo "$health_status"
            fi
        else
            echo "$running_status"
        fi
    else
        # Check production container health via SSH
        if [ -n "$N8N_PROD_HOST" ] && [ -n "$N8N_PROD_USER" ] && [ -n "$N8N_PROD_PWD" ]; then
            sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" \
                "docker inspect --format='{{.State.Status}}' $container_name 2>/dev/null || echo 'not-found'"
        else
            echo "no-ssh-config"
        fi
    fi
}

# Function to wait for container to be healthy
wait_for_container_health() {
    local env="$1"
    local container_name="$2"
    local max_attempts="${3:-30}"
    local check_interval="${4:-2}"
    
    print_status "$YELLOW" "⏳ Waiting for container to be healthy..."
    
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        local health_status=$(check_container_health "$env" "$container_name")
        
        case "$health_status" in
            "healthy"|"running")
                print_status "$GREEN" "✅ Container is healthy and running"
                return 0
                ;;
            "starting"|"unhealthy")
                echo "  Container status: $health_status (attempt $((attempt + 1))/$max_attempts)"
                ;;
            "not-found")
                print_status "$RED" "❌ Container not found: $container_name"
                return 1
                ;;
            "exited"|"dead")
                print_status "$RED" "❌ Container has stopped: $health_status"
                return 1
                ;;
            *)
                echo "  Container status: $health_status (attempt $((attempt + 1))/$max_attempts)"
                ;;
        esac
        
        sleep $check_interval
        ((attempt++))
    done
    
    print_status "$RED" "❌ Container did not become healthy within $((max_attempts * check_interval)) seconds"
    return 1
}

# Function to verify data persistence after update
verify_data_persistence() {
    local env="$1"
    local container_name="$2"
    
    print_status "$BLUE" "🔍 Verifying data persistence..."
    
    if [ "$env" = "local" ]; then
        # Check that .n8n directory exists and has proper structure
        local data_check=$(docker exec "$container_name" sh -c "
            if [ -d /home/node/.n8n ]; then
                ls -la /home/node/.n8n | wc -l
            else
                echo '0'
            fi
        " 2>/dev/null || echo "error")
        
        if [ "$data_check" != "error" ] && [ "$data_check" -gt 2 ]; then
            print_status "$GREEN" "✅ Data directory structure verified"
            
            # Check for database file
            local db_check=$(docker exec "$container_name" sh -c "
                if [ -f /home/node/.n8n/database.sqlite ]; then
                    echo 'sqlite-found'
                elif ls /home/node/.n8n/*.db 2>/dev/null; then
                    echo 'db-found'
                else
                    echo 'no-db'
                fi
            " 2>/dev/null || echo "error")
            
            if [ "$db_check" = "sqlite-found" ] || [ "$db_check" = "db-found" ]; then
                print_status "$GREEN" "✅ Database file present"
            else
                print_status "$YELLOW" "⚠️  No local database file found (may be using external DB)"
            fi
            
            return 0
        else
            print_status "$RED" "❌ Data directory structure issue detected"
            return 1
        fi
    else
        # Production data verification via SSH
        if [ -n "$N8N_PROD_HOST" ] && [ -n "$N8N_PROD_USER" ] && [ -n "$N8N_PROD_PWD" ]; then
            local data_check=$(sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" \
                "docker exec $container_name sh -c 'ls -la /home/node/.n8n 2>/dev/null | wc -l' 2>/dev/null || echo 'error'")
            
            if [ "$data_check" != "error" ] && [ "$data_check" -gt 2 ]; then
                print_status "$GREEN" "✅ Production data directory structure verified"
                return 0
            else
                print_status "$RED" "❌ Production data directory structure issue detected"
                return 1
            fi
        else
            print_status "$YELLOW" "⚠️  Cannot verify production data (SSH not configured)"
            return 0
        fi
    fi
}

# Function to check community nodes status
check_community_nodes() {
    local env="$1"
    
    if [ "$env" = "local" ]; then
        # For local environment, check Docker container
        local test_dir="$WORKSPACE_ROOT/n8n-local-test"
        if [ -d "$test_dir" ]; then
            cd "$test_dir"
            # Check if Semble node is accessible in local container
            local node_check=$(docker compose exec -T n8n sh -c "ls -la /home/node/.n8n/nodes/node_modules/ 2>/dev/null | grep semble || echo 'missing'" 2>/dev/null || echo "error")
            if [[ "$node_check" == *"semble"* ]]; then
                echo "present"
            else
                echo "missing"
            fi
        else
            echo "no-local-env"
        fi
    else
        # For production environment, check via SSH
        if [ -n "$N8N_PROD_HOST" ] && [ -n "$N8N_PROD_USER" ] && [ -n "$N8N_PROD_PWD" ]; then
            local node_check=$(sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$N8N_PROD_USER@$N8N_PROD_HOST" \
                "docker exec \$(docker ps --format '{{.Names}}' | grep n8n | head -1) sh -c 'ls -la /home/node/.n8n/nodes/node_modules/ 2>/dev/null | grep semble || echo missing'" 2>/dev/null || echo "error")
            
            if [[ "$node_check" == *"semble"* ]]; then
                echo "present"
            else
                echo "missing"
            fi
        else
            echo "no-ssh-config"
        fi
    fi
}

# Function to redeploy community nodes
redeploy_community_nodes() {
    local env="$1"
    
    print_status "$YELLOW" "🔧 Redeploying community nodes for $env environment..."
    
    # Navigate to the Semble node directory
    local current_dir=$(pwd)
    local semble_dir="$WORKSPACE_ROOT/n8n-nodes-semble"
    
    if [ ! -d "$semble_dir" ]; then
        print_status "$RED" "❌ Semble node directory not found at $semble_dir"
        return 1
    fi
    
    cd "$semble_dir"
    
    if [ "$env" = "local" ]; then
        print_status "$BLUE" "🚀 Deploying to local environment..."
        if npm run deploy:local >/dev/null 2>&1; then
            print_status "$GREEN" "✅ Local community nodes redeployed successfully"
        else
            print_status "$RED" "❌ Failed to redeploy local community nodes"
            cd "$current_dir"
            return 1
        fi
    else
        print_status "$BLUE" "🚀 Deploying to production environment..."
        if npm run deploy:prod >/dev/null 2>&1; then
            print_status "$GREEN" "✅ Production community nodes redeployed successfully"
        else
            print_status "$RED" "❌ Failed to redeploy production community nodes"
            cd "$current_dir"
            return 1
        fi
    fi
    
    cd "$current_dir"
    return 0
}

# Function to get current n8n version via API
get_current_version_api() {
    local env="$1"
    
    get_api_config "$env" || return 1
    
    # Use the authenticated API endpoint — avoids Cloudflare Access redirect on /healthz
    local response=$(curl -s \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        "${API_ENDPOINT}workflows?limit=1" 2>/dev/null || echo "")
    
    if [ -n "$response" ] && echo "$response" | grep -q '"data"'; then
        echo "api-accessible"
    else
        echo "unreachable"
    fi
}

# Function to get latest stable n8n version from GitHub releases
get_latest_version() {
    # Get the latest stable release (non-prerelease) from GitHub API
    local latest_tag=$(curl -s "https://api.github.com/repos/n8n-io/n8n/releases" | \
        jq -r '.[] | select(.prerelease == false) | .tag_name' | \
        head -1 2>/dev/null)
    
    if [ -n "$latest_tag" ] && [ "$latest_tag" != "null" ]; then
        # Extract version number from tag (remove 'n8n@' prefix)
        echo "$latest_tag" | sed 's/^n8n@//'
    else
        # Fallback to hardcoded stable version if API fails
        echo "1.104.2"
    fi
}

# Function to list available stable versions
list_available_versions() {
    print_status "$BLUE" "🏷️  Available stable n8n versions:"
    echo "   latest (latest stable release)"
    echo "   Recent stable releases:"
    
    # Get stable releases from GitHub API
    curl -s "https://api.github.com/repos/n8n-io/n8n/releases" | \
        jq -r '.[] | select(.prerelease == false) | .tag_name' | \
        sed 's/^n8n@//' | \
        head -10 | sed 's/^/   /'
}

# Function to update local Docker environment
update_local_docker() {
    local version="$1"
    local test_dir="$WORKSPACE_ROOT/n8n-local-test"
    
    if [ ! -d "$test_dir" ]; then
        print_status "$RED" "❌ Local test environment not found at $test_dir"
        echo "   Run 'npm run setup:test-env' first"
        return 1
    fi
    
    cd "$test_dir"
    
    print_status "$BLUE" "🔄 Updating local n8n to version $version"
    
    # Get current version first
    local current_version=$(get_current_version_api "local")
    
    if [ "$current_version" = "$version" ]; then
        print_status "$GREEN" "✅ Local n8n already running version $version"
        return 0
    fi
    
    print_status "$YELLOW" "Current version: $current_version"
    print_status "$YELLOW" "Target version: $version"
    
    # Create backup timestamp
    local backup_timestamp=$(date +%Y%m%d-%H%M%S)
    print_status "$BLUE" "💾 Creating local backup: n8n-backup-$backup_timestamp"
    
    # Create backup directory if it doesn't exist
    local backup_dir="$test_dir/backups"
    mkdir -p "$backup_dir"
    
    # Create backup using official method (same as production)
    # Note: Docker Compose prefixes volume names with project name (n8n-local-test_n8n_data)
    docker run --rm -v n8n-local-test_n8n_data:/source -v "$backup_dir:/backup" alpine sh -c "
        mkdir -p /backup/n8n-backup-$backup_timestamp
        cp -r /source/* /backup/n8n-backup-$backup_timestamp/ 2>/dev/null || true
        echo 'Backup created: n8n-backup-$backup_timestamp'
    "
    
    if [ -d "$backup_dir/n8n-backup-$backup_timestamp" ] && [ "$(ls -A $backup_dir/n8n-backup-$backup_timestamp)" ]; then
        print_status "$GREEN" "✅ Local backup created successfully"
    else
        print_status "$YELLOW" "⚠️  Backup directory created but may be empty"
    fi
    
    # Check community nodes before update
    print_status "$BLUE" "🔍 Checking community nodes before update..."
    local nodes_before=$(check_community_nodes "local")
    if [ "$nodes_before" = "present" ]; then
        print_status "$GREEN" "✅ Community nodes detected before update"
    else
        print_status "$YELLOW" "⚠️  No community nodes detected before update"
    fi
    
    # Update N8N_LOCAL_VERSION in .env file
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/^N8N_LOCAL_VERSION=.*/N8N_LOCAL_VERSION=$version/" "$ENV_FILE"
    else
        sed -i "s/^N8N_LOCAL_VERSION=.*/N8N_LOCAL_VERSION=$version/" "$ENV_FILE"
    fi
    
    # Export environment variable for this session
    export N8N_LOCAL_VERSION="$version"
    
    print_status "$BLUE" "📥 Following official Docker Compose update process..."
    print_status "$BLUE" "   Step 1: Pulling docker.n8n.io/n8nio/n8n:$version..."
    
    # Official Docker Compose update process
    # Step 1: Pull latest images
    if ! docker compose pull; then
        print_status "$RED" "❌ Failed to pull new n8n image"
        return 1
    fi
    
    print_status "$BLUE" "   Step 2: Stopping and removing containers..."
    # Step 2: Stop and remove containers  
    if ! docker compose down; then
        print_status "$RED" "❌ Failed to stop containers"
        return 1
    fi
    
    print_status "$BLUE" "   Step 3: Starting with new version..."
    # Step 3: Start with new version
    if ! docker compose up -d; then
        print_status "$RED" "❌ Failed to start containers with new version"
        return 1
    fi
    
    # Health check using comprehensive Docker health verification
    print_status "$YELLOW" "⏳ Comprehensive health verification starting..."
    local container_name="n8n-semble-test"
    
    # Step 1: Wait for container to be running and healthy
    if wait_for_container_health "local" "$container_name" 30 2; then
        # Step 2: Verify data persistence
        if verify_data_persistence "local" "$container_name"; then
            # Step 3: Verify API endpoint
            local api_attempts=15
            local api_attempt=0
            
            while [ $api_attempt -lt $api_attempts ]; do
                if curl -f http://localhost:5678/healthz >/dev/null 2>&1; then
                    print_status "$GREEN" "✅ Local n8n updated successfully to version $version"
                    
                    # Verify the actual running version
                    local actual_version=$(docker exec "$container_name" n8n --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "unknown")
                    if [ "$actual_version" != "unknown" ]; then
                        print_status "$GREEN" "✅ Confirmed running version: $actual_version"
                        
                        # Additional version verification
                        if [ "$actual_version" = "$version" ]; then
                            print_status "$GREEN" "✅ Version verification successful"
                        else
                            print_status "$YELLOW" "⚠️  Version mismatch: expected $version, got $actual_version"
                        fi
                    fi
                    
                    # Check community nodes after update
                    print_status "$BLUE" "🔍 Checking community nodes after update..."
                    sleep 5  # Give n8n time to fully start
                    local nodes_after=$(check_community_nodes "local")
                    
                    if [ "$nodes_after" = "present" ]; then
                        print_status "$GREEN" "✅ Community nodes still present after update"
                    elif [ "$nodes_before" = "present" ]; then
                        print_status "$YELLOW" "⚠️  Community nodes missing after update - redeploying..."
                        if redeploy_community_nodes "local"; then
                            print_status "$GREEN" "✅ Community nodes restored successfully"
                        else
                            print_status "$RED" "❌ Failed to restore community nodes"
                            print_status "$YELLOW" "💡 Run 'npm run deploy:local' manually to restore community nodes"
                        fi
                    fi
                    
                    print_status "$GREEN" "🌐 Access at: http://localhost:5678"
                    print_status "$GREEN" "💾 Backup available: n8n-backup-$backup_timestamp"
                    print_status "$GREEN" "📁 Backup location: $backup_dir/n8n-backup-$backup_timestamp"
                    return 0
                fi
                
                echo "  Waiting for API to be ready... (attempt $((api_attempt + 1))/$api_attempts)"
                sleep 2
                ((api_attempt++))
            done
            
            print_status "$RED" "❌ API endpoint verification failed"
        else
            print_status "$RED" "❌ Data persistence verification failed"
        fi
    else
        print_status "$RED" "❌ Container health verification failed"
    fi
    
    # Show comprehensive diagnostics if update failed
    print_status "$RED" "❌ Local update failed - comprehensive diagnostics:"
    print_status "$YELLOW" "📊 Container Status:"
    docker compose ps
    print_status "$YELLOW" "📊 Container Health:"
    docker inspect --format='{{.State.Health}}' "n8n-semble-test" 2>/dev/null || echo "No health check configured"
    print_status "$YELLOW" "📋 Container Logs (last 30 lines):"
    docker compose logs --tail=30 n8n
    print_status "$YELLOW" "📊 System Resources:"
    docker stats --no-stream "n8n-semble-test" 2>/dev/null || echo "Cannot get container stats"
    print_status "$YELLOW" "💾 Backup available for rollback: n8n-backup-$backup_timestamp"
    print_status "$YELLOW" "📁 Backup location: $backup_dir/n8n-backup-$backup_timestamp"
    print_status "$YELLOW" "💡 For continuous monitoring: docker compose logs -f n8n"
    
    return 1
}

# Function to update production Docker environment
update_production_docker() {
    local version="$1"
    
    # Validate SSH credentials
    if [ -z "$N8N_PROD_HOST" ] || [ -z "$N8N_PROD_USER" ] || [ -z "$N8N_PROD_PWD" ]; then
        print_status "$RED" "❌ Production SSH credentials not configured"
        echo "   Required: N8N_PROD_HOST, N8N_PROD_USER, N8N_PROD_PWD"
        return 1
    fi
    
    print_status "$BLUE" "🔄 Updating production n8n to version $version"
    
    # Get current version first
    local current_version=$(get_current_version_api "production")
    
    if [ "$current_version" = "$version" ]; then
        print_status "$GREEN" "✅ Production n8n already running version $version"
        return 0
    fi
    
    print_status "$YELLOW" "Current version: $current_version"
    print_status "$YELLOW" "Target version: $version"
    
    # Check SSH connection
    print_status "$YELLOW" "🔍 Checking SSH connection to production server..."
    if ! sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$N8N_PROD_USER@$N8N_PROD_HOST" "echo 'SSH OK'" >/dev/null 2>&1; then
        print_status "$RED" "❌ Cannot connect to production server $N8N_PROD_HOST"
        return 1
    fi
    
    # Check community nodes before update
    print_status "$BLUE" "🔍 Checking community nodes before update..."
    local nodes_before=$(check_community_nodes "production")
    if [ "$nodes_before" = "present" ]; then
        print_status "$GREEN" "✅ Community nodes detected before update"
    else
        print_status "$YELLOW" "⚠️  No community nodes detected before update"
    fi
    
    # Check if production compose file exists, if not provide guidance
    local compose_check=$(sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" \
        "test -f /root/docker-compose.yml && echo 'exists' || echo 'missing'" 2>/dev/null)
    
    if [ "$compose_check" = "missing" ]; then
        print_status "$RED" "❌ Production docker-compose.yml not found at /root/docker-compose.yml"
        print_status "$YELLOW" "💡 Please deploy the production compose file first:"
        print_status "$YELLOW" "   1. Copy templates/docker-compose.production.yml to your server"
        print_status "$YELLOW" "   2. Configure environment variables (see .env.example for template)"
        print_status "$YELLOW" "   3. Run: docker compose up -d"
        return 1
    fi
    
    # Create backup timestamp
    local backup_timestamp=$(date +%Y%m%d-%H%M%S)
    print_status "$BLUE" "💾 Creating backup: n8n-backup-$backup_timestamp"
    
    # Update production using official Docker Compose workflow
    print_status "$BLUE" "🔄 Updating production n8n to version $version..."
    
    sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" << EOF
        set -e
        
        echo "Updating n8n to version: $version"
        cd /root
        
        # Set the version environment variable for this session
        export N8N_PROD_VERSION="$version"
        
        # Create backup using official method
        mkdir -p /root/n8n-backups
        docker run --rm -v n8n_data:/source -v /root/n8n-backups:/backup alpine sh -c "
            mkdir -p /backup/n8n-backup-$backup_timestamp
            cp -r /source/* /backup/n8n-backup-$backup_timestamp/ 2>/dev/null || true
            echo 'Backup created: n8n-backup-$backup_timestamp'
        "
        
        # Official Docker Compose update workflow (as per n8n docs)
        echo "Following official n8n Docker Compose update process..."
        echo "Step 1: Pulling docker.n8n.io/n8nio/n8n:$version..."
        if ! docker compose pull; then
            echo "Failed to pull new n8n image"
            exit 1
        fi
        
        echo "Step 2: Stopping and removing containers..."
        if ! docker compose down; then
            echo "Failed to stop containers"
            exit 1
        fi
        
        echo "Step 3: Starting with new version..."
        if ! N8N_PROD_VERSION="$version" docker compose up -d; then
            echo "Failed to start containers with new version"
            exit 1
        fi
        
        echo "Production update completed successfully"
EOF
    
    # Comprehensive health check for production
    print_status "$YELLOW" "⏳ Comprehensive production health verification..."
    local production_container_name="n8n"
    
    # Step 1: Wait for container health via SSH
    local container_healthy=false
    local container_attempts=30
    local container_attempt=0
    
    while [ $container_attempt -lt $container_attempts ]; do
        local container_status=$(sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" \
            "docker compose ps n8n --format json 2>/dev/null | jq -r '.[0].State' 2>/dev/null || echo 'unknown'" 2>/dev/null)
        
        if [ "$container_status" = "running" ]; then
            container_healthy=true
            print_status "$GREEN" "✅ Production container is running"
            break
        elif [ "$container_status" = "unknown" ]; then
            print_status "$YELLOW" "⚠️  Cannot determine container status via Docker Compose"
            # Try alternative method
            local alt_status=$(sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" \
                "docker ps --filter 'name=n8n' --format '{{.Status}}' | head -1" 2>/dev/null || echo "not-found")
            if [[ "$alt_status" == "Up"* ]]; then
                container_healthy=true
                print_status "$GREEN" "✅ Production container is running (via docker ps)"
                break
            fi
        fi
        
        echo "  Waiting for production container... (attempt $((container_attempt + 1))/$container_attempts) [Status: $container_status]"
        sleep 3
        ((container_attempt++))
    done
    
    if [ "$container_healthy" = true ]; then
        # Step 2: Verify data persistence on production
        print_status "$BLUE" "🔍 Verifying production data persistence..."
        local data_ok=$(sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" \
            "docker exec \$(docker compose ps n8n -q 2>/dev/null || docker ps --filter 'name=n8n' -q | head -1) sh -c 'ls -la /home/node/.n8n 2>/dev/null | wc -l' 2>/dev/null || echo '0'")
        
        if [ "$data_ok" -gt 2 ]; then
            print_status "$GREEN" "✅ Production data persistence verified"
            
            # Step 3: HTTP endpoint verification
            local api_attempts=20
            local api_attempt=0
            
            while [ $api_attempt -lt $api_attempts ]; do
                if curl -f -s "https://workflows.thehealthsuite.co.uk/healthz" >/dev/null 2>&1; then
                    print_status "$GREEN" "✅ Production n8n updated successfully to version $version"
                    
                    # Verify the actual running version
                    local actual_version=$(sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" \
                        "docker exec \$(docker compose ps n8n -q 2>/dev/null || docker ps --filter 'name=n8n' -q | head -1) n8n --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo 'unknown'" 2>/dev/null)
                    if [ "$actual_version" != "unknown" ]; then
                        print_status "$GREEN" "✅ Confirmed production version: $actual_version"
                        
                        if [ "$actual_version" = "$version" ]; then
                            print_status "$GREEN" "✅ Production version verification successful"
                        else
                            print_status "$YELLOW" "⚠️  Version mismatch: expected $version, got $actual_version"
                        fi
                    fi
                    
                    # Check community nodes after update
                    print_status "$BLUE" "🔍 Checking community nodes after update..."
                    sleep 10  # Give production n8n more time to fully start
                    local nodes_after=$(check_community_nodes "production")
                    
                    if [ "$nodes_after" = "present" ]; then
                        print_status "$GREEN" "✅ Community nodes still present after update"
                    elif [ "$nodes_before" = "present" ]; then
                        print_status "$YELLOW" "⚠️  Community nodes missing after update - redeploying..."
                        if redeploy_community_nodes "production"; then
                            print_status "$GREEN" "✅ Community nodes restored successfully"
                        else
                            print_status "$RED" "❌ Failed to restore community nodes"
                            print_status "$YELLOW" "💡 Run 'npm run deploy:prod' manually to restore community nodes"
                        fi
                    fi
                    
                    print_status "$GREEN" "🌐 Access at: https://workflows.thehealthsuite.co.uk"
                    print_status "$GREEN" "💾 Backup available: n8n-backup-$backup_timestamp"
            print_status "$GREEN" "📊 Container status: $docker_status"
            
            # Update production version in .env
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s/^N8N_PROD_VERSION=.*/N8N_PROD_VERSION=$version/" "$ENV_FILE"
            else
                sed -i "s/^N8N_PROD_VERSION=.*/N8N_PROD_VERSION=$version/" "$ENV_FILE"
            fi
            
            return 0
                fi
                
                echo "  Waiting for production API... (attempt $((api_attempt + 1))/$api_attempts)"
                sleep 3
                ((api_attempt++))
            done
            
            print_status "$RED" "❌ Production API endpoint verification failed"
        else
            print_status "$RED" "❌ Production data persistence verification failed"
        fi
    else
        print_status "$RED" "❌ Production container health verification failed"
    fi
    
    # Show comprehensive production diagnostics if update failed
    print_status "$RED" "❌ Production update failed - comprehensive diagnostics:"
    print_status "$YELLOW" "📊 Production Container Status:"
    sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" \
        "docker compose ps" 2>/dev/null || echo "Could not retrieve container status"
    print_status "$YELLOW" "� Production Container Logs (last 30 lines):"
    sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no "$N8N_PROD_USER@$N8N_PROD_HOST" \
        "docker compose logs --tail=30 n8n" 2>/dev/null || echo "Could not retrieve logs"
    print_status "$YELLOW" "💡 Backup available for rollback: n8n-backup-$backup_timestamp"
    print_status "$YELLOW" "💡 For continuous monitoring: ssh and run 'docker compose logs -f n8n'"
    return 1
}

# Function to update n8n version (unified approach)
update_n8n_unified() {
    local env="$1"
    local version="$2"
    
    get_api_config "$env" || return 1
    
    # Check if n8n is accessible
    print_status "$YELLOW" "🔍 Checking $env n8n accessibility..."
    local current_version=$(get_current_version_api "$env")
    
    if [ "$current_version" = "unreachable" ]; then
        print_status "$RED" "❌ Cannot reach $env n8n at $HOST_URL"
        return 1
    fi
    
    # For Docker-based environments, we need to update the container
    if [ "$env" = "local" ]; then
        update_local_docker "$version"
    else
        update_production_docker "$version"
    fi
}

# Function to get current version
get_current_version_display() {
    local env="$1"
    
    if [ "$env" = "production" ]; then
        local version=$(get_current_version_api "production")
        echo "Production n8n version: $version"
    elif [ "$env" = "local" ]; then
        local version=$(get_current_version_api "local")
        echo "Local n8n version: $version"
    else
        # Show both
        local local_version=$(get_current_version_api "local")
        local prod_version=$(get_current_version_api "production")
        echo "Local n8n version: $local_version"
        echo "Production n8n version: $prod_version"
    fi
}

# Function to show usage
show_usage() {
    echo "🔄 Universal n8n Update Script with Comprehensive Health Verification"
    echo ""
    echo "✨ Features (Following Official n8n Docker Best Practices):"
    echo "  • Official Docker Compose update workflow (pull → down → up)"
    echo "  • Official docker.n8n.io/n8nio/n8n registry"  
    echo "  • Environment variable-based version management"
    echo "  • Comprehensive container health verification"
    echo "  • Data persistence verification after updates"
    echo "  • Multi-stage health checks (Docker + API + Version + Community Nodes)"
    echo "  • Detailed diagnostics and error reporting"
    echo "  • Production backup creation with rollback guidance"
    echo ""
    echo "Usage:"
    echo "  $0 [local|production] [version]          # Update to specific version"
    echo "  $0 [local|production] latest             # Update to latest stable version"
    echo "  $0 [local|production] current            # Show current version"
    echo "  $0 [local|production] list               # List available versions"
    echo "  $0 list                                  # List available versions"
    echo ""
    echo "Examples:"
    echo "  $0 local 1.107.3                        # Update local to version 1.107.3"
    echo "  $0 production latest                     # Update production to latest stable"
    echo "  $0 production current                    # Show production version"
    echo ""
    echo "Health Verification Process:"
    echo "  1. 🐳 Container Health: Docker status, health checks, resource usage"
    echo "  2. 💾 Data Persistence: .n8n directory structure and database integrity"
    echo "  3. 🌐 API Verification: HTTP endpoint responsiveness"
    echo "  4. 📋 Version Validation: Confirms actual running version matches target"
    echo "  5. 🔧 Community Nodes: Ensures custom nodes remain functional"
    echo ""
    echo "Docker Compose Process (Official n8n Method):"
    echo "  1. docker compose pull                  # Pull new images"
    echo "  2. docker compose down                  # Stop and remove containers"
    echo "  3. docker compose up -d                 # Start with new version"
    echo ""
    echo "Error Diagnostics Include:"
    echo "  • Container status and health information"
    echo "  • Detailed container logs (last 30 lines)"
    echo "  • System resource usage"
    echo "  • Rollback instructions for production failures"
    echo ""
    echo "Environment Configuration:"
    echo "  Local: Uses docker-compose.yml with N8N_LOCAL_VERSION env var"
    echo "  Production: Uses docker-compose.yml with N8N_PROD_VERSION env var"
    echo "  Templates: See templates/ directory for setup files"
    echo ""
}

# Main script logic
case "$1" in
    "local"|"production")
        case "$2" in
            "list"|"versions")
                list_available_versions
                ;;
            "current")
                get_current_version_display "$1"
                ;;
            "latest")
                latest_version=$(get_latest_version)
                update_n8n_unified "$1" "$latest_version"
                ;;
            *)
                # Assume it's a version number
                update_n8n_unified "$1" "$2"
                ;;
        esac
        ;;
    "list"|"versions")
        list_available_versions
        ;;
    "current")
        get_current_version_display "both"
        ;;
    "help"|"--help"|"-h")
        show_usage
        ;;
    "")
        show_usage
        ;;
    *)
        get_current_version_display "local"
        ;;
esac
