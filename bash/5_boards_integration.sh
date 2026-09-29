#!/usr/bin/env bash
# Azure Boards Integration - Links Boards work items to migrated GitHub repos
# Requires: ADO_PAT, GH_PAT, repos_with_status.csv
# Exit codes: 0=success, 1=failure

set -euo pipefail

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters for summary
TOTAL_REPOS=0
SUCCESSFUL_INTEGRATIONS=0
FAILED_INTEGRATIONS=0

# Log file
LOG_FILE="azure-boards-integration-$(date +%Y%m%d-%H%M%S).log"

################################################################################
# Logging Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${YELLOW}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_section() {
    echo "" | tee -a "$LOG_FILE"
    echo "==========================================================================" | tee -a "$LOG_FILE"
    echo -e "${BLUE}$1${NC}" | tee -a "$LOG_FILE"
    echo "==========================================================================" | tee -a "$LOG_FILE"
}

################################################################################
# Validation Functions
################################################################################

validate_prerequisites() {
    log_section "VALIDATING PREREQUISITES"
    
    # Check if repos_with_status.csv exists
    if [ ! -f "repos_with_status.csv" ]; then
        log_error "repos_with_status.csv not found"
        log_error "Make sure Stage 3 (Migration) completed successfully and published repos_with_status.csv"
        echo "##[error]repos_with_status.csv not found - Stage 3 migration may have failed"
        exit 1
    fi
    log_success "repos_with_status.csv found"
    
    # Check if any repos succeeded migration
    local success_count
    success_count=$(tail -n +2 "repos_with_status.csv" | grep -c ",Success$" || true)
    if [ "$success_count" -eq 0 ]; then
        log_warning "No successfully migrated repositories found"
        log_warning "All repositories failed migration. Skipping boards integration."
        echo "##[warning]No successfully migrated repositories - skipping boards integration"
        echo "Skipping Azure Boards integration as all repositories failed migration"
        exit 0
    fi
    log_success "Found $success_count successfully migrated repositories"
    
    # Check for required environment variables
    if [ -z "${ADO_PAT:-}" ]; then
        log_error "ADO_PAT environment variable is not set"
        echo "##[error]ADO_PAT environment variable is not set"
        exit 1
    fi
    log_success "ADO_PAT is set"
    
    if [ -z "${GH_PAT:-}" ]; then
        log_error "GH_PAT environment variable is not set"
        echo "##[error]GH_PAT environment variable is not set"
        exit 1
    fi
    log_success "GH_PAT is set"
    
    # Check if gh CLI is installed
    if ! command -v gh &> /dev/null; then
        log_error "gh CLI is not installed"
        exit 1
    fi
    log_success "gh CLI is installed: $(gh --version | head -n 1)"
}

################################################################################
# Azure Boards Integration
################################################################################

integrate_azure_boards() {
    local ado_org="$1"
    local ado_project="$2"
    local github_org="$3"
    local github_repo="$4"
    
    log_info "Integrating Azure Boards for ${github_org}/${github_repo}"
    
    # Set environment variables for gh CLI
    export GH_TOKEN="${GH_PAT}"
    export ADO_TOKEN="${ADO_PAT}"
    
    # Capture output to display and log
    local temp_output=$(mktemp)
    local temp_error=$(mktemp)
    
    # Execute gh ado2gh integrate-boards command
    log_info "Running: gh ado2gh integrate-boards..."
    
    if gh ado2gh integrate-boards \
        --github-org "${github_org}" \
        --github-repo "${github_repo}" \
        --ado-org "${ado_org}" \
        --ado-team-project "${ado_project}" \
        > "$temp_output" 2> "$temp_error"; then
        
        # Display and log the output
        local command_output=$(cat "$temp_output" "$temp_error")
        if [ -n "$command_output" ]; then
            echo "$command_output" | tee -a "$LOG_FILE"
        fi
        
        log_success "Azure Boards integration completed for ${github_org}/${github_repo}"
        rm -f "$temp_output" "$temp_error"
        return 0
    else
        # Display and log the error output
        local error_output=$(cat "$temp_error" "$temp_output")
        if [ -n "$error_output" ]; then
            echo "$error_output" | tee -a "$LOG_FILE"
        fi
        
        # Check if error is due to invalid authorization scheme
        if echo "$error_output" | grep -q "authorization scheme is invalid" 2>/dev/null; then
            log_error "Azure Boards integration failed: Invalid/stale service connection detected"
            log_error ""
            log_error "═══════════════════════════════════════════════════════════════════"
            log_error "  ACTION REQUIRED: Remove Stale Service Connection"
            log_error "═══════════════════════════════════════════════════════════════════"
            log_error ""
            log_error "A service connection already exists but has invalid authorization."
            log_error "This typically happens when:"
            log_error "  • GitHub App installation token expired"
            log_error "  • Previous integration was incomplete"
            log_error ""
            log_error "To fix:"
            log_error "  1. Open: https://dev.azure.com/${ado_org}/${ado_project}/_settings/adminservices"
            log_error "  2. Find service connection for GitHub repo: ${github_org}/${github_repo}"
            log_error "  3. Click the connection and select 'Delete'"
            log_error "  4. Re-run this pipeline to create a fresh connection"
            log_error ""
            log_error "Alternatively, edit the connection and re-authorize the GitHub App."
            log_error "═══════════════════════════════════════════════════════════════════"
            log_error ""
        else
            log_error "Azure Boards integration failed for ${github_org}/${github_repo}"
            log_error "Check the log file for details: $LOG_FILE"
        fi
        rm -f "$temp_output" "$temp_error"
        return 1
    fi
}

################################################################################
# Main Processing Logic
################################################################################

process_repositories() {
    log_section "PROCESSING REPOSITORIES FROM repos_with_status.csv"
    
    local line_number=0
    
    while IFS=',' read -r ado_org ado_team_project ado_repo github_org github_repo gh_repo_visibility migration_status; do
        : $((line_number++))
        
        # Skip header row
        if [ $line_number -eq 1 ]; then
            continue
        fi
        
        # Skip empty lines or lines with missing required fields
        if [ -z "$ado_org" ] || [ -z "$ado_team_project" ] || [ -z "$github_org" ] || [ -z "$github_repo" ]; then
            continue
        fi
        
        # Skip repositories that failed migration
        if [ "$migration_status" != "Success" ]; then
            log_warning "⏭️  Skipping $ado_repo (Migration Status: $migration_status)"
            continue
        fi
        
        TOTAL_REPOS=$((TOTAL_REPOS + 1))
        
        log_section "Repository $TOTAL_REPOS: ${github_org}/${github_repo}"
        log_info "ADO Org: ${ado_org}"
        log_info "ADO Project: ${ado_team_project}"
        log_info "GitHub Org: ${github_org}"
        log_info "GitHub Repo: ${github_repo}"
        
        # Execute Azure Boards integration
        if integrate_azure_boards "$ado_org" "$ado_team_project" "$github_org" "$github_repo"; then
            SUCCESSFUL_INTEGRATIONS=$((SUCCESSFUL_INTEGRATIONS + 1))
        else
            FAILED_INTEGRATIONS=$((FAILED_INTEGRATIONS + 1))
        fi
        
        echo "" | tee -a "$LOG_FILE"
        
    done < repos_with_status.csv
}

################################################################################
# Summary Report
################################################################################

print_summary() {
    log_section "AZURE BOARDS INTEGRATION SUMMARY"
    
    echo "" | tee -a "$LOG_FILE"
    echo "Total Repositories Processed:    ${TOTAL_REPOS}" | tee -a "$LOG_FILE"
    echo "Successful Integrations:         ${SUCCESSFUL_INTEGRATIONS}" | tee -a "$LOG_FILE"
    echo "Failed Integrations:             ${FAILED_INTEGRATIONS}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Log file: ${LOG_FILE}" | tee -a "$LOG_FILE"
    echo "==========================================================================" | tee -a "$LOG_FILE"
    
    # Handle integration results
    if [ $TOTAL_REPOS -eq 0 ]; then
        log_error "No repositories were processed"
        echo "##[error]Azure Boards integration: No repositories found to process - all migrations may have failed"
        exit 1
    elif [ $SUCCESSFUL_INTEGRATIONS -eq 0 ]; then
        log_error "All $FAILED_INTEGRATIONS repositories failed boards integration"
        echo "##[error]All repositories failed Azure Boards integration"
        exit 1
    elif [ $FAILED_INTEGRATIONS -gt 0 ]; then
        log_warning "Azure Boards integration completed with issues"
        echo "##[warning]⚠️ Boards integration completed with PARTIAL SUCCESS: $SUCCESSFUL_INTEGRATIONS succeeded, $FAILED_INTEGRATIONS failed"
        echo "##vso[task.logissue type=warning]Partial success: $SUCCESSFUL_INTEGRATIONS succeeded, $FAILED_INTEGRATIONS failed"
        
        # Set task result to SucceededWithIssues and exit successfully
        echo "##vso[task.complete result=SucceededWithIssues]Boards integration completed with partial success"
        exit 0
    else
        log_success "Azure Boards integration completed successfully!"
        echo "##[section]✅ All $SUCCESSFUL_INTEGRATIONS repositories integrated successfully with Azure Boards"
        exit 0
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    log_section "AZURE BOARDS INTEGRATION - ADO TO GHE"
    log_info "Script started at: $(date)"
    log_info "Log file: ${LOG_FILE}"
    
    validate_prerequisites
    process_repositories
    print_summary
    
    log_info "Script completed at: $(date)"
}

# Execute main function
main
