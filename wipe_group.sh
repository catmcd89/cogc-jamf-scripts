#!/bin/bash

###########################################
#
# Author: Cat McDonald
# Company: City of Glasgow College
# Purpose: To select a group from a CSV file and wipe them 
# Blog post: 
#
###########################################

#### DEPENDENCIES TO RUN THIS SCRIPT ####
# - Python3
# - SwiftDialog
# - Client ID & Secret saved in keychain fo API Token
# - A CSV hosted on a webserver with the smart group name and their group ID 


# --- Jamf Pro variables ---
JAMF_URL="JAMFINSTANCE.jamfcloud.com"
CLIENT_ID="API ID"
CLIENT_SECRET=$(security find-generic-password -a "API ID" -s "NAME" -w)

# --- File locations ---
LOG_FILE="/var/log/jamf_wipe.log"
DIALOG="/usr/local/bin/dialog"
JAMF="/usr/local/jamf/bin/jamf"
ERASE_PIN="<pin>" #for intel Macs

# --- Get Smart Groups ---
#where the CSV of the groups and details are kept. You can ask the Jamf AI to export this for you
LIST=$(curl -s WEBSERVER URL) 
csv=$(echo "$LIST" |
    awk -F',' 'NR>1 {print $1}' |
    paste -sd ',' -)

# --- Get access token test ---

echo "Authenticating with Jamf Pro..."

# Gets the bearer token used to authenticate against our Jamf Instance. 
# The details authenticate against an API that allows:
#	- Read Smart Groups
#	- Read Computers
#	- Read Static Computer groups 
#	- Send computer remote wipe commands
# As dictated by best practices it has been given the least privilege needed
TOKEN_RESPONSE=$(curl --max-time 60 --silent --fail \
    --request POST \
    --url "${JAMF_URL}/api/oauth/token" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}")

# If it fails to authenticate exit out of script with an error
if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to authenticate. Check your credentials and URL."
    exit 1
fi

# The access token needed for the API calls
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')


# if it managed to grab the token - validation checking
if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
    echo "ERROR: Could not parse access token from response."
    exit 1
fi

echo "Authentication successful." 

# --- Dry Run check ---

### This section means you can see the script run in theory then do it for real 
### when comfortable 

dryRunResult=$("$DIALOG" \
	--small \
    --height 300 \
    --title "Select the Smart Group to Wipe" \
    --messagefont "size=16" \
    --message "Please select which Smart Group you want to wipe." \
    --icon caution \
    --selecttitle "Dry run or real deal?",radio \
    --selectvalues "dry run, real deal" \
)
DRY_RUN=$(echo "$dryRunResult" | awk -F' : ' '/SelectedOption/ {print $2}')

# --- Group select section ---

### This list is grabbed off a CSV on a linux webserver 
### it's limited so the wrong group doesn't get wiped 

# --- Smart Group Selection ---

while true; do

    groupResult=$("$DIALOG" \
        --small \
        --height 300 \
        --title "Select the Smart Group to Wipe" \
        --messagefont "size=16" \
        --message "Please select which Smart Group you want to wipe." \
        --hideicon \
        --selecttitle "Smart Group" \
        --selectvalues "$csv"
    )

    # Exit if cancelled
    [[ $? -ne 0 ]] && exit 0

    group=$(echo "$groupResult" | awk -F' : ' '/SelectedOption/ {print $2}' | sed 's/^"//;s/"$//')

    groupValidation=$("$DIALOG" \
        --small \
        --height 300 \
        --title "Validation" \
        --messagefont "size=16" \
        --message "You selected: $group is this correct?" \
        --hideicon \
        --selecttitle "select option",radio \
        --selectvalues "Yes,No"
    )

    validation=$(echo "$groupValidation" | awk -F' : ' '/SelectedOption/ {print $2}')
	printf '<%s>\n' "$validation"
   if [[ "$validation" == "\"Yes\"" ]]; then
    break
fi

done

# --- display group info ---

echo "Looking up group: '${group}'..."

### using the second column to find the group ID and search it through that

GROUP_ID=$(echo "$LIST" | awk -F',' -v grp="$group" '$1 == grp {print $2}')

echo "Found group '${group}' with ID: ${GROUP_ID}"

echo "Retrieving inventory for group members..."

COMPUTERS_RESPONSE=$(curl --max-time 60 --silent --fail \
    --request GET \
    --url "${JAMF_URL}/api/v1/computers-inventory?section=GENERAL&section=GROUP_MEMBERSHIPS&page-size=2000" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header "Accept: application/json")

COMPUTER_IDS=$(echo "$COMPUTERS_RESPONSE" | jq -r \
    --arg gid "$GROUP_ID" \
    '.results[] | select(.groupMemberships[]?.groupId == $gid) | .id')

# Filter out any empty lines or nulls
FILTERED_IDS=$(echo "$COMPUTER_IDS" | grep -v "^$|^null$" | sort -u)
COMPUTER_COUNT=$(echo "$FILTERED_IDS" | grep -c .)

if [[ $COMPUTER_COUNT -eq 0 ]]; then
    echo "No computers found in group '${GROUP_NAME}'. Exiting."
    exit 0
fi

echo "Found ${COMPUTER_COUNT} computer(s) in target group."


# --- Step 4: Execution Logic ------------------------------------------------
############################################################
# Dry Run
############################################################

if [[ "$DRY_RUN" == "\"dry run\"" ]]; then
DRYRUN_DETAILS=$(echo "$COMPUTERS_RESPONSE" | jq -r \
    --arg gid "$GROUP_ID" '
    .results[]
    | select(.groupMemberships[]?.groupId == $gid)
    | "Name: \(.general.name // "Unknown")
"
')

MESSAGE="DRY RUN MODE

NO DEVICES WILL BE WIPED

Selected Group:
$group

Group ID:
$GROUP_ID

Devices Found:
$COMPUTER_COUNT

Erase PIN:
$ERASE_PIN

Pin is only needed on Intel Macs

------------------------------------------------

$DRYRUN_DETAILS"

"$DIALOG" \
    --title "Dry Run Results" \
    --icon caution \
    --width 700 \
    --height 450 \
    --messagefont "size=15" \
    --message "$MESSAGE" \
    --button1text "Continue" \
    --button2text "Cancel"
    
    [[ $? -ne 0 ]] && exit 0

    # Optional second confirmation before real run
    dryRunConfirm=$("$DIALOG" \
    	--mini \
        --title "Proceed With Real Wipe?" \
        --icon caution \
        --message "Dry run complete.

Would you like to continue with the actual wipe operation?" \
        --button1text "Proceed" \
        --button2text "Exit")

    [[ $? -ne 0 ]] && exit 0
fi

# Final confirmation prompt

  # --- Final Confirmation ---

result=$("$DIALOG" \
    --title "Confirmation Needed" \
    --messagefont "size=16" \
    --message "WARNING: You are about to WIPE $COMPUTER_COUNT Mac(s).

This action is IRREVERSIBLE. All data will be erased.

Group: $group

PIN: $ERASE_PIN

Type CONFIRM to proceed.

Please note it is case sensitive." \
    --icon caution \
    --textfield "Confirm?" \
    --button1text "OK" \
    --button2text "Cancel" \
    --json
)

# User clicked Cancel or closed the window
[[ $? -ne 0 ]] && exit 0

# Extract text entered into the field
confirmText=$(echo "$result" | \
    /usr/bin/plutil -extract "Confirm?" raw -o - -)

echo "User entered: [$confirmText]"

# Validate entry
if [[ "$confirmText" != "CONFIRM" ]]; then

    "$DIALOG" \
        --title "Aborted" \
        --icon caution \
        --message "You must enter CONFIRM exactly to continue." \
        --button1text "OK"

    exit 0
fi

echo "Confirmation accepted."

SUCCESS_COUNT=0
FAIL_COUNT=0
CURRENT_INDEX=0

# Process the list
while read -r COMPUTER_ID; do
    [[ -z "$COMPUTER_ID" ]] && continue
    ((CURRENT_INDEX++))

    echo "[$CURRENT_INDEX/$COMPUTER_COUNT] Processing ID: ${COMPUTER_ID}..."

    # Execute command with 60-second timeout
    RESPONSE=$(curl --max-time 60 --silent --write-out "\n%{http_code}" \
        --request POST \
        --url "${JAMF_URL}/api/v1/computer-inventory/${COMPUTER_ID}/erase" \
        --header "Authorization: Bearer ${ACCESS_TOKEN}" \
        --header "Content-Type: application/json" \
        --header "Accept: application/json" \
        --data "{\"pin\": \"${ERASE_PIN}\"}")
	HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
	BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_STATUS" == "200" ]]; then
    COMMAND_UUID=$(echo "$BODY" | jq -r '.commandUuid')
    echo "✓ Success. Command UUID: $COMMAND_UUID"
    ((SUCCESS_COUNT++))
else
    echo "HTTP Status: $HTTP_STATUS"
    echo "Response: $BODY"

    echo "ID: ${COMPUTER_ID} | Status: ${HTTP_STATUS} | Response: ${BODY}" >> "$LOG_FILE"

    ((FAIL_COUNT++))
fi

    # Short sleep to respect API rate limits
    sleep 0.5

done <<< "$FILTERED_IDS"

if [[ $FAIL_COUNT -gt 0 ]]; then
    ICON="caution"
else
    ICON="$LOGO"
fi

# --- Wipe Summary ---

"$DIALOG" \
    --title "Wipe Summary" \
    --messagefont "size=16" \
    --icon "$ICON" \
    --width 500 \
    --height 350 \
    --button1text "OK" \
    --message "✅ Successful: $SUCCESS_COUNT

❌ Failed: $FAIL_COUNT

Total Processed: $COMPUTER_COUNT

🔐 PIN Used: $ERASE_PIN

📄 Log File:
$LOG_FILE"
