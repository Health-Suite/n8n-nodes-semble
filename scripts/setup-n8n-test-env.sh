#!/bin/bash

# n8n-nodes-semble Test Environment Setup Script
# This script creates a complete n8n testing environment for the Semble node

set -e

echo "🚀 Setting up n8n-nodes-semble test environment..."

# Change to the n8n-nodes-semble directory
cd "$(dirname "$0")/.."

# Define test environment directory
TEST_DIR="../n8n-local-test"

# Create test environment directory
if [ -d "$TEST_DIR" ]; then
    echo "📁 Test environment exists, updating..."
    rm -rf "$TEST_DIR"
fi

mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

echo "📝 Creating docker-compose.yml..."
cat > docker-compose.yml << 'EOF'
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_LOCAL_VERSION:-latest}
    container_name: n8n-semble-test
    restart: always
    env_file:
      - ../.env
    ports:
      - "5678:5678"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    environment:
      # --- Required Environment Variables (Official n8n Recommendations) ---
      - GENERIC_TIMEZONE=Europe/London
      - TZ=Europe/London
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - N8N_RUNNERS_MODE=external
      - N8N_RUNNERS_TASK_BROKER_URI=http://n8n-task-broker:5679
      
      # --- Redis Configuration (Required for External Task Runners) ---
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      
      # --- Webhook and Host Configuration ---
      - WEBHOOK_URL=http://localhost:5678/
      
      # --- Community Packages ---
      - N8N_COMMUNITY_PACKAGES_ENABLED=true
      
      # --- API Configuration ---
      - N8N_API_ENABLED=true
      - N8N_API_KEY=${N8N_LOCAL_API_KEY:-test-api-key-12345}
      
      # --- Logging ---
      - N8N_LOG_LEVEL=info
      
      # --- Security and Performance ---
      - N8N_SECURE_COOKIE=false
      - N8N_METRICS=false
      - N8N_SKIP_AUTH_ON_OAUTH_CALLBACK=false
      
      # --- Database Configuration ---
      - DB_SQLITE_POOL_SIZE=5
    volumes:
      - n8n_data:/home/node/.n8n
      - ./n8n-nodes-semble.tgz:/tmp/n8n-nodes-semble.tgz
    networks:
      - n8n-network
    depends_on:
      - redis

  redis:
    image: redis:7-alpine
    container_name: n8n-redis-local
    restart: always
    networks:
      - n8n-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  n8n-task-runner:
    image: n8nio/runners:${N8N_LOCAL_VERSION:-latest}
    container_name: n8n-task-runner-local
    restart: always
    env_file:
      - ../.env
    environment:
      - N8N_RUNNERS_TASK_BROKER_URI=http://n8n-task-broker:5679
      - N8N_RUNNERS_AUTH_TOKEN=${N8N_RUNNERS_AUTH_TOKEN}
      - NODE_FUNCTION_ALLOW_BUILTIN=*
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
    networks:
      - n8n-network
    depends_on:
      - n8n

  n8n-task-broker:
    image: docker.n8n.io/n8nio/n8n:${N8N_LOCAL_VERSION:-latest}
    container_name: n8n-task-broker-local
    restart: always
    command: worker --type=taskBroker
    env_file:
      - ../.env
    environment:
      - GENERIC_TIMEZONE=Europe/London
      - TZ=Europe/London
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_RUNNERS_ENABLED=true
      - N8N_RUNNERS_MODE=external
      - N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
    networks:
      - n8n-network
    depends_on:
      - n8n
      - redis

volumes:
  n8n_data:
    driver: local

networks:
  n8n-network:
    driver: bridge
EOF

echo "🔧 Creating start.sh..."
cat > start.sh << 'EOF'
#!/bin/bash
# Startup script for n8n local test environment
# Loads environment variables from centralized .env file

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables from parent .env
if [ -f "$SCRIPT_DIR/../.env" ]; then
    echo "Loading environment variables from ../.env"
    export $(grep -v '^#' "$SCRIPT_DIR/../.env" | grep -v '^$' | xargs)
else
    echo "Warning: ../.env file not found"
    exit 1
fi

# Execute docker compose with any arguments passed to this script
cd "$SCRIPT_DIR"
docker compose "$@"
EOF

chmod +x start.sh

echo "🔧 Creating install-semble-node.sh..."
cat > install-semble-node.sh << 'EOF'
#!/bin/bash

echo "Installing n8n-nodes-semble in local n8n..."

# Check if package exists
if [ ! -f "n8n-nodes-semble.tgz" ]; then
    echo "❌ Package file n8n-nodes-semble.tgz not found!"
    echo "   Run 'npm run pack:local' from the n8n-nodes-semble directory first."
    exit 1
fi

# Check if container is running
if ! docker ps | grep -q "n8n-semble-test"; then
    echo "❌ n8n container is not running!"
    echo "   Run './start.sh up -d' first."
    exit 1
fi

echo "📦 Extracting package..."
docker exec n8n-semble-test sh -c "cd /tmp && rm -rf package && tar -xzf n8n-nodes-semble.tgz"

echo "🔧 Removing pnpm restriction..."
docker exec n8n-semble-test sh -c "cd /tmp/package && sed -i 's/\"preinstall\": \"npx only-allow pnpm\",//g' package.json"

echo "📥 Installing dependencies..."
docker exec n8n-semble-test sh -c "cd /tmp/package && npm install >/dev/null 2>&1"

echo "📋 Installing node in n8n user directory..."
docker exec -u root n8n-semble-test sh -c "rm -rf /home/node/.n8n/nodes/node_modules/n8n-nodes-semble"
docker exec -u root n8n-semble-test sh -c "cp -r /tmp/package /home/node/.n8n/nodes/node_modules/n8n-nodes-semble"
docker exec -u root n8n-semble-test sh -c "chown -R node:node /home/node/.n8n/nodes/node_modules/n8n-nodes-semble"

echo "📄 Updating package.json..."
docker exec n8n-semble-test sh -c 'echo "{\"name\": \"installed-nodes\", \"private\": true, \"dependencies\": {\"n8n-nodes-semble\": \"file:./n8n-nodes-semble\"}}" > /home/node/.n8n/nodes/package.json'

echo "🔄 Restarting n8n..."
./start.sh restart >/dev/null 2>&1

echo "✅ Installation complete!"
echo ""
echo "Your Semble node should now be available in n8n:"
echo "   1. Open http://localhost:5678"
echo "   2. Create a new workflow"
echo "   3. Search for 'Semble' in the node picker"
echo ""
echo "To update the node:"
echo "   1. Run 'npm run pack:local' from n8n-nodes-semble directory"
echo "   2. Run this script again"
EOF

chmod +x install-semble-node.sh

echo "� Creating env-utils.sh..."
cat > env-utils.sh << 'EOF'
#!/bin/bash

# Environment setup utility functions for The Health Suite
# This file provides functions to manage the workspace .env file

WORKSPACE_ROOT="/Users/mikehatcher/Websites/the-health-suite"
ENV_FILE="$WORKSPACE_ROOT/.env"
ENV_EXAMPLE_FILE="$WORKSPACE_ROOT/n8n-nodes-semble/.env.example"

# Function to ensure .env file exists with required n8n configuration
ensure_env_file() {
    local required_vars=("N8N_LOCAL_ADMIN_EMAIL" "N8N_LOCAL_ADMIN_PASSWORD" "N8N_LOCAL_ADMIN_FIRST_NAME" "N8N_LOCAL_ADMIN_LAST_NAME")
    local missing_vars=()
    local existing_vars=()
    
    # Create .env file if it doesn't exist
    if [ ! -f "$ENV_FILE" ]; then
        echo "📝 Creating .env file from template..."
        if [ -f "$ENV_EXAMPLE_FILE" ]; then
            cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
            echo "✅ Created .env file at $ENV_FILE"
            return 0
        else
            echo "❌ Error: .env.example file not found at $ENV_EXAMPLE_FILE"
            return 1
        fi
    fi
    
    # Check which variables are missing or present
    for var in "${required_vars[@]}"; do
        if env_var_exists "$var"; then
            existing_vars+=("$var")
        else
            missing_vars+=("$var")
        fi
    done
    
    # If all variables exist, check if they need updating
    if [ ${#missing_vars[@]} -eq 0 ]; then
        echo "✅ .env file exists with n8n configuration"
        
        # Check if any variables have default values that need updating
        local needs_update=false
        local email=$(get_env_var "N8N_LOCAL_ADMIN_EMAIL")
        if [ "$email" = "admin@example.com" ] || [ "$email" = "your_email_here" ]; then
            needs_update=true
        fi
        
        if [ "$needs_update" = true ]; then
            echo "⚠️  n8n configuration contains default values"
            read -p "Do you want to update the n8n configuration? (y/N): " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                # Remove existing n8n variables so they can be re-added
                for var in "${required_vars[@]}"; do
                    remove_env_var "$var"
                done
                append_n8n_config_from_template
            fi
        fi
        return 0
    fi
    
    # If some variables are missing, append them
    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "📝 .env file exists but missing n8n configuration variables: ${missing_vars[*]}"
        append_n8n_config_from_template
    fi
}

# Function to append n8n configuration from template
append_n8n_config_from_template() {
    if [ ! -f "$ENV_EXAMPLE_FILE" ]; then
        echo "❌ Error: .env.example file not found at $ENV_EXAMPLE_FILE"
        return 1
    fi
    
    echo "📝 Adding n8n configuration to .env file..."
    
    # Add a section header if the file doesn't end with a newline
    if [ -s "$ENV_FILE" ] && [ "$(tail -c1 "$ENV_FILE")" != "" ]; then
        echo "" >> "$ENV_FILE"
    fi
    
    # Add comment header
    echo "# n8n Configuration (added automatically)" >> "$ENV_FILE"
    
    # Extract and append n8n-related lines from template
    grep -E "^N8N_" "$ENV_EXAMPLE_FILE" >> "$ENV_FILE"
    
    echo "✅ Added n8n configuration to .env file"
}

# Function to remove a variable from .env
remove_env_var() {
    local var_name="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "/^${var_name}=/d" "$ENV_FILE"
    else
        # Linux
        sed -i "/^${var_name}=/d" "$ENV_FILE"
    fi
}

# Function to check if a variable exists in .env
env_var_exists() {
    local var_name="$1"
    grep -q "^${var_name}=" "$ENV_FILE" 2>/dev/null
}

# Function to get value from .env
get_env_var() {
    local var_name="$1"
    grep "^${var_name}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | sed 's/^["'"'"']//' | sed 's/["'"'"']$//'
}

# Function to set/update value in .env
set_env_var() {
    local var_name="$1"
    local var_value="$2"
    
    if env_var_exists "$var_name"; then
        # Update existing variable
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            sed -i '' "s/^${var_name}=.*/${var_name}=${var_value}/" "$ENV_FILE"
        else
            # Linux
            sed -i "s/^${var_name}=.*/${var_name}=${var_value}/" "$ENV_FILE"
        fi
    else
        # Add new variable
        echo "${var_name}=${var_value}" >> "$ENV_FILE"
    fi
}

# Function to prompt for n8n credentials
setup_n8n_credentials() {
    echo "🔑 Setting up n8n credentials..."
    
    local email password first_name last_name
    
    # Check if credentials already exist
    if env_var_exists "N8N_LOCAL_ADMIN_EMAIL" && env_var_exists "N8N_LOCAL_ADMIN_PASSWORD"; then
        email=$(get_env_var "N8N_LOCAL_ADMIN_EMAIL")
        if [ "$email" != "admin@example.com" ] && [ "$email" != "your_email_here" ] && [ -n "$email" ]; then
            echo "✅ n8n credentials already configured for: $email"
            return 0
        fi
    fi
    
    echo "Please enter your n8n admin credentials:"
    
    # Prompt for email
    while true; do
        read -p "Email address: " email
        if [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            break
        else
            echo "❌ Please enter a valid email address"
        fi
    done
    
    # Prompt for password
    while true; do
        read -s -p "Password (min 8 characters): " password
        echo
        if [ ${#password} -ge 8 ]; then
            break
        else
            echo "❌ Password must be at least 8 characters long"
        fi
    done
    
    # Prompt for first name
    read -p "First name (optional, default: Admin): " first_name
    first_name=${first_name:-Admin}
    
    # Prompt for last name
    read -p "Last name (optional, default: User): " last_name
    last_name=${last_name:-User}
    
    # Save to .env file
    set_env_var "N8N_LOCAL_ADMIN_EMAIL" "$email"
    set_env_var "N8N_LOCAL_ADMIN_PASSWORD" "$password"
    set_env_var "N8N_LOCAL_ADMIN_FIRST_NAME" "$first_name"
    set_env_var "N8N_LOCAL_ADMIN_LAST_NAME" "$last_name"
    
    echo "✅ n8n credentials saved to .env file"
}

# Function to load .env file variables
load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a  # automatically export all variables
        source "$ENV_FILE"
        set +a  # turn off automatic export
    else
        echo "❌ .env file not found at $ENV_FILE"
        return 1
    fi
}

# Function to validate n8n credentials are set
validate_n8n_credentials() {
    if [ -z "$N8N_LOCAL_ADMIN_EMAIL" ] || [ -z "$N8N_LOCAL_ADMIN_PASSWORD" ]; then
        echo "❌ n8N credentials not found in environment"
        return 1
    fi
    
    if [ "$N8N_LOCAL_ADMIN_EMAIL" = "admin@example.com" ] || [ "$N8N_LOCAL_ADMIN_EMAIL" = "your_email_here" ]; then
        echo "❌ Please configure your n8n credentials (email is still set to default)"
        return 1
    fi
    
    return 0
}
EOF

chmod +x env-utils.sh

echo "�👤 Creating setup-owner-account.sh..."
cat > setup-owner-account.sh << 'EOF'
#!/bin/bash

# Load environment utilities
source "$(dirname "$0")/env-utils.sh"

echo "🔑 Setting up n8n owner account..."

# Ensure .env file exists
ensure_env_file

# Setup n8n credentials if needed
setup_n8n_credentials

# Load environment variables
load_env

# Validate credentials are set
if ! validate_n8n_credentials; then
    echo "❌ Cannot proceed without valid n8n credentials"
    exit 1
fi

# Wait for n8n to be ready
echo "⏳ Waiting for n8n to start..."
until curl -f http://localhost:5678/healthz >/dev/null 2>&1; do
    echo "  Still waiting..."
    sleep 2
done

echo "✅ n8n is ready! Creating owner account..."

# Setup owner account via API using environment variables
RESPONSE=$(curl -s -X POST http://localhost:5678/rest/owner/setup \
  -H "Content-Type: application/json" \
  -d "{
    \"email\": \"$N8N_LOCAL_ADMIN_EMAIL\",
    \"password\": \"$N8N_LOCAL_ADMIN_PASSWORD\",
    \"firstName\": \"$N8N_LOCAL_ADMIN_FIRST_NAME\",
    \"lastName\": \"$N8N_LOCAL_ADMIN_LAST_NAME\"
  }")

if echo "$RESPONSE" | grep -q '"id"'; then
    echo "✅ Owner account created successfully!"
    echo "   Email: $N8N_LOCAL_ADMIN_EMAIL"
    echo "   Password: [CONFIGURED]"
    echo "   URL: http://localhost:5678"
else
    echo "ℹ️  Owner account setup response: $RESPONSE"
    echo "   (Account may already exist or there was an issue)"
fi
EOF

chmod +x setup-owner-account.sh

echo "👤 Creating setup-owner.sh (legacy alias)..."
cp setup-owner-account.sh setup-owner.sh

echo "🏗️ Creating custom_nodes directory..."
mkdir -p custom_nodes

echo "📚 Creating README.md..."
cat > README.md << 'EOF'
# n8n-nodes-semble Test Environment

This is a local n8n testing environment specifically for the n8n-nodes-semble package.

## Quick Start

1. **Build and package the node** (from the n8n-nodes-semble directory):
   ```bash
   npm run pack:local
   ```

2. **Start n8n:**
   ```bash
   ./start.sh up -d
   ```

3. **Set up owner account:**
   ```bash
   ./setup-owner-account.sh
   ```
   
   This will:
   - Create/check the workspace .env file
   - Prompt for your n8n admin credentials (if not configured)
   - Set up the owner account using your credentials

4. **Install the Semble node:**
   ```bash
   ./install-semble-node.sh
   ```

5. **Open n8n:**
   Open http://localhost:5678 in your browser
   - Use the credentials you configured in step 3

## Environment Configuration

This setup uses a centralized `.env` file located at `/Users/mikehatcher/Websites/the-health-suite/.env` that contains:

- n8n admin credentials
- Semble API configuration
- Other workspace-wide environment variables

The `.env` file is automatically created from `.env.example` if it doesn't exist, and you'll be prompted to configure your credentials when needed.

## Testing the Semble Node

1. Create a new workflow in n8n
2. Search for "Semble" in the node picker
3. You should see two nodes:
   - **Semble** - For CRUD operations (patients, appointments, staff)
   - **Semble Trigger** - For polling triggers

## Development Workflow

1. **Make changes** to the source code in the n8n-nodes-semble directory
2. **Rebuild and repackage**: `npm run pack:local`
3. **Reinstall** the node: `./install-semble-node.sh`
4. **Test** your changes in n8n
5. **Repeat** as needed

## Environment Management

- **View logs:** `./start.sh logs -f`
- **Stop environment:** `./start.sh down`
- **Reset environment:** `./start.sh down -v` (removes all data)
- **Restart n8n:** `./start.sh restart`
- **Update n8n:** `./update-n8n.sh` (local alias) or use unified script
- **Check n8n version:** `./update-n8n.sh current`
- **List available versions:** `./update-n8n.sh list`

## n8n Version Management

The environment supports unified n8n version management for both local and production:

**From the n8n-nodes-semble directory:**
```bash
# Local environment
./scripts/update-n8n.sh local               # Interactive update
./scripts/update-n8n.sh local 1.55.3       # Update to specific version
./scripts/update-n8n.sh local latest       # Update to latest
./scripts/update-n8n.sh local current      # Check current version
./scripts/update-n8n.sh local rollback 1.54.0  # Rollback

# Production environment
./scripts/update-n8n.sh production         # Interactive update
./scripts/update-n8n.sh production latest  # Update to latest
./scripts/update-n8n.sh production current # Check current version
./scripts/update-n8n.sh production rollback 1.54.0  # Rollback

# Both environments
./scripts/update-n8n.sh current           # Show both versions
./scripts/update-n8n.sh list              # List available versions
```

**From the n8n-local-test directory:**
```bash
# Local-only commands (legacy aliases)
./update-n8n.sh                           # Interactive update
./update-n8n.sh 1.55.3                    # Update to specific version
./update-n8n.sh current                   # Check current version
```

**NPM Scripts:**
```bash
# Local environment
npm run update:n8n:local                  # Interactive local update
npm run update:n8n:local:latest           # Update local to latest
npm run n8n:version:local                 # Check local version

# Production environment
npm run update:n8n:production             # Interactive production update
npm run update:n8n:production:latest      # Update production to latest
npm run n8n:version:production            # Check production version

# Both environments
npm run n8n:version                       # Check both versions
npm run n8n:versions                      # List available versions
```

**Features:**
- ✅ **Unified Script** - Single script manages both local and production
- ✅ **Environment Detection** - Automatically uses correct credentials
- ✅ **Backup & Rollback** - Automatic backups before production updates
- ✅ **Health Checks** - Validates updates before completing
- ✅ **Version Control** - Updates .env file with new versions
- ✅ **SSH Integration** - Secure production updates via SSH
- ✅ **Multiple Interfaces** - CLI script, npm commands, and legacy aliases

## Semble API Credentials

To test the nodes, you'll need to set up Semble API credentials in n8n:

1. Go to Settings > Credentials in n8n
2. Create new "Semble API" credentials with:
   - **API Token:** Your Semble x-token (JWT format)
   - **Base URL:** `https://open.semble.io/graphql` (default)

You can also configure your Semble API token in the workspace `.env` file under `SEMBLE_API_TOKEN`.

## Rate Limiting

The Semble node includes built-in rate limiting:
- Maximum 120 requests per minute
- Automatic retry with exponential backoff
- Pre-emptive throttling to prevent rate limit hits

## Troubleshooting

### Node not appearing
- Check that the container is running: `docker ps`
- Verify the package was built: `ls -la n8n-nodes-semble-1.0.0.tgz`
- Check n8n logs: `./start.sh logs -f`

### Installation fails
- Ensure Docker is running
- Try rebuilding: `npm run pack:local` (from parent directory)
- Reset environment: `./start.sh down -v && ./start.sh up -d`

### Credentials not working
- Check your `.env` file exists and contains valid credentials
- Re-run `./setup-owner-account.sh` to reconfigure
- Verify email format and password length (minimum 8 characters)

### Testing specific features
- **GraphQL queries:** Use the Custom API Call option
- **Rate limiting:** Create multiple rapid requests
- **Polling triggers:** Set short poll intervals (minimum 30 seconds)
EOF

echo "🎯 Creating initial tarball placeholder..."
# This will be replaced by the actual tarball from pack:local
touch n8n-nodes-semble.tgz

cd - > /dev/null

echo "✅ n8n test environment setup complete!"
echo ""
echo "📁 Created: ../n8n-local-test/"
echo ""
echo "🚀 Next steps:"
echo "   1. npm run pack:local                    # Build and package the node"
echo "   2. cd ../n8n-local-test                 # Go to test environment"
echo "   3. ./start.sh up -d                    # Start n8n"
echo "   4. ./setup-owner-account.sh             # Create admin account"
echo "   5. ./install-semble-node.sh             # Install the Semble node"
echo "   6. Open http://localhost:5678           # Access n8n"
echo ""
echo "📧 Login credentials will be configured via .env file during setup"
echo "🔍 Search for 'Semble' in the node picker to find both nodes"

echo "🔄 Creating update-n8n.sh (alias to main script)..."
cat > update-n8n.sh << 'EOF'
#!/bin/bash
# Legacy alias - redirect to main update script
exec "$(dirname "$0")/../n8n-nodes-semble/scripts/update-n8n.sh" local "$@"
EOF

chmod +x update-n8n.sh
