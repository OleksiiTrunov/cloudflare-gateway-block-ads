#!/bin/bash

# Replace these variables with your actual Cloudflare API token and account ID
API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1500
MAX_LISTS=100
MAX_RETRIES=10

# Define error function
function error() {
    echo "Error: $1"
    rm -f oisd_small_domainswild2.txt.* payload.json remove_items.json
    exit 1
}

# Define silent error function
function silent_error() {
    echo "Silent error: $1"
    rm -f oisd_small_domainswild2.txt.* payload.json remove_items.json
    exit 0
}

# Download the latest domains list
curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors https://small.oisd.nl/domainswild2 | grep -vE '^\s*(#|$)' > oisd_small_domainswild2.txt || silent_error "Failed to download the domains list"

# Check if the file has changed
git diff --exit-code oisd_small_domainswild2.txt > /dev/null && silent_error "The domains list has not changed"

# Ensure the file is not empty
[[ -s oisd_small_domainswild2.txt ]] || error "The domains list is empty"

# Calculate the number of lines in the file
total_lines=$(wc -l < oisd_small_domainswild2.txt)

# Ensure the file is not over the maximum allowed lines
(( total_lines <= MAX_LIST_SIZE * MAX_LISTS )) || error "The domains list has more than $((MAX_LIST_SIZE * MAX_LISTS)) lines"

# Calculate the number of lists required
total_lists=$((total_lines / MAX_LIST_SIZE))
[[ $((total_lines % MAX_LIST_SIZE)) -ne 0 ]] && total_lists=$((total_lists + 1))

# Get current lists from Cloudflare (Forcing per_page=1000 to bypass 50 items pagination limit)
current_lists=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists?per_page=1000" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json") || error "Failed to get current lists from Cloudflare"
    
# Get current policies from Cloudflare (Forcing per_page=1000)
current_policies=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules?per_page=1000" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json") || error "Failed to get current policies from Cloudflare"

# Count number of lists that have $PREFIX in name
current_lists_count=$(echo "${current_lists}" | jq -r --arg PREFIX "${PREFIX}" 'if (.result | length > 0) then .result | map(select(.name | contains($PREFIX))) | length else 0 end') || error "Failed to count current lists"

# Count number of lists without $PREFIX in name
current_lists_count_without_prefix=$(echo "${current_lists}" | jq -r --arg PREFIX "${PREFIX}" 'if (.result | length > 0) then .result | map(select(.name | contains($PREFIX) | not)) | length else 0 end') || error "Failed to count current lists without prefix"

# Ensure total_lists name is less than or equal to $MAX_LISTS - current_lists_count_without_prefix
[[ ${total_lists} -le $((MAX_LISTS - current_lists_count_without_prefix)) ]] || error "The number of lists required (${total_lists}) is greater than the maximum allowed (${MAX_LISTS - current_lists_count_without_prefix})"

# Split lists into chunks of $MAX_LIST_SIZE
split -l ${MAX_LIST_SIZE} oisd_small_domainswild2.txt oisd_small_domainswild2.txt. || error "Failed to split the domains list"

# Create array of chunked lists
chunked_lists=()
for file in oisd_small_domainswild2.txt.*; do
    chunked_lists+=("${file}")
done

# Create array of used list IDs
used_list_ids=()

# Create array of excess list IDs
excess_list_ids=()

# Create list counter
list_counter=1

# Update existing lists
if [[ ${current_lists_count} -gt 0 ]]; then
    # For each list ID
    for list_id in $(echo "${current_lists}" | jq -r --arg PREFIX "${PREFIX}" '.result | map(select(.name | contains($PREFIX))) | .[].id'); do
        # If there are no more chunked lists, mark the list ID for deletion
        [[ ${#chunked_lists[@]} -eq 0 ]] && {
            echo "Marking list ${list_id} for deletion..."
            excess_list_ids+=("${list_id}")
            continue
        }

        echo "Updating list ${list_id}..."

        # Get list contents
        list_items=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}/items?limit=${MAX_LIST_SIZE}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json") || error "Failed to get list ${list_id} contents"

        # Save removal items to a temp file to avoid ARG_MAX limits
        echo "${list_items}" | jq -r '.result | map(.value) | map(select(. != null))' > remove_items.json

        # Process the raw text chunk and combine it with the removal items directly into a payload file
        jq -R -s --slurpfile remove_items remove_items.json '
            split("\n") | map(select(length > 0) | { "value": . }) as $append_items |
            { "append": $append_items, "remove": ($remove_items[0] // []) }
        ' < "${chunked_lists[0]}" > payload.json

        # Patch list using the generated payload file
        list=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X PATCH "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data @payload.json) || error "Failed to patch list ${list_id}"

        # Store the list ID
        used_list_ids+=("${list_id}")

        # Delete the first chunked file and temp json files
        rm -f "${chunked_lists[0]}" payload.json remove_items.json
        chunked_lists=("${chunked_lists[@]:1}")

        # Increment list counter
        list_counter=$((list_counter + 1))
    done
fi

# Create extra lists if required
for file in "${chunked_lists[@]}"; do
    echo "Creating list..."

    # Format list counter
    formatted_counter=$(printf "%03d" "$list_counter")

    # Build payload directly to file avoiding ARG_MAX limits
    jq -R -s --arg PREFIX "${PREFIX} - ${formatted_counter}" '
        split("\n") | map(select(length > 0) | { "value": . }) as $items |
        { "name": $PREFIX, "type": "DOMAIN", "items": $items }
    ' < "${file}" > payload.json

    # Create list using the generated payload file
    list=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data @payload.json) || error "Failed to create list"

    # Store the list ID
    used_list_ids+=("$(echo "${list}" | jq -r '.result.id')")

    # Delete the file and payload
    rm -f "${file}" payload.json

    # Increment list counter
    list_counter=$((list_counter + 1))
done

# Ensure policy called exactly $PREFIX exists, else create it
policy_id=$(echo "${current_policies}" | jq -r --arg PREFIX "${PREFIX}" '.result | map(select(.name == $PREFIX)) | .[0].id') || error "Failed to get policy ID"

# Initialize an empty array to store conditions
conditions=()

# Loop through the used_list_ids and build the "conditions" array dynamically
[[ ${#used_list_ids[@]} -eq 1 ]] && {
    conditions='
                "any": {
                    "in": {
                        "lhs": {
                            "splat": "dns.domains"
                        },
                        "rhs": "$'"${used_list_ids[0]}"'"
                    }
                }'
} || {
    for list_id in "${used_list_ids[@]}"; do
        conditions+=('{
                "any": {
                    "in": {
                        "lhs": {
                            "splat": "dns.domains"
                        },
                        "rhs": "$'"$list_id"'"
                    }
                }
        }')
    done
    conditions=$(IFS=','; echo "${conditions[*]}")
    conditions='"or": ['"$conditions"']'
}

# Create the JSON data dynamically
json_data='{
    "name": "'${PREFIX}'",
    "conditions": [
        {
            "type":"traffic",
            "expression":{
                '"$conditions"'
            }
        }
    ],
    "action":"block",
    "enabled":true,
    "description":"",
    "rule_settings":{
        "block_page_enabled":false,
        "block_reason":"",
        "biso_admin_controls": {
            "dcp":false,
            "dcr":false,
            "dd":false,
            "dk":false,
            "dp":false,
            "du":false
        },
        "add_headers":{},
        "ip_categories":false,
        "override_host":"",
        "override_ips":null,
        "l4override":null,
        "check_session":null
    },
    "filters":["dns"]
}'

[[ -z "${policy_id}" || "${policy_id}" == "null" ]] &&
{
    # Create the policy
    echo "Creating policy..."
    curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$json_data" > /dev/null || error "Failed to create policy"
} ||
{
    # Update the policy
    echo "Updating policy ${policy_id}..."
    curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/${policy_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$json_data" > /dev/null || error "Failed to update policy"
}

# Delete excess lists in $excess_list_ids
for list_id in "${excess_list_ids[@]}"; do
    echo "Deleting list ${list_id}..."
    curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X DELETE "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" > /dev/null || error "Failed to delete list ${list_id}"
done

# Add, commit and push the file
git config --global user.email "${GITHUB_ACTOR_ID}+${GITHUB_ACTOR}@users.noreply.github.com"
git config --global user.name "$(gh api /users/${GITHUB_ACTOR} | jq .name -r)"
git add oisd_small_domainswild2.txt || error "Failed to add the domains list to repo"
git commit -m "Update domains list" --author=. || error "Failed to commit the domains list to repo"
git push origin main || error "Failed to push the domains list to repo"
