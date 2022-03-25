#!/bin/bash
set -euo pipefail

SESSION_TOKEN=$(\
   curl -s "https://$DOMAIN/api/v1/refresh-access-token" \
     -H 'Content-Type: application/json' \
     -H "Authorization: $TOKEN" | jq -r .systemToken)
repo=$(echo "$GITHUB_REPOSITORY" | sed 's/.*\///g')
dsname="codescan-$repo"
scanner_name="scanner-$repo"

if curl -s "https://$DOMAIN/api/v1/ds_connections/$dsname" -H "Authorization: $SESSION_TOKEN" --fail --output /dev/null; then
  #get branch list and add the current branch if not already in the list
  branch_data=$(curl -s "https://$DOMAIN/api/v1/ds_connections/$dsname" \
                     -H "Authorization: $SESSION_TOKEN" \
                |jq -r --arg new_branch "$BRANCH" \
                 '.ds_connection.branch_to_scan_list | split(",") | . |= . + [$new_branch] | unique | join(",")')
  DS_BODY=$(jq --null-input \
    --arg ds_name     "$dsname" \
    --arg repo_name   "$repo" \
    --arg branch_name "$branch_data" \
    --arg token       "$PA_TOKEN" \
    -f "$GITHUB_ACTION_PATH/templates/ds-tmpl.jq")
  echo "updating datasource"
  curl -s -X PUT "https://$DOMAIN/api/v1/ds_connections/$dsname" \
    -H "Authorization: $SESSION_TOKEN" \
    -H 'Content-type: application/json' \
    -d "$DS_BODY" \
    --fail
else
  echo "create new datasource"
  #BODY for datasource for review
  DS_BODY=$(jq --null-input \
    --arg ds_name     "$dsname" \
    --arg repo_name   "$repo" \
    --arg branch_name "$BRANCH" \
    --arg token       "$PA_TOKEN" \
    -f "$GITHUB_ACTION_PATH/templates/ds-tmpl.jq")
  curl -s "https://$DOMAIN/api/v1/ds_connections" \
    -H "Authorization: $SESSION_TOKEN" \
    -H 'Content-type: application/json' \
    -d "$DS_BODY" \
    --fail
  echo "create scan profile"
  #body for scanprofile
  SCAN_BODY=$(jq --null-input \
    --arg ds_name      "$dsname" \
    --arg scanner_name "$scanner_name" \
    -f "$GITHUB_ACTION_PATH/templates/scan-profile-tmpl.jq")
  curl -s -X POST \
    -H "Authorization: $SESSION_TOKEN" \
    -F "data=$SCAN_BODY" \
    -F "scanProfileName=$scanner_name" \
    -F 'scanProfileScanType=dsName' \
    "https://$DOMAIN/api/v1/scanProfiles/"
fi

echo "launch scan"
BODY=$(jq --null-input --arg scanner_name "$scanner_name" \
  '{"scanType": "dsScan", "scanProfileName": $scanner_name, "scanOrigin": "github action"}')
scan_id=$(curl -s "https://$DOMAIN/api/v1/scans" \
            -H "Authorization: $SESSION_TOKEN" \
            -H 'Content-type: application/json' \
            -d "$BODY" \
            --fail | jq -r '.result._id')
while [ "$(curl -s "https://$DOMAIN/api/v1/scans/$scan_id" -H "Authorization: $SESSION_TOKEN" |jq -r '.[0].state')" != "Completed" ]; do echo "waiting for scan"; sleep 2; done
echo "scan completed"
result=$(curl -s "https://$DOMAIN/api/v1/scan-insights/$scan_id" -H "Authorization: $SESSION_TOKEN")
echo "$result" | jq -r '.scanInsight.scanSummary'
