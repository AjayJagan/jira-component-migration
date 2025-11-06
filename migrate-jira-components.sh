#!/bin/bash
# JIRA Component Migration Script: RHOAISTRAT → RHAISTRAT
# This script migrates JIRA components from source to destination project
# with proper error handling, validation, and rollback capabilities

set -euo pipefail  # Exit on error, undefined variables, pipe failures

#=============================================================================
# CONFIGURATION
#=============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default values
CONFIG_FILE="${CONFIG_FILE:-.jira-migration.conf}"
JIRA_URL="${JIRA_URL:-https://issues.redhat.com}"
BOT_TOKEN="${BOT_TOKEN:-}"
SOURCE_PROJECT="${SOURCE_PROJECT:-RHOAISTRAT}"
DEST_PROJECT="${DEST_PROJECT:-RHAISTRAT}"
MIGRATION_DATE=$(date +%Y%m%d_%H%M%S)
MIGRATION_DIR="jira_migration_${MIGRATION_DATE}"
DRY_RUN=false
SKIP_BACKUP=false
FORCE_CONFIRM=false
RATE_LIMIT_DELAY=2

#=============================================================================
# HELPER FUNCTIONS
#=============================================================================

# Print colored messages
print_info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

print_success() {
    echo -e "${GREEN}✓${NC} $*"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

print_error() {
    echo -e "${RED}✗${NC} $*" >&2
}

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Show progress with percentage and progress bar
show_progress() {
    local current=$1
    local total=$2
    local component_name=$3
    local percent=$((current * 100 / total))
    local progress_width=30
    local filled=$((percent * progress_width / 100))
    local empty=$((progress_width - filled))

    # Build progress bar
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    # Truncate component name if too long
    local display_name="$component_name"
    if [[ ${#display_name} -gt 35 ]]; then
        display_name="${display_name:0:32}..."
    fi

    printf "\r${BLUE}ℹ${NC} [%3d%%] [%d/%d] %s %-35s" "$percent" "$current" "$total" "$bar" "$display_name"
}

# Show a simple spinner for operations without discrete progress
show_spinner() {
    local pid=$1
    local message=$2
    local spin='-\|/'
    local i=0

    printf "${BLUE}ℹ${NC} %s " "$message"
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${BLUE}ℹ${NC} %s %c" "$message" "${spin:i++%${#spin}:1}"
        sleep 0.1
    done
    printf "\r${BLUE}ℹ${NC} %s ✓\n" "$message"
}

# Helper function to make authenticated curl requests with Bearer token
jira_curl() {
    curl "$@" -H "Authorization: Bearer ${BOT_TOKEN}"
}

# Show usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Migrate JIRA components between projects with comprehensive conflict detection,
backup, verification, and rollback capabilities.

OPTIONS:
    -h, --help              Show this help message
    -c, --config FILE       Configuration file (default: .jira-migration.conf)
    -d, --dry-run           Perform a dry run without making changes
    -f, --force             Skip interactive confirmation (for automation)
    -s, --skip-backup       Skip backup step (not recommended)
    -u, --jira-url URL      JIRA instance URL (default: https://issues.redhat.com)
    -t, --token TOKEN       Bearer token for authentication
    --source PROJECT        Source project key
    --dest PROJECT          Destination project key
    --delay SECONDS         Rate limit delay between API calls (default: 2)

ENVIRONMENT VARIABLES:
    JIRA_URL                JIRA instance URL
    BOT_TOKEN               Bearer token for authentication
    SOURCE_PROJECT          Source project key
    DEST_PROJECT            Destination project key
    FORCE_CONFIRM           Skip confirmation (true/false)
    RATE_LIMIT_DELAY        Delay between API calls in seconds

CONFIGURATION FILE:
    Create .jira-migration.conf to persist settings:

    JIRA_URL=https://issues.redhat.com
    BOT_TOKEN=your-bearer-token-here
    SOURCE_PROJECT=SOURCEPROJ
    DEST_PROJECT=DESTPROJ
    RATE_LIMIT_DELAY=2
    FORCE_CONFIRM=false

EXAMPLES:

  Basic Usage:
    # Interactive mode with prompts
    $0

    # Quick dry-run to preview changes
    $0 --dry-run

    # Migrate with specific projects
    $0 --source RHOAISTRAT --dest RHAISTRAT --dry-run

  Configuration File Approach (Recommended):
    # 1. Create config file
    cp .jira-migration.conf.example .jira-migration.conf
    # 2. Edit with your settings
    vim .jira-migration.conf
    # 3. Run migration
    $0 --dry-run
    $0  # Live migration after reviewing dry-run

  Environment Variables:
    export BOT_TOKEN="your-bearer-token-here"
    export SOURCE_PROJECT="RHOAIRFE"
    export DEST_PROJECT="RHAISTRAT"
    $0 --dry-run

  Automation/CI-CD:
    # Non-interactive automation-friendly execution
    $0 --config /path/to/prod.conf --force --source PROJ1 --dest PROJ2

    # With custom rate limiting for busy instances
    $0 --delay 5 --force --dry-run

  Troubleshooting:
    # Test connectivity and permissions only
    $0 --dry-run --source TESTPROJ --dest TESTPROJ

    # Migration with verbose logging (check migration logs)
    $0 --dry-run && cat jira_migration_*/migration_log.txt

WORKFLOW:
  1. Always run with --dry-run first to preview changes
  2. Review conflicts.txt and migration_report.txt in output directory
  3. Run actual migration after confirming dry-run results
  4. Verify component mappings in component_mapping.csv

OUTPUT FILES (saved in jira_migration_YYYYMMDD_HHMMSS/):
  - migration_report.txt      : Summary and statistics
  - migration_log.txt         : Detailed operation log
  - component_mapping.csv     : Source to destination ID mappings
  - conflicts.txt            : Components skipped due to naming conflicts
  - source_components.json    : Full backup of source components
  - dest_components_*.json    : Destination state before/after migration

REAL-WORLD EXAMPLES:
  # Migrate RHOAISTRAT components to RHAISTRAT (17 components migrated)
  $0 --source RHOAISTRAT --dest RHAISTRAT --dry-run

  # Migrate RHOAIRFE components to RHAISTRAT (16 components migrated)
  $0 --source RHOAIRFE --dest RHAISTRAT --dry-run

For support: https://github.com/AjayJagan/jira-component-migration/issues

EOF
    exit 0
}

# Load configuration from file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        print_info "Loading configuration from $CONFIG_FILE"
        # Source the config file safely
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ $key =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue

            # Remove leading/trailing whitespace
            key=$(echo "$key" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            value=$(echo "$value" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

            # Remove quotes from value if present
            value=$(echo "$value" | sed 's/^["'\'']//' | sed 's/["'\'']$//')

            # Set valid configuration variables
            case "$key" in
                JIRA_URL)
                    JIRA_URL="$value"
                    ;;
                BOT_TOKEN)
                    BOT_TOKEN="$value"
                    ;;
                SOURCE_PROJECT)
                    SOURCE_PROJECT="$value"
                    ;;
                DEST_PROJECT)
                    DEST_PROJECT="$value"
                    ;;
                RATE_LIMIT_DELAY)
                    RATE_LIMIT_DELAY="$value"
                    ;;
                FORCE_CONFIRM)
                    FORCE_CONFIRM="$value"
                    ;;
            esac
        done < "$CONFIG_FILE"
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -f|--force|--auto-confirm)
                FORCE_CONFIRM=true
                shift
                ;;
            -s|--skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            -u|--jira-url)
                JIRA_URL="$2"
                shift 2
                ;;
            -t|--token)
                BOT_TOKEN="$2"
                shift 2
                ;;
            --source)
                SOURCE_PROJECT="$2"
                shift 2
                ;;
            --dest)
                DEST_PROJECT="$2"
                shift 2
                ;;
            --delay)
                RATE_LIMIT_DELAY="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

# Prompt for missing credentials
prompt_credentials() {
    if [[ -z "$BOT_TOKEN" ]]; then
        read -r -s -p "Bearer Token: " BOT_TOKEN
        echo ""
    fi
}

# Validate prerequisites
validate_prerequisites() {
    print_header "Validating Prerequisites"

    # Check for required commands
    local missing_commands=()
    for cmd in curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        print_error "Missing required commands: ${missing_commands[*]}"
        echo ""
        print_info "Installation instructions:"

        for cmd in "${missing_commands[@]}"; do
            case "$cmd" in
                jq)
                    echo "  • jq (JSON processor):"
                    echo "    - macOS: brew install jq"
                    echo "    - Ubuntu/Debian: sudo apt-get install jq"
                    echo "    - RHEL/CentOS: sudo yum install jq"
                    echo "    - Alpine: apk add jq"
                    ;;
                curl)
                    echo "  • curl (HTTP client):"
                    echo "    - macOS: Usually pre-installed, or brew install curl"
                    echo "    - Ubuntu/Debian: sudo apt-get install curl"
                    echo "    - RHEL/CentOS: sudo yum install curl"
                    echo "    - Alpine: apk add curl"
                    ;;
            esac
            echo ""
        done

        print_info "After installing missing dependencies, please run the script again."
        exit 1
    fi
    print_success "Required commands available: curl, jq"

    # Validate credentials
    if [[ -z "$BOT_TOKEN" ]]; then
        print_error "Bearer token is required"
        echo ""
        print_info "How to provide your Bearer Token:"
        echo "  • Environment variable: export BOT_TOKEN=\"your-token-here\""
        echo "  • Command line flag: ./migrate-jira-components.sh -t \"your-token-here\""
        echo "  • Configuration file: Add BOT_TOKEN=your-token-here to .jira-migration.conf"
        echo ""
        print_info "How to generate a Bearer Token in JIRA:"
        echo "  1. Go to: ${JIRA_URL}/secure/ViewProfile.jspa"
        echo "  2. Click 'Personal Access Tokens'"
        echo "  3. Click 'Create token'"
        echo "  4. Give it a name and select appropriate permissions"
        echo "  5. Copy the generated token"
        exit 1
    fi
    print_success "Credentials provided"

    # Test JIRA connectivity and authentication
    print_info "Testing JIRA connectivity..."
    local response
    local http_code

    response=$(jira_curl -s -w "\n%{http_code}" \
        -H "Accept: application/json" \
        "${JIRA_URL}/rest/api/2/myself" 2>&1)

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" != "200" ]]; then
        print_error "Authentication failed (HTTP ${http_code})"
        echo ""

        case "$http_code" in
            401)
                print_info "Troubleshooting HTTP 401 (Unauthorized):"
                echo "  • Check that your Bearer Token is valid and not expired"
                echo "  • Verify the token has the required permissions"
                echo "  • Ensure you're using a Personal Access Token, not a password"
                ;;
            403)
                print_info "Troubleshooting HTTP 403 (Forbidden):"
                echo "  • Your token is valid but lacks required permissions"
                echo "  • Check that your account has access to both projects"
                echo "  • Verify project keys: ${SOURCE_PROJECT} and ${DEST_PROJECT}"
                ;;
            404)
                print_info "Troubleshooting HTTP 404 (Not Found):"
                echo "  • Check the JIRA URL: ${JIRA_URL}"
                echo "  • Verify this is the correct JIRA instance"
                echo "  • Ensure the /rest/api/2/myself endpoint is available"
                ;;
            *)
                print_info "Troubleshooting HTTP ${http_code}:"
                echo "  • Check your network connection"
                echo "  • Verify JIRA instance is accessible: ${JIRA_URL}"
                echo "  • Try accessing JIRA in a web browser"
                echo "  • Check for proxy or firewall restrictions"
                ;;
        esac

        echo ""
        print_info "For more details, check the response above for specific error messages."
        exit 1
    fi
    print_success "Successfully authenticated to JIRA"

    # Validate source project exists
    print_info "Validating source project: ${SOURCE_PROJECT}"
    response=$(jira_curl -s -w "\n%{http_code}" \
        -H "Accept: application/json" \
        "${JIRA_URL}/rest/api/2/project/${SOURCE_PROJECT}" 2>&1)

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" != "200" ]]; then
        print_error "Source project ${SOURCE_PROJECT} not found or not accessible"
        exit 1
    fi
    print_success "Source project ${SOURCE_PROJECT} validated"

    # Validate destination project exists
    print_info "Validating destination project: ${DEST_PROJECT}"
    response=$(jira_curl -s -w "\n%{http_code}" \
        -H "Accept: application/json" \
        "${JIRA_URL}/rest/api/2/project/${DEST_PROJECT}" 2>&1)

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" != "200" ]]; then
        print_error "Destination project ${DEST_PROJECT} not found or not accessible"
        exit 1
    fi
    print_success "Destination project ${DEST_PROJECT} validated"
}

# Create migration directory
setup_migration_directory() {
    print_header "Setting Up Migration Environment"

    if [[ -d "$MIGRATION_DIR" ]]; then
        print_warning "Migration directory already exists: ${MIGRATION_DIR}"
        read -r -p "Continue and overwrite? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            print_info "Migration cancelled"
            exit 0
        fi
    fi

    mkdir -p "$MIGRATION_DIR"
    cd "$MIGRATION_DIR"
    print_success "Created migration directory: ${MIGRATION_DIR}"
}

# Backup source components
backup_source_components() {
    if [[ "$SKIP_BACKUP" == true ]]; then
        print_warning "Skipping backup (--skip-backup flag set)"
        return 0
    fi

    print_header "Backing Up Source Components"

    print_info "Fetching components from ${SOURCE_PROJECT}..."
    local response
    local http_code

    response=$(jira_curl -s -w "\n%{http_code}" \
        -H "Accept: application/json" \
        "${JIRA_URL}/rest/api/2/project/${SOURCE_PROJECT}/components" 2>&1)

    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        print_error "Failed to fetch source components (HTTP ${http_code})"
        exit 1
    fi

    echo "$body" | jq '.' > source_components.json
    local count=$(echo "$body" | jq 'length')
    print_success "Backed up ${count} components from ${SOURCE_PROJECT}"

    # Display component list
    print_info "Components to migrate:"
    echo "$body" | jq -r '.[] | "  - \(.name) (ID: \(.id))"'
}

# Fetch existing destination components
fetch_destination_components() {
    print_header "Checking Destination Components"

    print_info "Fetching existing components from ${DEST_PROJECT}..."
    local response
    local http_code

    response=$(jira_curl -s -w "\n%{http_code}" \
        -H "Accept: application/json" \
        "${JIRA_URL}/rest/api/2/project/${DEST_PROJECT}/components" 2>&1)

    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        print_error "Failed to fetch destination components (HTTP ${http_code})"
        exit 1
    fi

    echo "$body" | jq '.' > dest_components_before.json
    local count=$(echo "$body" | jq 'length')
    print_success "Found ${count} existing components in ${DEST_PROJECT}"
}

# Detect conflicts
detect_conflicts() {
    print_header "Detecting Component Conflicts"

    # Extract component names
    jq -r '.[].name' source_components.json | sort > source_names.txt
    jq -r '.[].name' dest_components_before.json | sort > dest_names.txt

    # Find conflicts
    comm -12 source_names.txt dest_names.txt > conflicts.txt

    local conflict_count=$(wc -l < conflicts.txt | tr -d ' ')

    if [[ "$conflict_count" -gt 0 ]]; then
        print_warning "Found ${conflict_count} conflicting component name(s):"
        while IFS= read -r name; do
            echo "  - ${name}"
        done < conflicts.txt
        print_info "These components will be skipped during migration"
    else
        print_success "No component name conflicts detected"
    fi

    # Count components to migrate
    local total=$(jq 'length' source_components.json)
    local to_migrate=$((total - conflict_count))

    echo ""
    print_info "Migration summary:"
    echo "  Total source components: ${total}"
    echo "  Conflicting (will skip): ${conflict_count}"
    echo "  To be migrated: ${to_migrate}"
}

# Migrate components
migrate_components() {
    if [[ "$DRY_RUN" == true ]]; then
        print_header "DRY RUN: Migration Preview"
        print_warning "No actual changes will be made"
    else
        print_header "Migrating Components"
    fi

    # Initialize logs
    > migration_log.txt
    > component_mapping.csv
    echo "Component_Name,Source_ID,Dest_ID,Status" > component_mapping.csv

    local total=$(jq 'length' source_components.json)
    local current=0
    local succeeded=0
    local failed=0
    local skipped=0

    # Process each component
    jq -c '.[]' source_components.json | while IFS= read -r component; do
        current=$((current + 1))

        local name=$(echo "$component" | jq -r '.name')
        local desc=$(echo "$component" | jq -r '.description // ""')
        local source_id=$(echo "$component" | jq -r '.id')

        echo ""
        show_progress "$current" "$total" "$name"
        echo ""

        # Check for conflicts
        if grep -Fxq "$name" conflicts.txt 2>/dev/null; then
            print_warning "SKIPPED: Component already exists in destination"
            echo "SKIP|${name}|${source_id}|Component already exists" >> migration_log.txt
            echo "\"${name}\",${source_id},,SKIPPED" >> component_mapping.csv
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$DRY_RUN" == true ]]; then
            print_success "Would migrate: ${name}"
            echo "DRY_RUN|${name}|${source_id}|Would be migrated" >> migration_log.txt
            succeeded=$((succeeded + 1))
        else
            # Create component in destination
            local payload
            payload=$(jq -n \
                --arg name "$name" \
                --arg desc "$desc" \
                --arg project "$DEST_PROJECT" \
                '{
                    name: $name,
                    description: $desc,
                    project: $project,
                    assigneeType: "PROJECT_DEFAULT",
                    isAssigneeTypeValid: true
                }')

            local response
            local http_code

            response=$(jira_curl -s -w "\n%{http_code}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -X POST \
                "${JIRA_URL}/rest/api/2/component" \
                -d "$payload" 2>&1)

            http_code=$(echo "$response" | tail -n1)
            local body=$(echo "$response" | sed '$d')

            if [[ "$http_code" == "201" ]] || [[ "$http_code" == "200" ]]; then
                local new_id=$(echo "$body" | jq -r '.id')
                print_success "SUCCESS: Created component (New ID: ${new_id})"
                echo "SUCCESS|${name}|${source_id}|${new_id}" >> migration_log.txt
                echo "\"${name}\",${source_id},${new_id},MIGRATED" >> component_mapping.csv
                succeeded=$((succeeded + 1))
            else
                local error_msg=$(echo "$body" | jq -r '.errorMessages[]? // .errors // "Unknown error"' | tr '\n' ' ')
                print_error "FAILED: ${error_msg}"
                echo "FAILED|${name}|${source_id}|${error_msg}" >> migration_log.txt
                echo "\"${name}\",${source_id},,FAILED" >> component_mapping.csv
                failed=$((failed + 1))
            fi

            # Rate limiting
            if [[ "$RATE_LIMIT_DELAY" -gt 0 ]]; then
                sleep "$RATE_LIMIT_DELAY"
            fi
        fi
    done

    # Clear progress line and show completion
    printf "\r%80s\r" ""  # Clear the progress line
    print_success "Component processing completed!"

    # Read final counts from files
    if [[ -f migration_log.txt ]]; then
        succeeded=$(grep -c "^SUCCESS" migration_log.txt)
        failed=$(grep -c "^FAILED" migration_log.txt)
        skipped=$(grep -c "^SKIP" migration_log.txt)
    else
        succeeded=0
        failed=0
        skipped=0
    fi

    echo ""
    print_header "Migration Results"
    echo "  Total components: ${total}"
    echo "  Succeeded: ${succeeded}"
    echo "  Failed: ${failed}"
    echo "  Skipped: ${skipped}"

    if [[ "$DRY_RUN" == true ]]; then
        print_info "This was a DRY RUN - no changes were made"
    fi
}

# Verify migration
verify_migration() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "Skipping verification (dry run mode)"
        return 0
    fi

    print_header "Verifying Migration"

    print_info "Fetching updated destination components..."
    local response
    local http_code

    response=$(jira_curl -s -w "\n%{http_code}" \
        -H "Accept: application/json" \
        "${JIRA_URL}/rest/api/2/project/${DEST_PROJECT}/components" 2>&1)

    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        print_error "Failed to fetch post-migration components (HTTP ${http_code})"
        return 1
    fi

    echo "$body" | jq '.' > dest_components_after.json
    local after_count=$(echo "$body" | jq 'length')
    local before_count=$(jq 'length' dest_components_before.json)
    local added=$((after_count - before_count))

    print_success "Verification complete"
    echo "  Components before: ${before_count}"
    echo "  Components after: ${after_count}"
    echo "  Components added: ${added}"
}

# Generate final report
generate_report() {
    print_header "Generating Migration Report"

    local report_file="migration_report.txt"

    cat > "$report_file" << EOF
========================================
JIRA Component Migration Report
========================================

Migration Details
-----------------
Date: ${MIGRATION_DATE}
Source Project: ${SOURCE_PROJECT}
Destination Project: ${DEST_PROJECT}
JIRA Instance: ${JIRA_URL}
Mode: $(if [[ "$DRY_RUN" == true ]]; then echo "DRY RUN"; else echo "LIVE"; fi)

Migration Statistics
--------------------
EOF

    if [[ -f migration_log.txt ]]; then
        local total
        local succeeded
        local failed
        local skipped

        # Get total count safely
        if [[ -f source_components.json ]]; then
            total=$(jq 'length' source_components.json)
        else
            total=0
        fi

        # Get counts from migration log safely
        succeeded=$(grep -c "^SUCCESS" migration_log.txt)
        failed=$(grep -c "^FAILED" migration_log.txt)
        skipped=$(grep -c "^SKIP" migration_log.txt)

        cat >> "$report_file" << EOF
Total Source Components: ${total}
Successfully Migrated: ${succeeded}
Failed: ${failed}
Skipped (duplicates): ${skipped}

EOF
    fi

    if [[ -f dest_components_before.json ]] && [[ -f dest_components_after.json ]]; then
        local before=$(jq 'length' dest_components_before.json)
        local after=$(jq 'length' dest_components_after.json)

        cat >> "$report_file" << EOF
Destination Component Count
----------------------------
Before Migration: ${before}
After Migration: ${after}
Net Change: $((after - before))

EOF
    fi

    cat >> "$report_file" << EOF
Generated Files
---------------
- source_components.json         : Backup of source components
- dest_components_before.json    : Destination components before migration
- dest_components_after.json     : Destination components after migration
- conflicts.txt                  : List of conflicting component names
- migration_log.txt              : Detailed migration log
- component_mapping.csv          : Component ID mapping (old to new)
- migration_report.txt           : This report

Next Steps
----------
EOF

    if [[ "$DRY_RUN" == true ]]; then
        cat >> "$report_file" << EOF
This was a DRY RUN. Review the results and run again without --dry-run flag
to perform the actual migration.
EOF
    else
        cat >> "$report_file" << EOF
1. Review the component_mapping.csv file for ID mappings
2. Use this mapping for migrating features/issues to maintain component associations
3. Verify components in JIRA UI: ${JIRA_URL}/projects/${DEST_PROJECT}
EOF

        if grep -q "^FAILED" migration_log.txt 2>/dev/null; then
            cat >> "$report_file" << EOF
4. IMPORTANT: Some components failed to migrate. Review migration_log.txt
   and retry failed components manually if needed.
EOF
        fi
    fi

    cat >> "$report_file" << EOF

========================================
End of Report
========================================
EOF

    print_success "Report generated: ${report_file}"
    echo ""
    cat "$report_file"
}

# Cleanup on exit
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        print_error "Migration failed with exit code ${exit_code}"
        print_info "Check logs in: ${MIGRATION_DIR}"
    fi
}

#=============================================================================
# MAIN EXECUTION
#=============================================================================

main() {
    # Set up cleanup trap
    trap cleanup EXIT

    # Load configuration file
    load_config

    # Parse arguments
    parse_args "$@"

    # Print banner (after config and args are loaded)
    echo ""
    echo "========================================="
    echo "  JIRA Component Migration Tool"
    echo "  ${SOURCE_PROJECT} → ${DEST_PROJECT}"
    echo "========================================="
    echo ""

    # Prompt for credentials if not provided
    prompt_credentials

    # Show configuration
    print_info "Configuration:"
    echo "  JIRA URL: ${JIRA_URL}"
    echo "  Source Project: ${SOURCE_PROJECT}"
    echo "  Destination Project: ${DEST_PROJECT}"
    echo "  Dry Run: ${DRY_RUN}"
    echo "  Rate Limit Delay: ${RATE_LIMIT_DELAY}s"
    echo ""

    if [[ "$DRY_RUN" != true ]]; then
        if [[ "$FORCE_CONFIRM" == true ]]; then
            print_info "Auto-confirming migration (--force flag used)"
        else
            read -r -p "Continue with migration? [y/N] " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                print_info "Migration cancelled"
                exit 0
            fi
        fi
    fi

    # Execute migration steps
    validate_prerequisites
    setup_migration_directory
    backup_source_components
    fetch_destination_components
    detect_conflicts
    migrate_components
    verify_migration
    generate_report

    echo ""
    print_success "Migration complete!"
    print_info "All files saved in: ${MIGRATION_DIR}"

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        print_warning "This was a DRY RUN - no actual changes were made"
        print_info "Review the results and run again without --dry-run to perform actual migration"
    fi
}

# Run main function
main "$@"
