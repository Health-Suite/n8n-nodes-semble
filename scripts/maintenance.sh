#!/bin/bash

##
# Monthly n8n Maintenance Script
# 
# Runs comprehensive monthly maintenance tasks for n8n:
# - Creates backup
# - Updates n8n to latest version
# - Verifies n8n is running properly
# - Checks for community node updates
# - Reviews deprecation warnings
# - Checks Docker resource usage
# - Cleans up old backups
# 
# Each step requires approval before proceeding.
##

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
N8N_DIR="$PROJECT_DIR/../n8n-local-test"
BACKUP_DIR="$N8N_DIR/backups"

print_status() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    print_status "$BLUE" "  $1"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

ask_approval() {
    local prompt="$1"
    print_status "$YELLOW" "$prompt"
    read -p "Continue? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "$YELLOW" "⏭️  Skipped"
        return 1
    fi
    return 0
}

# Main maintenance workflow
main() {
    print_header "🔧 Monthly n8n Maintenance Workflow"
    print_status "$BLUE" "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Step 1: Check current version
    print_header "Step 1: Check Current Version"
    if ask_approval "Check current n8n version?"; then
        cd "$PROJECT_DIR"
        print_status "$BLUE" "Current version:"
        docker exec n8n-semble-test n8n --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "Unable to get version"
        print_status "$GREEN" "✅ Version check complete"
    fi
    
    # Step 2: Check available updates
    print_header "Step 2: Check Available Updates"
    if ask_approval "Check for available n8n updates?"; then
        cd "$PROJECT_DIR"
        npm run n8n:versions
        print_status "$GREEN" "✅ Update check complete"
    fi
    
    # Step 3: Update n8n
    print_header "Step 3: Update n8n to Latest"
    if ask_approval "Update n8n to latest version? (This will create a backup automatically)"; then
        cd "$PROJECT_DIR"
        npm run update:n8n:local:latest
        print_status "$GREEN" "✅ n8n update complete"
    fi
    
    # Step 4: Verify n8n is running
    print_header "Step 4: Verify n8n Status"
    if ask_approval "Verify n8n is running properly?"; then
        cd "$PROJECT_DIR"
        echo ""
        print_status "$BLUE" "Container status:"
        npm run status:n8n
        echo ""
        print_status "$BLUE" "Updated version:"
        docker exec n8n-semble-test n8n --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "Unable to get version"
        print_status "$GREEN" "✅ Verification complete"
    fi
    
    # Step 5: Check deprecation warnings
    print_header "Step 5: Check Deprecation Warnings"
    if ask_approval "Check for deprecation warnings in logs?"; then
        cd "$PROJECT_DIR"
        print_status "$BLUE" "Recent logs (checking for deprecations):"
        docker logs n8n-semble-test 2>&1 | grep -i "deprecat" | tail -20 || echo "No deprecation warnings found"
        print_status "$GREEN" "✅ Deprecation check complete"
    fi
    
    # Step 6: Update Node Dependencies
    print_header "Step 6: Update Node Dependencies"
    if ask_approval "Update n8n-nodes-semble package dependencies (safe updates only)?"; then
        cd "$PROJECT_DIR"
        print_status "$BLUE" "Checking for outdated dependencies..."
        pnpm outdated || true
        echo ""
        
        # Update patch and minor versions (respects semver ranges)
        print_status "$BLUE" "Updating safe dependencies (patch/minor versions)..."
        if pnpm update; then
            print_status "$GREEN" "✅ Safe dependencies updated successfully"
        else
            print_status "$RED" "❌ Dependency update failed"
        fi
        
        echo ""
        # Check for major version updates
        print_status "$BLUE" "Checking for major version updates..."
        MAJOR_UPDATES=$(pnpm outdated --format json 2>/dev/null | jq -r '.[] | select(.current != .latest and (.latest | split(".")[0] | tonumber) > (.current | split(".")[0] | tonumber)) | "\(.name): \(.current) → \(.latest)"' 2>/dev/null || echo "")
        
        if [ -n "$MAJOR_UPDATES" ]; then
            print_status "$YELLOW" "⚠️  Major updates available (require manual review):"
            echo "$MAJOR_UPDATES" | while IFS= read -r line; do
                echo "  • $line"
            done
            echo ""
            print_status "$YELLOW" "To update major versions: pnpm update --latest <package-name>"
        else
            print_status "$GREEN" "No major updates pending"
        fi
        print_status "$GREEN" "✅ Dependency check complete"
    fi
    
    # Step 7: Test Semble API Connection
    print_header "Step 7: Test Semble API Connection"
    if ask_approval "Test Semble API connection?"; then
        cd "$PROJECT_DIR"
        print_status "$BLUE" "Testing API connection..."
        # Load environment variables from workspace .env
        if [ -f "$PROJECT_DIR/../.env" ]; then
            export SEMBLE_API_TOKEN=$(grep "^SEMBLE_TOKEN=" "$PROJECT_DIR/../.env" | cut -d '=' -f2)
        fi
        if npm run test:api; then
            print_status "$GREEN" "✅ API connection test complete"
        else
            print_status "$RED" "❌ API connection test failed"
        fi
    fi
    
    # Step 8: Check for Outdated Nodes
    print_header "Step 8: Check for Outdated Community Nodes"
    if ask_approval "Check for outdated community nodes in workflows?"; then
        print_status "$BLUE" "Checking installed community nodes..."
        docker exec n8n-semble-test ls -la /home/node/.n8n/nodes 2>/dev/null || echo "No custom nodes directory found"
        echo ""
        print_status "$YELLOW" "Note: Check n8n UI (Settings > Community Nodes) for available updates"
        print_status "$GREEN" "✅ Node check complete"
    fi
    
    # Step 9: Check Docker resources
    print_header "Step 9: Check Docker Resource Usage"
    if ask_approval "Check Docker container resource usage?"; then
        print_status "$BLUE" "Container resource stats:"
        docker stats --no-stream n8n-semble-test 2>/dev/null || echo "Container not running"
        print_status "$GREEN" "✅ Resource check complete"
    fi
    
    # Step 10: Clean up old backups
    print_header "Step 10: Clean Up Old Backups"
    if ask_approval "Clean up old backups? (Keep last 5)"; then
        print_status "$BLUE" "Current backups:"
        ls -lth "$BACKUP_DIR" | grep "n8n-backup-" | head -10 || echo "No backups found"
        echo ""
        
        # Count backups
        backup_count=$(ls -1 "$BACKUP_DIR" | grep "n8n-backup-" | wc -l)
        print_status "$BLUE" "Total backups: $backup_count"
        
        if [ "$backup_count" -gt 5 ]; then
            print_status "$YELLOW" "Removing backups older than the last 5..."
            cd "$BACKUP_DIR"
            ls -1t | grep "n8n-backup-" | tail -n +6 | xargs -I {} rm -rf {}
            print_status "$GREEN" "✅ Cleanup complete"
        else
            print_status "$GREEN" "✅ No cleanup needed (5 or fewer backups)"
        fi
    fi
    
    # Step 11: Generate summary report
    print_header "Step 11: Maintenance Summary"
    print_status "$GREEN" "🎉 Monthly maintenance workflow complete!"
    echo ""
    print_status "$BLUE" "Summary:"
    echo "  • n8n version: $(docker exec n8n-semble-test n8n --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo 'unknown')"
    echo "  • Container status: $(docker inspect --format='{{.State.Status}}' n8n-semble-test 2>/dev/null || echo 'not running')"
    echo "  • Available backups: $(ls -1 "$BACKUP_DIR" 2>/dev/null | grep "n8n-backup-" | wc -l)"
    echo "  • Latest backup: $(ls -1t "$BACKUP_DIR" 2>/dev/null | grep "n8n-backup-" | head -1 || echo 'none')"
    echo ""
    print_status "$YELLOW" "📝 Manual tasks to review:"
    echo "  • Review and apply community node updates in n8n UI (Settings > Community Nodes)"
    echo "  • Review failed workflow executions"
    echo "  • Test critical workflows"
    echo "  • Apply dependency updates if needed: pnpm update"
    echo ""
    print_status "$GREEN" "Maintenance completed at: $(date '+%Y-%m-%d %H:%M:%S')"
}

# Run main workflow
main "$@"
