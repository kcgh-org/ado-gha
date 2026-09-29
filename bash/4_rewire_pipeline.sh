#!/usr/bin/env bash
set -euo pipefail

# Copyright (c) 2025 Vamsi Cherukuri, Microsoft
# 
# MIT License
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Verify GitHub CLI is available
if ! command -v gh &> /dev/null; then
    echo "ERROR: GitHub CLI (gh) not found. Please install it first."
    exit 1
fi

# ADO2GH: Rewire Pipelines
# 
# Description:
#   Rewires Azure DevOps pipelines to GitHub repositories.
#   Reads pipeline information from pipelines.csv and executes rewiring for each pipeline.
#
# Prerequisites:
#   - ADO_PAT and GH_PAT environment variables set
#   - pipelines.csv with required columns: org, teamproject, pipeline, github_org, github_repo, serviceConnection
#
# Usage:
#   ./4_rewire_pipeline.sh
#
# Workflow:
#   [Step 1] Validate PAT tokens (ADO_PAT and GH_PAT)
#   [Step 2] Validate pipelines.csv file and required columns
#   [Step 3] Validate service connection IDs (no placeholders)
#   [Step 4] Execute pipeline rewiring
#   [Step 5] Generate summary and log file

# --- Configuration ---

PIPELINES_FILE="pipelines.csv"
REQUIRED_COLUMNS=("org" "teamproject" "pipeline" "github_org" "github_repo" "serviceConnection")
PLACEHOLDER_VALUES=("your-service-connection-id" "placeholder" "TODO" "TBD" "xxx" "")
DETAILED_LOG=$(mktemp)

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# Counters
SUCCESS_COUNT=0
FAILURE_COUNT=0
ALREADY_MIGRATED_COUNT=0
SKIPPED_COUNT=0
SKIPPED_REWIRING_COUNT=0
declare -a RESULTS=()
declare -a FAILED_DETAILS=()
declare -a ALREADY_MIGRATED_DETAILS=()
declare -a SKIPPED_DETAILS=()
declare -a SKIPPED_REWIRING=()
declare -A MIGRATED_REPOS=()  # Track successfully migrated repos

# --- Helper Functions ---

# Load repos_with_status.csv to filter pipelines
load_migrated_repos() {
    local repos_status_csv="repos_with_status.csv"
    
    if [ ! -f "$repos_status_csv" ]; then
        echo -e "${RED}❌ ERROR: repos_with_status.csv not found${NC}"
        echo -e "${YELLOW}   Make sure Stage 3 (Migration) completed successfully${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Loading successfully migrated repositories...${NC}"
    
    # Read repos_with_status.csv and track Success repos
    while IFS=',' read -r org teamproject repo github_org github_repo visibility status; do
        # Remove quotes and whitespace
        repo=$(echo "$repo" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        status=$(echo "$status" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ "$status" = "Success" ]; then
            MIGRATED_REPOS["$repo"]=1
        fi
    done < <(tail -n +2 "$repos_status_csv")
    
    echo -e "${GREEN}✅ Loaded ${#MIGRATED_REPOS[@]} successfully migrated repositories${NC}"
    
    # Debug: Show which repos were loaded
    if [ ${#MIGRATED_REPOS[@]} -gt 0 ]; then
        echo -e "${GRAY}   Successfully migrated repos:${NC}"
        for repo_name in "${!MIGRATED_REPOS[@]}"; do
            echo -e "${GRAY}     • '$repo_name'${NC}"
        done
    fi
    
    # Skip gracefully if no repos migrated successfully
    if [ ${#MIGRATED_REPOS[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠️ WARNING: No successfully migrated repositories found${NC}"
        echo -e "${YELLOW}   All repositories failed migration. Skipping rewiring.${NC}"
        echo "##[warning]No successfully migrated repositories to rewire - skipping rewiring stage"
        echo "Skipping pipeline rewiring as all repositories failed migration"
        exit 0
    fi
}

# Function to parse CSV line properly (handles quoted fields)
parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next
  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"
    if [[ "${char}" == '"' ]]; then
      if [[ "${in_quotes}" == true ]]; then
        if [[ "${next}" == '"' ]]; then
          field+='"'; ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "${char}" == ',' && "${in_quotes}" == false ]]; then
      fields+=("${field}")
      field=""
    else
      field+="${char}"
    fi
  done
  fields+=("${field}")
  printf '%s\n' "${fields[@]}"
}

# ========================================
# MAIN SCRIPT
# ========================================
echo -e "\n${CYAN}========================================${NC}"
echo -e "${CYAN}  ADO2GH: Rewire Pipelines${NC}"
echo -e "${CYAN}========================================${NC}\n"

# Load successfully migrated repositories first
load_migrated_repos

# ========================================
# STEP 1: Validate PAT Tokens
# ========================================
echo -e "${YELLOW}[Step 1/4] Validating PAT tokens...${NC}"

if [ -z "$ADO_PAT" ]; then
    echo -e "${RED}❌ ERROR: ADO_PAT environment variable is not set${NC}"
    exit 1
fi

if [ -z "$GH_PAT" ]; then
    echo -e "${RED}❌ ERROR: GH_PAT environment variable is not set${NC}"
    exit 1
fi

echo -e "${GREEN}✅ PAT tokens validated${NC}"

# ========================================
# STEP 2: Validate pipelines.csv File
# ========================================
echo -e "\n${YELLOW}[Step 2/4] Validating pipelines.csv file...${NC}"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_PATH="$SCRIPT_DIR/$PIPELINES_FILE"

# Check file exists
if [ ! -f "$CSV_PATH" ]; then
    echo -e "${RED}❌ ERROR: Pipeline file not found: $CSV_PATH${NC}"
    echo -e "${YELLOW}   Please ensure pipelines.csv exists in the current directory${NC}"
    exit 1
fi

# Load CSV and count lines
TOTAL_LINES=$(wc -l < "$CSV_PATH")
PIPELINE_COUNT=$((TOTAL_LINES - 1))  # Subtract header

if [ $PIPELINE_COUNT -eq 0 ]; then
    echo -e "${YELLOW}⚠️  No pipelines found in CSV file${NC}"
    echo -e "${GRAY}   Nothing to process. Exiting.${NC}"
    exit 0
fi

echo -e "${GREEN}✅ File loaded: $PIPELINE_COUNT pipeline(s) found${NC}"

# ========================================
# STEP 3: Validate Required Columns
# ========================================
echo -e "\n${YELLOW}[Step 3/4] Validating CSV columns and data...${NC}"

# Read header and validate columns
IFS=',' read -ra CSV_COLUMNS <<< "$(head -n 1 "$CSV_PATH")"

# Remove quotes and whitespace from column names
for i in "${!CSV_COLUMNS[@]}"; do
    CSV_COLUMNS[$i]=$(echo "${CSV_COLUMNS[$i]}" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
done

# Check for missing columns
MISSING_COLUMNS=()
for req_col in "${REQUIRED_COLUMNS[@]}"; do
    found=false
    for csv_col in "${CSV_COLUMNS[@]}"; do
        if [ "$csv_col" = "$req_col" ]; then
            found=true
            break
        fi
    done
    if [ "$found" = "false" ]; then
        MISSING_COLUMNS+=("$req_col")
    fi
done

if [ ${#MISSING_COLUMNS[@]} -gt 0 ]; then
    echo -e "${RED}❌ ERROR: CSV is missing required columns: ${MISSING_COLUMNS[*]}${NC}"
    echo -e "${YELLOW}   Required columns: ${REQUIRED_COLUMNS[*]}${NC}"
    echo -e "${GRAY}   Found columns: ${CSV_COLUMNS[*]}${NC}"
    exit 1
fi

echo -e "${GREEN}✅ All required columns present${NC}"

# Get column indices
declare -A COL_INDEX
for i in "${!CSV_COLUMNS[@]}"; do
    COL_INDEX["${CSV_COLUMNS[$i]}"]=$i
done

# Validate service connection IDs
echo -e "${GRAY}   Validating service connection IDs...${NC}"
INVALID_ROWS=()
ROW_NUM=1

while IFS= read -r line; do
    ROW_NUM=$((ROW_NUM + 1))
    
    # Parse CSV line
    IFS=',' read -ra fields <<< "$line"
    
    # Remove quotes
    for i in "${!fields[@]}"; do
        fields[$i]=$(echo "${fields[$i]}" | sed 's/^"//;s/"$//')
    done
    
    # Get service connection ID
    SERVICE_CONN_ID="${fields[${COL_INDEX["serviceConnection"]}]}"
    PIPELINE_NAME="${fields[${COL_INDEX["pipeline"]}]}"
    
    # Check if empty or placeholder
    if [ -z "$SERVICE_CONN_ID" ]; then
        INVALID_ROWS+=("Row $ROW_NUM: $PIPELINE_NAME - Empty service connection ID")
    else
        for placeholder in "${PLACEHOLDER_VALUES[@]}"; do
            if [ "$SERVICE_CONN_ID" == "$placeholder" ]; then
                INVALID_ROWS+=("Row $ROW_NUM: $PIPELINE_NAME - Placeholder value: '$SERVICE_CONN_ID'")
                break
            fi
        done
    fi
done < <(tail -n +2 "$CSV_PATH")

if [ ${#INVALID_ROWS[@]} -gt 0 ]; then
    echo -e "\n${RED}❌ ERROR: Invalid service connection IDs found${NC}"
    echo -e "${YELLOW}   The following rows have issues:\n${NC}"
    
    for invalid in "${INVALID_ROWS[@]}"; do
        echo -e "${YELLOW}      $invalid${NC}"
    done
    
    echo -e "\n${CYAN}   💡 How to fix:${NC}"
    echo -e "${GRAY}      1. Go to Azure DevOps → Project Settings → Service Connections${NC}"
    echo -e "${GRAY}      2. Find your GitHub service connection${NC}"
    echo -e "${GRAY}      3. Copy the connection ID (GUID format)${NC}"
    echo -e "${GRAY}      4. Update the 'serviceConnection' column in pipelines.csv${NC}"
    exit 1
fi

echo -e "${GREEN}✅ All service connection IDs validated${NC}"

# ========================================
# STEP 4: Rewire Pipelines
# ========================================
echo -e "\n${YELLOW}[Step 4/4] Rewiring pipelines to GitHub...${NC}"

while IFS= read -r line; do
    # Parse CSV line
    IFS=',' read -ra fields <<< "$line"
    
    # Remove quotes
    for i in "${!fields[@]}"; do
        fields[$i]=$(echo "${fields[$i]}" | sed 's/^"//;s/"$//')
    done
    
    # Extract fields
    ADO_ORG="${fields[${COL_INDEX["org"]}]}"
    ADO_PROJECT="${fields[${COL_INDEX["teamproject"]}]}"
    ADO_REPO="${fields[${COL_INDEX["repo"]}]}"
    ADO_PIPELINE="${fields[${COL_INDEX["pipeline"]}]}"
    GITHUB_ORG="${fields[${COL_INDEX["github_org"]}]}"
    GITHUB_REPO="${fields[${COL_INDEX["github_repo"]}]}"
    SERVICE_CONNECTION_ID="${fields[${COL_INDEX["serviceConnection"]}]}"
    
    # Debug: Show what we're checking
    echo -e "\n${GRAY}   🔍 Checking pipeline: $ADO_PIPELINE (repo: '$ADO_REPO')${NC}"
    
    # Check if repo successfully migrated (safe check for associative array)
    if [ -z "${MIGRATED_REPOS[$ADO_REPO]+x}" ]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo -e "${YELLOW}   ⏭️  Skipping: $ADO_PIPELINE${NC}"
        echo -e "${GRAY}      Reason: Repository '$ADO_REPO' failed migration (not in repos_with_status.csv as Success)${NC}"
        SKIPPED_DETAILS+=("$ADO_PROJECT/$ADO_PIPELINE: Repository '$ADO_REPO' not found in repos_with_status.csv or migration failed")
        continue
    fi
    
    echo -e "\n${CYAN}   🔄 Processing: $ADO_PIPELINE${NC}"
    echo -e "${GRAY}      ADO: $ADO_ORG/$ADO_PROJECT${NC}"
    echo -e "${GRAY}      GitHub: $GITHUB_ORG/$GITHUB_REPO${NC}"
    echo -e "${GRAY}      Service Connection: $SERVICE_CONNECTION_ID${NC}"
    
    # Capture output and error from gh ado2gh rewire-pipeline
    OUTPUT_FILE=$(mktemp)
    ERROR_FILE=$(mktemp)
    
    # Show command being executed
    echo -e "${GRAY}      Running: gh ado2gh rewire-pipeline...${NC}"
    
    if gh ado2gh rewire-pipeline \
        --ado-org "$ADO_ORG" \
        --ado-team-project "$ADO_PROJECT" \
        --ado-pipeline "$ADO_PIPELINE" \
        --github-org "$GITHUB_ORG" \
        --github-repo "$GITHUB_REPO" \
        --service-connection-id "$SERVICE_CONNECTION_ID" > "$OUTPUT_FILE" 2> "$ERROR_FILE"; then
        
        # Check if already on GitHub (detect from output/warnings)
        OUTPUT_CONTENT=$(cat "$OUTPUT_FILE" "$ERROR_FILE")

         # CATCH HIDDEN ERRORS (400, 403, 500, etc.)
        # If the output contains "Response status code does not indicate success"
        if echo "$OUTPUT_CONTENT" | grep -qi "does not indicate success"; then
            SKIPPED_REWIRING_COUNT=$((SKIPPED_REWIRING_COUNT + 1))
            ERROR_EXTRACT=$(echo "$OUTPUT_CONTENT" | grep -oE "[0-9]{3} \(.*\)")
            echo -e "${RED}      ⚠️ WARNING: API FAILED - $ERROR_EXTRACT ${NC}"
            echo "$OUTPUT_CONTENT"
            # This adds a record to the "Issues" summary at the top of the ADO page
            echo "##vso[task.logissue type=warning]Pipeline $ADO_PIPELINE failed with $ERROR_EXTRACT"

            
            
            RESULTS+=("⚠️ WARNING | $ADO_PROJECT/$ADO_PIPELINE ($ERROR_EXTRACT)")
            SKIPPED_REWIRING+=("⚠️ $ADO_PROJECT/$ADO_PIPELINE: $ERROR_EXTRACT") 
            continue 
        fi
        
        # Display and save the verbose output to console and log
        if [ -n "$OUTPUT_CONTENT" ]; then
            echo -e "${GRAY}      --- Command Output ---${NC}"
            echo "$OUTPUT_CONTENT" | sed 's/^/      /' | tee -a "$DETAILED_LOG"
            echo -e "${GRAY}      ---------------------${NC}"
        fi
        
        if echo "$OUTPUT_CONTENT" | grep -qi "repository.*type.*GitHub\|already.*github\|404.*Not Found"; then
            ALREADY_MIGRATED_COUNT=$((ALREADY_MIGRATED_COUNT + 1))
            echo -e "${YELLOW}      ⚠️  ALREADY ON GITHUB (No rewiring needed)${NC}"
            echo "##[warning]Pipeline '$ADO_PROJECT/$ADO_PIPELINE' already points to GitHub repository. No rewiring needed."
            
            # Extract relevant warning message
            WARNING_MSG=$(echo "$OUTPUT_CONTENT" | grep -i "warning\|404\|Not Found" | head -n 1)
            if [ -z "$WARNING_MSG" ]; then
                WARNING_MSG="Pipeline repository type is already 'GitHub'"
            fi
            
            RESULTS+=("⚠️  ALREADY ON GITHUB | $ADO_PROJECT/$ADO_PIPELINE → $GITHUB_ORG/$GITHUB_REPO")
            ALREADY_MIGRATED_DETAILS+=("$ADO_PROJECT/$ADO_PIPELINE: $WARNING_MSG")
        else
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo -e "${GREEN}      ✅ SUCCESS${NC}"
            RESULTS+=("✅ SUCCESS | $ADO_PROJECT/$ADO_PIPELINE → $GITHUB_ORG/$GITHUB_REPO")
        fi
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        echo -e "${RED}      ❌ FAILED${NC}"
        
        # Capture error message
        ERROR_CONTENT=$(cat "$ERROR_FILE" "$OUTPUT_FILE")
        
        # Display and save the error output to console and log
        if [ -n "$ERROR_CONTENT" ]; then
            echo -e "${RED}      --- Error Output ---${NC}"
            echo "$ERROR_CONTENT" | sed 's/^/      /' | tee -a "$DETAILED_LOG"
            echo -e "${RED}      --------------------${NC}"
        fi
        
        ERROR_MSG=$(echo "$ERROR_CONTENT" | grep -i "error\|fail\|exception" | head -n 3 | tr '\n' ' ')
        if [ -z "$ERROR_MSG" ]; then
            ERROR_MSG="Unknown error during pipeline rewiring"
        fi
        
        echo -e "${RED}      Summary: $ERROR_MSG${NC}"
        echo "##[error]Failed to rewire pipeline: $ADO_PROJECT/$ADO_PIPELINE - $ERROR_MSG"
        RESULTS+=("❌ FAILED | $ADO_PROJECT/$ADO_PIPELINE → $GITHUB_ORG/$GITHUB_REPO")
        FAILED_DETAILS+=("$ADO_PROJECT/$ADO_PIPELINE: $ERROR_MSG")
    fi
    
    # Cleanup temp files
    rm -f "$OUTPUT_FILE" "$ERROR_FILE"
    
    sleep 1
    
done < <(tail -n +2 "$CSV_PATH")

# ========================================
# STEP 5: Generate Summary and Log
# ========================================
echo -e "\n${CYAN}========================================${NC}"
echo -e "${CYAN}  Pipeline Rewiring Summary${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "Total Pipelines: $PIPELINE_COUNT"
echo -e "${GREEN}Successful: $SUCCESS_COUNT${NC}"
echo -e "${YELLOW}Already on GitHub: $ALREADY_MIGRATED_COUNT${NC}"
echo -e "${YELLOW}Skipped (repo not migrated): $SKIPPED_COUNT${NC}"
echo -e "${YELLOW}Skipped (rewiring incomplete): $SKIPPED_REWIRING_COUNT${NC}"
echo -e "${RED}Failed: $FAILURE_COUNT${NC}"

echo -e "\n${CYAN}📋 Detailed Results:${NC}"
for result in "${RESULTS[@]}"; do
    echo -e "${GRAY}   $result${NC}"
done

# Show details for already migrated pipelines
if [ -n "${ALREADY_MIGRATED_DETAILS+x}" ] && [ ${#ALREADY_MIGRATED_DETAILS[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}⚠️  Already on GitHub (No rewiring needed):${NC}"
    for detail in "${ALREADY_MIGRATED_DETAILS[@]}"; do
        echo -e "${GRAY}   • $detail${NC}"
    done
fi

# Show details for skipped pipelines
if [ -n "${SKIPPED_DETAILS+x}" ] && [ ${#SKIPPED_DETAILS[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}⏭️  Skipped (Repository not migrated):${NC}"
    for detail in "${SKIPPED_DETAILS[@]}"; do
        echo -e "${GRAY}   • $detail${NC}"
    done
fi

# Show details for skipped rewiring
if [ -n "${SKIPPED_REWIRING+x}" ] && [ ${#SKIPPED_REWIRING[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}⏭️  Skipped (rewiring incomplete):${NC}"
    for detail in "${SKIPPED_REWIRING[@]}"; do
        echo -e "${GRAY}   • $detail${NC}"
    done
fi

# Show details for failed pipelines
if [ -n "${FAILED_DETAILS+x}" ] && [ ${#FAILED_DETAILS[@]} -gt 0 ]; then
    echo -e "\n${RED}❌ Failed Pipelines:${NC}"
    for detail in "${FAILED_DETAILS[@]}"; do
        echo -e "${GRAY}   • $detail${NC}"
    done
fi

# Generate log file
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
LOG_FILE="pipeline-rewiring-$(date "+%Y%m%d-%H%M%S").txt"

cat > "$LOG_FILE" << EOF
Pipeline Rewiring Log - $TIMESTAMP
========================================
Total Pipelines: $PIPELINE_COUNT
Successful: $SUCCESS_COUNT
Already on GitHub: $ALREADY_MIGRATED_COUNT
Skipped (repo not migrated): $SKIPPED_COUNT
skipped (rewiring incomplete): $SKIPPED_REWIRING_COUNT
Failed: $FAILURE_COUNT

Detailed Results:
$(if [ "${#RESULTS[@]}" -gt 0 ] 2>/dev/null; then printf '%s\n' "${RESULTS[@]}"; else echo "None"; fi)

Already on GitHub Details:
$(if [ "${#ALREADY_MIGRATED_DETAILS[@]}" -gt 0 ] 2>/dev/null; then printf '%s\n' "${ALREADY_MIGRATED_DETAILS[@]}"; else echo "None"; fi)

Skipped Pipeline Details (Repository not migrated):
$(if [ "${#SKIPPED_DETAILS[@]}" -gt 0 ] 2>/dev/null; then printf '%s\n' "${SKIPPED_DETAILS[@]}"; else echo "None"; fi)

Skipped Pipeline Details (Rewiring incomplete):
$(if [ "${#SKIPPED_REWIRING[@]}" -gt 0 ] 2>/dev/null; then printf '%s\n' "${SKIPPED_REWIRING[@]}"; else echo "None"; fi)


Failed Pipeline Details:
$(if [ "${#FAILED_DETAILS[@]}" -gt 0 ] 2>/dev/null; then printf '%s\n' "${FAILED_DETAILS[@]}"; else echo "None"; fi)
========================================

Detailed Command Output:
========================================
EOF

# Append detailed command output if exists
if [ -f "$DETAILED_LOG" ] && [ -s "$DETAILED_LOG" ]; then
    cat "$DETAILED_LOG" >> "$LOG_FILE"
    rm -f "$DETAILED_LOG"
else
    echo "No detailed command output captured" >> "$LOG_FILE"
fi

echo -e "\n${GRAY}📄 Log saved: $LOG_FILE${NC}"

# ========================================
# EXIT WITH APPROPRIATE STATUS
# ========================================

# Determine exit behavior based on the three scenarios
ACTUAL_FAILURES=$FAILURE_COUNT  # Only count real errors, not "already migrated"
ACTUAL_SUCCESSES=$((SUCCESS_COUNT + ALREADY_MIGRATED_COUNT))  # Both are successful outcomes

# Check if ALL pipelines were skipped (no actual work done)
if [ $ACTUAL_SUCCESSES -eq 0 ] && [ $ACTUAL_FAILURES -eq 0 ] && [ $SKIPPED_COUNT -gt 0 ] && [ $SKIPPED_REWIRING_COUNT -gt 0 ]; then
    # All pipelines skipped - show warning
    echo -e "\n${YELLOW}⚠️  All pipelines skipped - no repositories were migrated${NC}"
    echo -e "${YELLOW}   ⏭️  Skipped: $SKIPPED_COUNT${NC}"
    echo -e "${YELLOW}   ⏭️  Skipped: $SKIPPED_REWIRING_COUNT${NC}"
    echo "##[warning]⚠️ All $SKIPPED_COUNT pipeline(s) skipped because their repositories were not successfully migrated"
    echo "##[warning]⚠️ All $SKIPPED_REWIRING_COUNT pipeline(s) skipped because rewiring is incomplete"
    echo "##vso[task.logissue type=warning]All pipelines skipped - no repositories migrated"
    
    # Show skipped pipeline details
    if [ ${#SKIPPED_DETAILS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Skipped Pipeline Details:${NC}"
        for detail in "${SKIPPED_DETAILS[@]}"; do
            echo "##[warning]  Skipped: $detail"
        done
    fi

    # Show skipped rewiirng details
    if [ ${#SKIPPED_REWIRING[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Skipped Pipeline Details:${NC}"
        for detail in "${SKIPPED_REWIRING[@]}"; do
            echo "##[warning]  Skipped: $detail"
        done
    fi
    
    # Set task result to SucceededWithIssues since no work was done
    echo "##vso[task.complete result=SucceededWithIssues]All pipelines skipped - no repositories migrated"
    exit 0

# Downstream stages should not fail completely, only show partial success
elif [ $ACTUAL_FAILURES -eq 0 ]; then
    # All successful (including already migrated)
    if [ $SKIPPED_COUNT -gt 0 ]; then
        # Some succeeded, some skipped
        echo -e "\n${GREEN}✅ Pipeline rewiring completed successfully${NC}"
        echo -e "${GREEN}   ✅ Successful: $SUCCESS_COUNT${NC}"
        if [ $ALREADY_MIGRATED_COUNT -gt 0 ]; then
            echo -e "${YELLOW}   ⚠️  Already on GitHub: $ALREADY_MIGRATED_COUNT${NC}"
        fi
        echo -e "${YELLOW}   ⏭️  Skipped: $SKIPPED_COUNT${NC}"
        echo "##[warning]$SKIPPED_COUNT pipeline(s) skipped because repositories were not migrated"
        
        # Show skipped details
        if [ ${#SKIPPED_DETAILS[@]} -gt 0 ]; then
            echo -e "\n${YELLOW}Skipped Pipeline Details (Repository not migrated):${NC}"
            for detail in "${SKIPPED_DETAILS[@]}"; do
                echo "##[warning]  Skipped: $detail"
            done
        fi
        echo "##vso[task.complete result=SucceededWithIssues]Rewiring completed with $SKIPPED_COUNT skipped pipeline(s)"
        exit 0
    
    elif [ $SKIPPED_REWIRING_COUNT -gt 0 ]; then
        # Some succeeded, some skipped
        echo -e "\n${GREEN}✅ Pipeline rewiring completed successfully${NC}"
        echo -e "${GREEN}   ✅ Successful: $SUCCESS_COUNT${NC}"
        if [ $ALREADY_MIGRATED_COUNT -gt 0 ]; then
            echo -e "${YELLOW}   ⚠️  Already on GitHub: $ALREADY_MIGRATED_COUNT${NC}"
        fi
        echo -e "${YELLOW}   ⏭️  Skipped: $SKIPPED_REWIRING_COUNT${NC}"
        echo "##[warning]$SKIPPED_REWIRING_COUNT pipeline(s) skipped because rewiring is incomplete"

        # Show skipped rewiring
        if [ ${#SKIPPED_REWIRING[@]} -gt 0 ]; then
            echo -e "\n${YELLOW}Skipped Pipeline Details (Rewiring incomplete):${NC}"
            for detail in "${SKIPPED_REWIRING[@]}"; do
                echo "##[warning]  Skipped: $detail"
            done
        fi
        
        echo "##vso[task.complete result=SucceededWithIssues]Rewiring completed with $SKIPPED_REWIRING_COUNT skipped pipeline(s)"
        exit 0
    
    elif [ $ALREADY_MIGRATED_COUNT -gt 0 ]; then
        echo -e "\n${GREEN}✅ Pipeline rewiring completed successfully${NC}"
        echo "##[warning]$ALREADY_MIGRATED_COUNT pipeline(s) already on GitHub - no rewiring needed"
        exit 0
    else
        echo -e "\n${GREEN}✅ All pipelines rewired successfully${NC}"
        exit 0
    fi
    
else
    # Partial success or some failed - downstream stage should continue
    echo -e "\n${YELLOW}⚠️  Pipeline rewiring completed with issues${NC}"
    echo -e "${GREEN}   ✅ Successful: $SUCCESS_COUNT${NC}"
    if [ $ALREADY_MIGRATED_COUNT -gt 0 ]; then
        echo -e "${YELLOW}   ⚠️  Already on GitHub: $ALREADY_MIGRATED_COUNT${NC}"
    fi
    if [ $SKIPPED_COUNT -gt 0 ]; then
        echo -e "${YELLOW}   ⏭️  Skipped: $SKIPPED_COUNT${NC}"
    fi
    if [ $SKIPPED_REWIRING_COUNT -gt 0 ]; then
        echo -e "${YELLOW}   ⏭️  Skipped: $SKIPPED_COUNT${NC}"
    fi
    echo -e "${RED}   ❌ Failed: $FAILURE_COUNT${NC}"
    
    # Output warnings for partial success
    echo "##[warning]⚠️ Rewiring completed with issues: $ACTUAL_SUCCESSES succeeded, $SKIPPED_COUNT skipped,$SKIPPED_REWIRING_COUNT skippedRewiring,$FAILURE_COUNT failed"
    echo "##vso[task.logissue type=warning]Partial success: $ACTUAL_SUCCESSES succeeded, $SKIPPED_COUNT skipped,$SKIPPED_REWIRING_COUNT skippedRewiring, $FAILURE_COUNT failed"
    
    # Show failed pipeline details as warnings
    if [ ${#FAILED_DETAILS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Failed Pipeline Details:${NC}"
        for detail in "${FAILED_DETAILS[@]}"; do
            echo "##[warning]  Failed: $detail"
        done
    fi
    
    # Show skipped pipeline details
    if [ ${#SKIPPED_DETAILS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Skipped Pipeline Details (Repository not migrated):${NC}"
        for detail in "${SKIPPED_DETAILS[@]}"; do
            echo "##[warning]  Skipped: $detail"
        done
    fi

    # Show skipped pipeline rewiring details
    if [ ${#SKIPPED_REWIRING[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Skipped Pipeline Details (rewiring incomplete):${NC}"
        for detail in "${SKIPPED_REWIRING[@]}"; do
            echo "##[warning]  Skipped: $detail"
        done
    fi
    
    # Show already migrated details if any
    if [ ${#ALREADY_MIGRATED_DETAILS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Already on GitHub (No action needed):${NC}"
        for detail in "${ALREADY_MIGRATED_DETAILS[@]}"; do
            echo "##[warning]  Already migrated: $detail"
        done
    fi
    
    # Set task result to SucceededWithIssues and exit successfully
    echo "##vso[task.complete result=SucceededWithIssues]Rewiring completed with partial success"
    exit 0
fi
