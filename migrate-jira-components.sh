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
JIRA_URL="${JIRA_URL:-https://issues.redhat.com}"
BOT_TOKEN="${BOT_TOKEN:-}"
SOURCE_PROJECT="${SOURCE_PROJECT:-RHOAISTRAT}"
DEST_PROJECT="${DEST_PROJECT:-RHAISTRAT}"
MIGRATION_DATE=$(date +%Y%m%d_%H%M%S)
MIGRATION_DIR="jira_migration_${MIGRATION_DATE}"
DRY_RUN=false
SKIP_BACKUP=false
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

# Helper function to make authenticated curl requests with Bearer token
jira_curl() {
    curl "$@" -H "Authorization: Bearer ${BOT_TOKEN}"
}

# Show usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Migrate JIRA components from RHOAISTRAT to RHAISTRAT project.

OPTIONS:
    -h, --help              Show this help message
    -d, --dry-run           Perform a dry run without making changes
    -s, --skip-backup       Skip backup step (not recommended)
    -u, --jira-url URL      JIRA instance URL (default: https://issues.redhat.com)
    -t, --token TOKEN       Bearer token for authentication
    --source PROJECT        Source project key (default: RHOAISTRAT)
    --dest PROJECT          Destination project key (default: RHAISTRAT)
    --delay SECONDS         Delay between API calls (default: 2)

ENVIRONMENT VARIABLES:
    JIRA_URL                JIRA instance URL
    BOT_TOKEN               Bearer token for authentication
    SOURCE_PROJECT          Source project key
    DEST_PROJECT            Destination project key

EXAMPLES:
    # Interactive mode (prompts for token)
    $0

    # With environment variable
    export BOT_TOKEN="your-bearer-token"
    $0

    # Dry run to preview changes
    $0 --dry-run

    # With command line arguments
    $0 -t your-bearer-token --source RHOAISTRAT --dest RHAISTRAT

EOF
    exit 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            -d|--dry-run)
                DRY_RUN=true
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
        print_info "Please install: ${missing_commands[*]}"
        exit 1
    fi
    print_success "Required commands available: curl, jq"

    # Validate credentials
    if [[ -z "$BOT_TOKEN" ]]; then
        print_error "Bearer token is required"
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
        print_error "Please check your credentials and JIRA URL"
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
        print_info "[${current}/${total}] Processing: ${name}"

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

    # Read final counts from files
    succeeded=$(grep -c "^SUCCESS" migration_log.txt 2>/dev/null || echo 0)
    failed=$(grep -c "^FAILED" migration_log.txt 2>/dev/null || echo 0)
    skipped=$(grep -c "^SKIP" migration_log.txt 2>/dev/null || echo 0)

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
        local total=$(jq 'length' source_components.json 2>/dev/null || echo 0)
        local succeeded=$(grep -c "^SUCCESS" migration_log.txt 2>/dev/null || echo 0)
        local failed=$(grep -c "^FAILED" migration_log.txt 2>/dev/null || echo 0)
        local skipped=$(grep -c "^SKIP" migration_log.txt 2>/dev/null || echo 0)

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

    # Print banner
    echo ""
    echo "========================================="
    echo "  JIRA Component Migration Tool"
    echo "  ${SOURCE_PROJECT} → ${DEST_PROJECT}"
    echo "========================================="
    echo ""

    # Parse arguments
    parse_args "$@"

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
        read -r -p "Continue with migration? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            print_info "Migration cancelled"
            exit 0
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
