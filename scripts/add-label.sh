#!/bin/bash

# Script to add label to issues in GitHub ProjectsV2 based on Status field
# Usage: ./add-label.sh "PVT_xxx,PVT_yyy" ["Need To Verify"] ["kind/need-to-verify"]

set -e

PROJECT_IDS="${1:-}"
STATUS_VALUE="${2:-Need To Verify}"
LABEL_TO_ADD="${3:-kind/need-to-verify}"

if [ -z "$PROJECT_IDS" ]; then
    echo "Usage: $0 <project_ids> [status_value] [label_to_add]"
    echo "  project_ids:   Comma-separated list of ProjectV2 IDs (required)"
    echo "  status_value:  Status field value to match (default: 'Need To Verify')"
    echo "  label_to_add:  Label to add (default: 'kind/need-to-verify')"
    echo ""
    echo "Example: $0 'PVT_kwDOAjmOms4BMOXr,PVT_kwDOAjmOms4A4UrU'"
    exit 1
fi

echo "Projects: $PROJECT_IDS"
echo "Status: $STATUS_VALUE"
echo "Label: $LABEL_TO_ADD"
echo ""

# Get Status field info for each project
FIELD_QUERY='query($id: ID!) {
  node(id: $id) {
    ... on ProjectV2 {
      id
      title
      fields(first: 30) {
        nodes {
          ... on ProjectV2Field {
            name
          }
          ... on ProjectV2SingleSelectField {
            name
            options { name }
          }
        }
      }
    }
  }
}'

# Fetch field info for each project
declare -A STATUS_FIELD_IDS
declare -A PROJECT_TITLES

echo "Fetching project fields..."
for project_id in $(echo "$PROJECT_IDS" | tr ',' ' '); do
    project_data=$(gh api graphql -f query="$FIELD_QUERY" -F id="$project_id" --jq '.data.node')
    
    if [ "$project_data" = "null" ]; then
        echo "Warning: Could not fetch project $project_id, skipping"
        continue
    fi
    
    project_title=$(echo "$project_data" | jq -r '.title')
    PROJECT_TITLES[$project_id]="$project_title"
    
    status_field=$(echo "$project_data" | jq -r '.fields.nodes[] | select(.name == "Status")')
    
    if [ "$status_field" = "null" ] || [ -z "$status_field" ]; then
        echo "Warning: Project $project_title has no Status field, skipping"
        continue
    fi
    
    status_option=$(echo "$status_field" | jq -r ".options[] | select(.name == \"$STATUS_VALUE\")")
    
    if [ "$status_option" = "null" ] || [ -z "$status_option" ]; then
        echo "Warning: Project $project_title has no Status option '$STATUS_VALUE', skipping"
        continue
    fi
    
    STATUS_FIELD_IDS[$project_id]="present"
    
    echo "Project: $project_title - OK"
done

if [ ${#STATUS_FIELD_IDS[@]} -eq 0 ]; then
    echo "Error: No valid projects found"
    exit 1
fi

echo ""
echo "=== Processing issues ==="

total_labeled=0

for project_id in "${!STATUS_FIELD_IDS[@]}"; do
    project_title="${PROJECT_TITLES[$project_id]}"
    
    echo ""
    echo "=== Checking project: $project_title ==="
    
    # Query items in the project with pagination
    ITEMS_QUERY='query($id: ID!, $cursor: String) {
      node(id: $id) {
        ... on ProjectV2 {
          items(first: 100, after: $cursor) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              content {
                ... on Issue {
                  number
                  title
                  state
                  repository {
                    name
                    owner { login }
                  }
                  labels(first: 10) {
                    nodes { name }
                  }
                }
              }
              fieldValues(first: 20) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    field {
                      ... on ProjectV2SingleSelectField {
                        name
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }'
    
    labeled_count=0
    item_count=0
    cursor="null"
    
    while true; do
        if [ "$cursor" = "null" ] || [ -z "$cursor" ]; then
            items_data=$(gh api graphql -f query="$ITEMS_QUERY" -F id="$project_id" --jq '.data.node.items')
        else
            items_data=$(gh api graphql -f query="$ITEMS_QUERY" -F id="$project_id" -F cursor="$cursor" --jq '.data.node.items')
        fi
        
        page_info=$(echo "$items_data" | jq -r '.pageInfo')
        has_next=$(echo "$page_info" | jq -r '.hasNextPage')
        end_cursor=$(echo "$page_info" | jq -r '.endCursor')
        
        nodes=$(echo "$items_data" | jq '.nodes')
        current_count=$(echo "$nodes" | jq 'length')
        item_count=$((item_count + current_count))
        
        echo "Found $item_count items so far..."
        
        for item_row in $(echo "$nodes" | jq -r '.[] | @base64'); do
            item=$(echo "$item_row" | base64 -d)
            
            content=$(echo "$item" | jq -r '.content')
            if [ "$content" = "null" ] || [ -z "$content" ]; then
                continue
            fi
            
            issue_state=$(echo "$content" | jq -r '.state')
            if [ "$issue_state" != "OPEN" ]; then
                continue
            fi
            
            # Check Status field value
            status_field_value=$(echo "$item" | jq -r '.fieldValues.nodes[] | select(.field.name == "Status") | .name')
            
            if [ "$status_field_value" = "$STATUS_VALUE" ]; then
                issue_number=$(echo "$content" | jq -r '.number')
                issue_title=$(echo "$content" | jq -r '.title')
                repo_name=$(echo "$content" | jq -r '.repository.name')
                repo_owner=$(echo "$content" | jq -r '.repository.owner.login')
                
                # Check if label already exists
                existing_labels=$(echo "$content" | jq -r '.labels.nodes[].name')
                
                if echo "$existing_labels" | grep -q "^${LABEL_TO_ADD}$"; then
                    echo "Issue #$issue_number already has label, skip"
                else
                    echo "Adding label to issue #$issue_number: $issue_title"
                    
                    if echo '{"labels": ["$LABEL_TO_ADD"]}' | gh api repos/"$repo_owner"/"$repo_name"/issues/"$issue_number"/labels \
                        -X POST \
                        --input - \
                        > /dev/null 2>&1; then
                        labeled_count=$((labeled_count + 1))
                    else
                        echo "  Warning: Failed to add label to #$issue_number"
                    fi
                fi
            fi
        done
        
        if [ "$has_next" = "false" ]; then
            break
        fi
        
        cursor="$end_cursor"
    done
    
    echo "Project $project_title: Labeled $labeled_count issues (total: $item_count)"
    total_labeled=$((total_labeled + labeled_count))
done

echo ""
echo "=== Done! Total labeled: $total_labeled ==="
