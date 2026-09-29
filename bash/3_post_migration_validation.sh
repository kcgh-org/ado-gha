#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="validation-log-$(date +%Y%m%d).txt"
VALIDATION_FAILURES=0
VALIDATION_SUCCESSES=0

write_log() {
  local message="$1"
  echo "$message" | tee -a "$LOG_FILE"
}

is_json() { jq -e . >/dev/null 2>&1; }

urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

clean_field() {
  local s="$1"
  s="${s%$'\r'}"
  s="${s#\"}"
  s="${s%\"}"
  s="$(printf '%s' "$s" | xargs)"
  printf '%s' "$s"
}

parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next

  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"

    if [[ "$char" == '"' ]]; then
      if [[ "$in_quotes" == true ]]; then
        if [[ "$next" == '"' ]]; then field+='"'; ((i++))
        else in_quotes=false; fi
      else in_quotes=true; fi
    elif [[ "$char" == ',' && "$in_quotes" == false ]]; then
      fields+=("$field"); field=""
    else
      field+="$char"
    fi
  done
  fields+=("$field")

  while [ "${#fields[@]}" -lt 7 ]; do fields+=(""); done

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${fields[0]}" "${fields[1]}" "${fields[2]}" \
    "${fields[3]}" "${fields[4]}" "${fields[5]}" "${fields[6]}"
}

# -----------------------------
# Auth checks
# -----------------------------
ensure_auth() {
  # ADO PAT check
  if [[ -z "${ADO_PAT:-}" ]]; then
    write_log "❌ ERROR: ADO_PAT environment variable is not set"
    exit 1
  fi

  # GitHub auth check (support GH_PAT or GH_TOKEN)
  if [[ -n "${GH_PAT:-}" && -z "${GH_TOKEN:-}" ]]; then
    export GH_TOKEN="$GH_PAT"
  fi

  if [[ -z "${GH_TOKEN:-}" ]]; then
    write_log "❌ ERROR: GH_PAT or GH_TOKEN is not set (required for gh api)"
    exit 1
  fi

  # Validate token
  if ! gh api user >/dev/null 2>&1; then
    write_log "❌ ERROR: GitHub authentication failed (invalid/expired token)"
    exit 1
  fi
}

# -----------------------------
# GitHub commit helpers (correct pagination)
# -----------------------------
gh_commit_count() {
  local github_org="$1" github_repo="$2" branch="$3"
  gh api "/repos/$github_org/$github_repo/commits?sha=$branch&per_page=100" --paginate \
    | jq -s 'map(length) | add // 0'
}

gh_latest_sha() {
  local github_org="$1" github_repo="$2" branch="$3"
  gh api "/repos/$github_org/$github_repo/commits?sha=$branch&per_page=1" --jq '.[0].sha // empty'
}

# -----------------------------
# ADO commit helpers (correct continuation token paging)
# -----------------------------
ado_commit_count() {
  local ado_org="$1" encoded_project="$2" repo_id="$3" base64_auth="$4" branch="$5"
  local total=0 token="" url headers_file body_file page_count

  while :; do
    url="https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories/$repo_id/commits?searchCriteria.itemVersion.version=$branch&searchCriteria.\$top=100&api-version=7.1"
    [[ -n "$token" ]] && url="${url}&continuationToken=$token"

    headers_file="$(mktemp)"
    body_file="$(mktemp)"

    curl -s -D "$headers_file" -o "$body_file" -H "Authorization: Basic $base64_auth" "$url"

    if ! jq -e . >/dev/null 2>&1 < "$body_file"; then
      rm -f "$headers_file" "$body_file"
      echo "0"
      return
    fi

    page_count="$(jq -r '.count // 0' < "$body_file")"
    total=$(( total + page_count ))

    token="$(grep -i '^x-ms-continuationtoken:' "$headers_file" | tail -1 | cut -d' ' -f2 | tr -d '\r')"

    rm -f "$headers_file" "$body_file"

    [[ -z "$token" ]] && break
  done

  echo "$total"
}

ado_latest_sha() {
  local ado_org="$1" encoded_project="$2" repo_id="$3" base64_auth="$4" branch="$5"
  curl -s -H "Authorization: Basic $base64_auth" \
    "https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories/$repo_id/commits?searchCriteria.itemVersion.version=$branch&searchCriteria.\$top=1&api-version=7.1" \
    | jq -r '.value[0].commitId // empty'
}

# -----------------------------
# Validate migration
# -----------------------------
validate_migration() {
  local ado_org="$1"
  local ado_team_project="$2"
  local ado_repo="$3"
  local github_org="$4"
  local github_repo="$5"

  local has_validation_errors=0
  write_log "============================================================"
  write_log "Validating: $ado_repo -> $github_org/$github_repo"

  # ---- GitHub branches ----
  local gh_branches
  if ! gh_branches=$(gh api "/repos/$github_org/$github_repo/branches?per_page=100" --paginate 2>/dev/null); then
    write_log "❌ ERROR: Failed to fetch GitHub branches for $github_org/$github_repo"
    return 1
  fi

  local -a gh_branch_array=()
  mapfile -t gh_branch_array < <(echo "$gh_branches" | jq -r '.[].name')

  # ---- GitHub default branch ----
  local gh_default_branch
  if ! gh_default_branch=$(gh api "/repos/$github_org/$github_repo" --jq '.default_branch' 2>/dev/null); then
    write_log "❌ ERROR: Failed to fetch GitHub default branch for $github_org/$github_repo"
    return 1
  fi

  # ---- ADO auth ----
  local base64_auth
  base64_auth=$(printf ":%s" "$ADO_PAT" | base64 -w 0 2>/dev/null || printf ":%s" "$ADO_PAT" | base64)

  # ---- ADO repo lookup ----
  local encoded_project
  encoded_project=$(urlencode "$ado_team_project")

  local repo_list_resp
  repo_list_resp=$(curl -s -H "Authorization: Basic $base64_auth" \
    "https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories?api-version=7.1")

  if ! echo "$repo_list_resp" | is_json; then
    write_log "❌ ERROR: ADO repo list response is not JSON for org=$ado_org project=$ado_team_project"
    return 1
  fi

  local repo_id
  repo_id=$(echo "$repo_list_resp" | jq -r --arg name "$ado_repo" '.value[] | select(.name == $name) | .id' | head -n 1)

  if [[ -z "${repo_id:-}" || "$repo_id" == "null" ]]; then
    write_log "❌ ERROR: Could not find ADO repo id for repo='$ado_repo' in project='$ado_team_project'"
    return 1
  fi

  local ado_default_ref
  ado_default_ref=$(echo "$repo_list_resp" | jq -r --arg id "$repo_id" '.value[] | select(.id == $id) | .defaultBranch' | head -n 1)

  local ado_default_branch="${ado_default_ref#refs/heads/}"
  write_log "Default branch: ADO=$ado_default_branch | GitHub=$gh_default_branch"

  # ---- ADO branches ----
  local ado_branch_response
  ado_branch_response=$(curl -s -H "Authorization: Basic $base64_auth" \
    "https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories/$repo_id/refs?filter=heads/&api-version=7.1")

  if ! echo "$ado_branch_response" | is_json; then
    write_log "❌ ERROR: ADO branch response is not JSON for repo_id=$repo_id"
    return 1
  fi

  local -a ado_branch_array=()
  mapfile -t ado_branch_array < <(echo "$ado_branch_response" | jq -r '.value[].name | sub("refs/heads/";"")')

  # ---- Branch count comparison ----
  local gh_branch_count=${#gh_branch_array[@]}
  local ado_branch_count=${#ado_branch_array[@]}

  local branch_status="❌ Not Matching"
  if [[ "$gh_branch_count" -eq "$ado_branch_count" ]]; then
    branch_status="✅ Matching"
  else
    has_validation_errors=1
  fi
  write_log "Branch Count: ADO=$ado_branch_count | GitHub=$gh_branch_count | $branch_status"

  # ---- Build sets ----
  declare -A gh_set=()
  declare -A ado_set=()
  for b in "${gh_branch_array[@]}"; do gh_set["$b"]=1; done
  for b in "${ado_branch_array[@]}"; do ado_set["$b"]=1; done

  # ---- Determine validation branch (for <=10 scenario) ----
  local validation_branch=""
  if [[ "$gh_default_branch" == "$ado_default_branch" ]]; then
    validation_branch="$gh_default_branch"
  elif [[ -n "${gh_set[$gh_default_branch]:-}" ]]; then
    validation_branch="$gh_default_branch"
  elif [[ -n "${gh_set[$ado_default_branch]:-}" ]]; then
    validation_branch="$ado_default_branch"
  else
    has_validation_errors=1
  fi

  # ---- Commit/SHA checks ----
  if [[ "${COMMIT_CHECK:-true}" == "true" ]]; then
    local -a branches_to_check=()

    if (( gh_branch_count > 10 || ado_branch_count > 10 )); then
      # Default branch first
      branches_to_check+=("$gh_default_branch")

      # Fill up to 10 branches from GitHub list, avoiding duplicates
      for b in "${gh_branch_array[@]}"; do
        [[ "$b" == "$gh_default_branch" ]] && continue
        branches_to_check+=("$b")
        (( ${#branches_to_check[@]} >= 10 )) && break
      done

      write_log "Repo has >10 branches. Commit/SHA summary will be shown for first ${#branches_to_check[@]} branches (default branch first)."
    else
      if [[ -z "${validation_branch:-}" ]]; then
        write_log "❌ Could not determine a validation branch for commit/SHA checks."
        has_validation_errors=1
      else
        branches_to_check+=("$validation_branch")
        write_log "Repo has ≤10 branches. Commit/SHA will be checked only for default branch: '$validation_branch'."
      fi
    fi

    for b in "${branches_to_check[@]}"; do
      [[ -z "$b" ]] && continue

      if [[ -z "${gh_set[$b]:-}" ]]; then
        write_log "Branch '$b': ❌ Missing in GitHub branches list"
        has_validation_errors=1
        continue
      fi

      if [[ -z "${ado_set[$b]:-}" ]]; then
        write_log "Branch '$b': ❌ Missing in ADO branches list"
        has_validation_errors=1
        continue
      fi

      local gh_cc gh_sha ado_cc ado_sha
      gh_cc="$(gh_commit_count "$github_org" "$github_repo" "$b")"
      gh_sha="$(gh_latest_sha "$github_org" "$github_repo" "$b")"

      ado_cc="$(ado_commit_count "$ado_org" "$encoded_project" "$repo_id" "$base64_auth" "$b")"
      ado_sha="$(ado_latest_sha "$ado_org" "$encoded_project" "$repo_id" "$base64_auth" "$b")"

      local commit_status="❌ Not Matching"
      if [[ "$gh_cc" -eq "$ado_cc" ]]; then
        commit_status="✅ Matching"
      else
        has_validation_errors=1
      fi

      local sha_status="❌ Not Matching"
      if [[ -n "$gh_sha" && -n "$ado_sha" && "$gh_sha" == "$ado_sha" ]]; then
        sha_status="✅ Matching"
      else
        has_validation_errors=1
      fi

      write_log "Branch '$b': ADO Commits=$ado_cc | GitHub Commits=$gh_cc | $commit_status"
      write_log "Branch '$b': ADO SHA=$ado_sha | GitHub SHA=$gh_sha | $sha_status"
    done
  fi

  return $has_validation_errors
}

# -----------------------------
# MAIN
# -----------------------------
ensure_auth

CSV_INPUT="${1:-repos_with_status.csv}"

while read -r line; do
  line="${line%$'\r'}"
  [[ -z "$line" ]] && continue

  IFS=$'\t' read -r org teamproject repo github_org github_repo _ status \
    < <(parse_csv_line "$line")

  org=$(clean_field "$org")
  teamproject=$(clean_field "$teamproject")
  repo=$(clean_field "$repo")
  github_org=$(clean_field "$github_org")
  github_repo=$(clean_field "$github_repo")
  status=$(clean_field "$status")

  [[ "$status" != "Success" ]] && continue

  if validate_migration "$org" "$teamproject" "$repo" "$github_org" "$github_repo"; then
    VALIDATION_SUCCESSES=$((VALIDATION_SUCCESSES + 1))
  else
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
  fi

done < <(tail -n +2 "$CSV_INPUT")

write_log "============================================================"
write_log "Summary: $VALIDATION_SUCCESSES succeeded, $VALIDATION_FAILURES failed"

# Optional: fail pipeline if you want
if [[ "${FAIL_ON_VALIDATION_FAILURES:-false}" == "true" && "$VALIDATION_FAILURES" -gt 0 ]]; then
  write_log "❌ FAIL_ON_VALIDATION_FAILURES=true and failures detected. Exiting with code 1."
  exit 1
fi

exit 0
