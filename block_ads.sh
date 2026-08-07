#!/bin/bash

# Replace these variables with your actual Cloudflare API token and account ID
API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=500
MAX_LISTS=350
MAX_RETRIES=10

# Define error function
function error() {
    echo "Error: $1"
    rm -f adguard_domains.txt.* payload.json
    exit 1
}

# Define silent error function
function silent_error() {
    echo "Silent error: $1"
    rm -f adguard_domains.txt.* payload.json
    exit 0
}

# Download and parse AdGuard DNS filter safely
echo "Downloading AdGuard list..."
curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt" | \
    tr -d '\r' | \
    grep -vE '^[[:space:]]*[!#@]' | \
    sed 's/\$.*//g' | \
    sed 's/^\|\|//g' | \
    sed 's/\^$//g' | \
    sed 's/\^//g' | \
    grep -vE '[/:]' | \
    grep '\.' | \
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
    grep -v '^$' | \
    sort -u > adguard_domains.txt# Create extra lists if required
for file in "${chunked_lists[@]}"; do
    echo "Creating list..."

    # Format list counter
    formatted_counter=$(printf "%03d" "$list_counter")

    # Build payload safely stripping trailing CR and whitespace
    jq -R -s --arg PREFIX "${PREFIX} - ${formatted_counter}" '
        split("\n") | 
        map(sub("\r$"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) |
        map(select(length > 0) | { "value": . }) as $items |
        { "name": $PREFIX, "type": "DOMAIN", "items": $items }
    ' < "${file}" > payload.json

    # Create list using curl without -f to capture the exact error message from Cloudflare
    response=$(curl -sSL --retry "$MAX_RETRIES" --retry-all-errors -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data @payload.json)

    # Check if successful
    if ! echo "$response" | jq -e '.success' > /dev/null; then
        echo "Cloudflare Error Response: $response"
        error "Failed to create list"
    fi

    # Store the list ID
    used_list_ids+=("$(echo "$response" | jq -r '.result.id')")

    # Delete the file and payload
    rm -f "${file}" payload.json

    # Increment list counter
    list_counter=$((list_counter + 1))
done# Create extra lists if required
for file in "${chunked_lists[@]}"; do
    echo "Creating list..."

    # Format list counter
    formatted_counter=$(printf "%03d" "$list_counter")

    # Build payload safely stripping trailing CR and whitespace
    jq -R -s --arg PREFIX "${PREFIX} - ${formatted_counter}" '
        split("\n") | 
        map(sub("\r$"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) |
        map(select(length > 0) | { "value": . }) as $items |
        { "name": $PREFIX, "type": "DOMAIN", "items": $items }
    ' < "${file}" > payload.json

    # Create list using curl without -f to capture the exact error message from Cloudflare
    response=$(curl -sSL --retry "$MAX_RETRIES" --retry-all-errors -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data @payload.json)

    # Check if successful
    if ! echo "$response" | jq -e '.success' > /dev/null; then
        echo "Cloudflare Error Response: $response"
        error "Failed to create list"
    fi

    # Store the list ID
    used_list_ids+=("$(echo "$response" | jq -r '.result.id')")

    # Delete the file and payload
    rm -f "${file}" payload.json

    # Increment list counter
    list_counter=$((list_counter + 1))
done

echo "Clean domains remaining: $(wc -l < adguard_domains.txt)"

# Ensure the file is not empty
[[ -s adguard_domains.txt ]] || error "The domains list is empty after processing"
# Check if the file has changed
git diff --exit-code adguard_domains.txt > /dev/null && silent_error "The domains list has not changed"

# Ensure the file is not empty
[[ -s adguard_domains.txt ]] || error "The domains list is empty"

# Calculate the number of lines in the file
total_lines=$(wc -l < adguard_domains.txt)

# Ensure the file is not over the maximum allowed lines
(( total_lines <= MAX_LIST_SIZE * MAX_LISTS )) || error "The domains list has more than $((MAX_LIST_SIZE * MAX_LISTS)) lines"

# Calculate the number of lists required
total_lists=$((total_lines / MAX_LIST_SIZE))
[[ $((total_lines % MAX_LIST_SIZE)) -ne 0 ]] && total_lists=$((total_lists + 1))

# Get current lists from Cloudflare (Forcing per_page=1000 to bypass pagination limits)
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
split -l ${MAX_LIST_SIZE} adguard_domains.txt adguard_domains.txt. || error "Failed to split the domains list"

# Create array of chunked lists
chunked_lists=()
for file in adguard_domains.txt.*; do
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

        # Get the existing list name
        list_name=$(echo "${current_lists}" | jq -r --arg id "${list_id}" '.result[] | select(.id == $id) | .name')

        # Build payload safely stripping trailing CR and whitespace
        jq -R -s --arg name "${list_name}" '
            split("\n") | 
            map(sub("\r$"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) |
            map(select(length > 0) | { "value": . }) as $items |
            { "name": $name, "type": "DOMAIN", "items": $items }
        ' < "${chunked_lists[0]}" > payload.json

        # Overwrite list using PUT
        list=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data @payload.json) || error "Failed to update list ${list_id}"

        # Store the list ID
        used_list_ids+=("${list_id}")

        # Delete the first chunked file and temp json files
        rm -f "${chunked_lists[0]}" payload.json
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

    # Build payload safely stripping trailing CR and whitespace
    jq -R -s --arg PREFIX "${PREFIX} - ${formatted_counter}" '
        split("\n") | 
        map(sub("\r$"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) |
        map(select(length > 0) | { "value": . }) as $items |
        { "name": $PREFIX, "type": "DOMAIN", "items": $items }
    ' < "${file}" > payload.json

    # Create list using curl without -f to capture the exact error message from Cloudflare
    response=$(curl -sSL --retry "$MAX_RETRIES" --retry-all-errors -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data @payload.json)

    # Check if successful
    if ! echo "$response" | jq -e '.success' > /dev/null; then
        echo "Cloudflare Error Response: $response"
        error "Failed to create list"
    fi

    # Store the list ID
    used_list_ids+=("$(echo "$response" | jq -r '.result.id')")

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
git add adguard_domains.txt || error "Failed to add the domains list to repo"
git commit -m "Update domains list" --author=. || error "Failed to commit the domains list to repo"
git push origin main || error "Failed to push the domains list to repo"
