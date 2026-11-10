#!/bin/bash
set -e

RESET_TEXT='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'

# Functions
function getTaskDefinition() {
    aws ecs describe-task-definition \
        --task-definition "$1" \
        --query taskDefinition
}

function registerTaskDefinition() {
    aws ecs register-task-definition \
        --cli-input-json "$1"
}

function runTask() {
    aws ecs run-task \
        --cluster "$INPUT_ECS_CLUSTER_NAME" \
        --launch-type "$INPUT_ECS_LAUNCH_TYPE" \
        --task-definition "$1" \
        --network-configuration "$2"
}

function waitOnTask() {
    aws ecs wait tasks-stopped \
        --cluster "$INPUT_ECS_CLUSTER_NAME" \
        --tasks "$1"
}

function describeTask() {
    aws ecs describe-tasks \
        --cluster "$INPUT_ECS_CLUSTER_NAME" \
        --tasks "$1"
}

function updateService() {
    aws ecs update-service \
        --cluster "$INPUT_ECS_CLUSTER_NAME" \
        --service "$INPUT_ECS_SERVICE_NAME" \
        --task-definition "$1" \
        --enable-execute-command \
        --force-new-deployment
}

function describeService() {
    aws ecs describe-services \
        --cluster "$INPUT_ECS_CLUSTER_NAME" \
        --services "$INPUT_ECS_SERVICE_NAME"
}

function describeServiceScopedToEvents() {
    aws ecs describe-services \
        --cluster "$INPUT_ECS_CLUSTER_NAME" \
        --services "$INPUT_ECS_SERVICE_NAME" \
        --query "services[*].events[?createdAt > \`$1\`]" \
        --output json
}

function listServiceRunningTasks() {
    aws ecs list-tasks \
        --cluster "$INPUT_ECS_CLUSTER_NAME" \
        --service-name "$INPUT_ECS_SERVICE_NAME" \
        --desired-status RUNNING \
        --query taskArns \
        --output json
}

function describeTasks() {
    aws ecs describe-tasks \
        --cluster "$INPUT_ECS_CLUSTER_NAME" \
        --tasks "$@"
}

function getTaskProtection() {
    aws ecs get-task-protection \
        --cluster "$INPUT_ECS_CLUSTER_NAME" \
        --tasks "$@"
}

# Returns 0 (and prints a summary) when every task still running from a previous deployment
# has scale-in protection enabled. ECS will not stop those tasks until their protection is
# removed or expires, so the rollout cannot reach COMPLETED until then.
function onlyProtectedTasksRemain() {
    PARAM_DEPLOYMENT_ID="$1"

    TASK_ARNS=$(listServiceRunningTasks) || return 1
    ALL_TASKS=()
    while IFS= read -r TASK; do ALL_TASKS+=("$TASK"); done < <(echo "$TASK_ARNS" | jq -r '.[]')

    if [ "${#ALL_TASKS[@]}" -eq 0 ]; then
        return 1
    fi

    # Find tasks not started by our deployment (describe-tasks accepts at most 100 per call).
    OLD_TASKS=()
    for ((i = 0; i < ${#ALL_TASKS[@]}; i += 100)); do
        DESCRIBE_RESPONSE=$(describeTasks "${ALL_TASKS[@]:i:100}") || return 1
        while IFS= read -r TASK; do OLD_TASKS+=("$TASK"); done < <(echo "$DESCRIBE_RESPONSE" | jq -r --arg deploymentId "$PARAM_DEPLOYMENT_ID" '.tasks[] | select(.startedBy != $deploymentId) | .taskArn')
    done

    # No old tasks left with desired status RUNNING; normal draining, keep polling.
    if [ "${#OLD_TASKS[@]}" -eq 0 ]; then
        return 1
    fi

    # Check protection (get-task-protection accepts at most 10 per call).
    PROTECTED_TASKS="[]"
    for ((i = 0; i < ${#OLD_TASKS[@]}; i += 10)); do
        PROTECTION_RESPONSE=$(getTaskProtection "${OLD_TASKS[@]:i:10}" 2>&1) || {
            if [ -z "$PROTECTION_CHECK_WARNED" ]; then
                echo "::warning::Unable to check task protection (is ecs:GetTaskProtection allowed?). Continuing to poll normally."
                echo "$PROTECTION_RESPONSE"
                PROTECTION_CHECK_WARNED=1
            fi
            return 1
        }
        PROTECTED_TASKS=$(jq -c --argjson acc "$PROTECTED_TASKS" '$acc + [.protectedTasks[]? | select(.protectionEnabled == true)]' <<< "$PROTECTION_RESPONSE")
    done

    PROTECTED_COUNT=$(echo "$PROTECTED_TASKS" | jq 'length')
    if [ "$PROTECTED_COUNT" -lt "${#OLD_TASKS[@]}" ]; then
        return 1
    fi

    echo -e "${BLUE}New deployment is fully running. Remaining tasks from previous deployment(s) are scale-in protected:"
    echo "$PROTECTED_TASKS" | jq -r '.[] | "  \(.taskArn) (protected until \(.expirationDate // "unknown"))"'
    echo "::notice::Deployment healthy, but ${PROTECTED_COUNT} protected task(s) from a previous deployment are still running. ECS will stop them once protection is removed or expires."
    return 0
}

function pollForSpecificServiceUpdate() {
    LAST_EVENT_DATE="$2"
    deadlockCounter=0;
    PREVIOUS_FAILED_COUNT=0;

        while true; do
            RESPONSE=$(describeService)
            DEPLOYMENT=$(echo "$RESPONSE" | jq -r --arg deploymentId "$1" '.services[]?.deployments[] | select(.id==$deploymentId)')

            if [ -z "$DEPLOYMENT" ]; then
                echo -e "${ORANGE}Deployment with ID $1 was cancelled, missing or replaced by another.";
                echo -e "${ORANGE}Exiting polling loop. Please verify deployment status in the AWS Console."
                exit 0;
            fi

            DESIRED_COUNT=$(echo "$DEPLOYMENT" | jq -r '.desiredCount // 0')
            RUNNING_COUNT=$(echo "$DEPLOYMENT" | jq -r '.runningCount // 0')
            PENDING_COUNT=$(echo "$DEPLOYMENT" | jq -r '.pendingCount // 0')
            FAILED_COUNT=$(echo "$DEPLOYMENT" | jq -r '.failedTasks // 0')
            STATUS=$(echo "$DEPLOYMENT" | jq -r '.rolloutState // "UNKNOWN"')

            echo -e "${ORANGE}Service update in progress. Sleeping 15 seconds. (Try $((++deadlockCounter)))";
            echo -e "Overview: ${RED}Failed ($FAILED_COUNT), ${RESET_TEXT}Desired ($DESIRED_COUNT), ${BLUE}Pending ($PENDING_COUNT), ${GREEN}Running ($RUNNING_COUNT)"
            echo -e "Rollout State: $STATUS"

            EVENTS_RESPONSE=$(describeServiceScopedToEvents "$LAST_EVENT_DATE")
            TEMP_LAST_EVENT_DATE=$(echo "$EVENTS_RESPONSE" | jq -r '.[][0].createdAt // empty')

            if [ -n "$TEMP_LAST_EVENT_DATE" ]; then
                LAST_EVENT_DATE="$TEMP_LAST_EVENT_DATE"
            fi

            echo "$EVENTS_RESPONSE" | jq -r '.[][].message'

            # failedTasks is cumulative for the deployment. A transient failure that ECS replaces
            # is not a failed deployment, so we only warn and let rolloutState decide.
            if [ "$FAILED_COUNT" -gt "$PREVIOUS_FAILED_COUNT" ]; then
                echo "::warning::$((FAILED_COUNT - PREVIOUS_FAILED_COUNT)) task(s) failed during deployment (total: $FAILED_COUNT). ECS will retry; continuing to monitor."
                PREVIOUS_FAILED_COUNT="$FAILED_COUNT"
            fi

            if [ -n "$INPUT_MAX_FAILED_TASKS" ] && [ "$INPUT_MAX_FAILED_TASKS" -gt 0 ] && [ "$FAILED_COUNT" -ge "$INPUT_MAX_FAILED_TASKS" ]; then
                echo -e "${RED}Failed task count ($FAILED_COUNT) reached limit (max_failed_tasks: $INPUT_MAX_FAILED_TASKS)."
                exit 1;
            fi

            if [ "$STATUS" = "FAILED" ]; then
                echo -e "${RED}Failed rollout detected (Failed status)."
                exit 1;
            fi

            if [ "$STATUS" = "UNKNOWN" ]; then
                echo -e "${RED}Unknown status detected (Unknown status)."
                exit 1;
            fi

            if [ "$STATUS" = "COMPLETED" ]; then
                break;
            fi

            if [ "$INPUT_WAIT_FOR_PROTECTED_TASKS" = "false" ] \
                && [ "$STATUS" = "IN_PROGRESS" ] \
                && [ "$PENDING_COUNT" -eq 0 ] \
                && [ "$RUNNING_COUNT" -ge "$DESIRED_COUNT" ] \
                && onlyProtectedTasksRemain "$1"; then
                break;
            fi

            if [ "$deadlockCounter" -gt "$INPUT_MAX_POLLING_ITERATIONS" ]; then
                echo -e "${RED}Max polling iterations reached (max_polling_iterations)."
                exit 1;
            fi
            sleep 15s;
        done;
}

function modifyTaskDefinitionFile() {
    PARAM_TASK_DEFINITION="$1"
    PARAM_IMAGE_CHANGES="$2"

    TASK_DEFINITION_FILE=$(mktemp)
    ORIGINAL_TASK_DEFINITION_FILE=$(mktemp)

    getTaskDefinition "$PARAM_TASK_DEFINITION" > "$ORIGINAL_TASK_DEFINITION_FILE"
    cp "$ORIGINAL_TASK_DEFINITION_FILE" "$TASK_DEFINITION_FILE"

    # Iterate each line item for change and inline adapt Task Definition
    for LINE in ${PARAM_IMAGE_CHANGES}; do
        CONTAINER=$(echo "$LINE" | cut -d'|' -f1)
        IMAGE=${LINE#*|}

        echo "::debug::Found image: $IMAGE";
        echo "::debug::Found container: $CONTAINER";

        if [ -z "$CONTAINER" ] || [ -z "$IMAGE" ]; then
            echo -e "${RED}Image/Container could not be extracted from string: ${RESET_TEXT}${LINE}."
            exit 1;
        fi

        # Intentional skip when NO_IMAGE received to keep above error checking for empty image string
        if [[ "$IMAGE" != "NO_IMAGE" ]]; then
            touch tmpfile;

            # shellcheck disable=SC2002
            cat "$TASK_DEFINITION_FILE" | jq --arg image "$IMAGE" --arg container "$CONTAINER" '(.containerDefinitions[]? | select(.name==$container)) |= (.image=$image)' > tmpfile && mv tmpfile "$TASK_DEFINITION_FILE"
        fi
    done

    if ! jq -e . < "$TASK_DEFINITION_FILE" >/dev/null 2>&1; then
        echo -e "${RED}Task Definition became invalid JSON after modifications (invalid_task_definition)."

        if [ -n "$RUNNER_DEBUG" ]; then
            echo "::debug::Debug enabled. Outputting modified Task Definition file.";
            cat "$TASK_DEFINITION_FILE"
        fi

        exit 1;
    fi

    # Review changes (if debugging)
    if [ -n "$RUNNER_DEBUG" ]; then
        diff <(jq --sort-keys . "$ORIGINAL_TASK_DEFINITION_FILE") <(jq --sort-keys . "$TASK_DEFINITION_FILE") || true
    fi

    # Remove keys that are rejected via registering.
    # shellcheck disable=SC2002
    cat "$TASK_DEFINITION_FILE" | jq 'del(.compatibilities,.taskDefinitionArn,.requiresAttributes,.revision,.status,.registeredAt,.deregisteredAt,.registeredBy)' > tmpfile && mv tmpfile "$TASK_DEFINITION_FILE"
}

# Validation of AWS Creds
echo -e "ECS Deploy Action for AWS on GitHub Actions.";
AWS_USERID=$(aws sts get-caller-identity | jq -r '.UserId')
if [ -z "$AWS_USERID" ] && [ -z "$INPUT_DRY_RUN" ]; then
    echo "::error::Access could not be reached to AWS. Double check aws-actions/configure-aws-credentials is properly configured."
    exit 1;
fi

# Load in values
if [ -n "$INPUT_AWS_REGION" ]; then
    export AWS_DEFAULT_REGION=$INPUT_AWS_REGION
fi

# Check if we have a prepare script
if [ -n "$INPUT_PREPARE_TASK_DEFINITION_NAME" ] && [ -z "$INPUT_PREPARE_TASK_CONTAINER_IMAGE_CHANGES" ]; then
    echo "::error::Prepare Task Definition Name was passed, but no Prepare container image changes. Ending job."
    exit 1;
fi

if [ -n "$INPUT_PREPARE_TASK_CONTAINER_IMAGE_CHANGES" ] && [ -z "$INPUT_PREPARE_TASK_DEFINITION_NAME" ]; then
    echo "::error::Prepare container image changes was passed, but no Prepare task definition name. Ending job."
    exit 1;
fi

if [ -n "$INPUT_PREPARE_TASK_CONTAINER_IMAGE_CHANGES" ] && [ -n "$INPUT_PREPARE_TASK_DEFINITION_NAME" ]; then
    modifyTaskDefinitionFile "$INPUT_PREPARE_TASK_DEFINITION_NAME" "$INPUT_PREPARE_TASK_CONTAINER_IMAGE_CHANGES"

    if [ -n "$INPUT_PREPARE_TASK_CONTAINER_NETWORK_CONFIG_FILEPATH" ]; then
        if ! jq -e . < "$INPUT_PREPARE_TASK_CONTAINER_NETWORK_CONFIG_FILEPATH" >/dev/null 2>&1; then
            echo -e "${RED}Network configuration is invalid JSON. (invalid_network_config_file)."
            exit 1;
        fi
    fi

    # shellcheck disable=SC2002
    JSON_NETWORK_CONFIG=$(cat "$INPUT_PREPARE_TASK_CONTAINER_NETWORK_CONFIG_FILEPATH" | jq -r tostring)

    if "$INPUT_DRY_RUN"; then
        echo "::debug::Dry Run detected. Exiting."
        exit 0;
    fi

    # Register Prepare Task Definition
    RESPONSE=$(registerTaskDefinition "file://$TASK_DEFINITION_FILE")
    REVISION_ID=$(echo "$RESPONSE" | jq -r '.taskDefinition.revision // empty')
    FAMILY=$(echo "$RESPONSE" | jq -r '.taskDefinition.family // empty')

    if [ -z "$REVISION_ID" ] && [ -z "$FAMILY" ]; then
        echo -e "${RED}RevisionId and Family could not be extracted from register task definition call. Raw response is below:";
        echo -e "${RESPONSE}";
        exit 1;
    fi

    echo -e "${BLUE}Registered Prepare Task Definition (Revision): ${RESET_TEXT}$FAMILY ($REVISION_ID)"

    RUN_TASK_OUTPUT=$(runTask "${FAMILY}:${REVISION_ID}" "$JSON_NETWORK_CONFIG")
    TASK_ARN=$(echo "$RUN_TASK_OUTPUT" | jq -r '.tasks[].taskArn')

    if [ -z "$TASK_ARN" ]; then
        echo -e "${RED}Task ARN could not be obtained. Raw response is below:";
        echo -e "${RUN_TASK_OUTPUT}";
        exit 1;
    fi

    echo -e "${BLUE}Task has been started: ${RESET_TEXT}$TASK_ARN"
    echo -e "No output is provided, but polling has begun.";
    waitOnTask "$TASK_ARN"

    TASK_RESPONSE=$(describeTask "$TASK_ARN")
    if echo "$TASK_RESPONSE" | jq -e '.tasks[0].containers[] | select((.exitCode // 255) != 0)' > /dev/null; then
        EXIT_CODE=$(echo "$TASK_RESPONSE" | jq -r '.tasks[0].containers[] | select((.exitCode // 255) != 0) | .exitCode // 255')

        echo -e "${RED}Task returned non-zero exit code: ${RESET_TEXT}$EXIT_CODE. Raw response is below:";
        echo -e "${TASK_RESPONSE}"
        exit 1;
    else
        echo -e "${GREEN}Task has executed successfully.";
    fi
fi

# Prepare Main Task Definition for editing
modifyTaskDefinitionFile "$INPUT_SERVICE_TASK_DEFINITION_NAME" "$INPUT_SERVICE_CONTAINER_IMAGE_CHANGES"

if "$INPUT_DRY_RUN"; then
    echo "::debug::Dry Run detected. Exiting."
    exit 0;
fi

# Register Task Definition
RESPONSE=$(registerTaskDefinition "file://$TASK_DEFINITION_FILE")
REVISION_ID=$(echo "$RESPONSE" | jq -r '.taskDefinition.revision // empty')
FAMILY=$(echo "$RESPONSE" | jq -r '.taskDefinition.family // empty')

if [ -z "$REVISION_ID" ] && [ -z "$FAMILY" ]; then
    echo -e "${RED}RevisionId and Family could not be extracted from register task definition call. Raw response is below:";
    echo -e "${RESPONSE}";
    exit 1;
fi

echo -e "${BLUE}Registered Task Definition (Revision): ${RESET_TEXT}$FAMILY ($REVISION_ID)"

# Update Service
echo -e "${BLUE}Updating cluster: ${RESET_TEXT}$INPUT_ECS_CLUSTER_NAME${BLUE}, within service: ${RESET_TEXT}$INPUT_ECS_SERVICE_NAME";
UPDATE_RESPONSE=$(updateService "${FAMILY}:${REVISION_ID}")

DEPLOYMENT_ID=$(echo "$UPDATE_RESPONSE" | jq -r '.service.deployments[0]?.id // empty')
DEPLOYMENT_MESSAGE=$(echo "$UPDATE_RESPONSE" | jq -r '.service.deployments[0]?.rolloutStateReason // empty')
LAST_EVENT_DATE=$(echo "$UPDATE_RESPONSE" | jq -r '.service.events[0]?.createdAt // empty')

if [ -z "$DEPLOYMENT_ID" ] && [ -z "$DEPLOYMENT_MESSAGE" ]; then
    echo -e "${RED}Service Id could not be extracted from update-service call. Raw response is below:";
    echo -e "${UPDATE_RESPONSE}";
    echo -e "${RESET_TEXT}Stopping GitHub Action job as status can not be determined to safely proceed.";
    exit 1;
fi

# Be sure we only emit this if the user is intending to wait on deployment.
if [ -z "$LAST_EVENT_DATE" ]; then
    echo -e "${ORANGE}There were no events found on this service. This means we cannot identify what events to ignore";
    echo -e "${BLUE}This will be expected if no deploys, otherwise if not - you will see events from the past.";
fi

echo -e "${DEPLOYMENT_MESSAGE}";

# Start polling
if [ "$INPUT_MAX_POLLING_ITERATIONS" -eq "0" ]; then
    echo -e "${BLUE}Iterations at 0. GitHub Action ending, but service update in-progress to: ${RESET_TEXT}$INPUT_ECS_CLUSTER_NAME${BLUE}, within service: ${RESET_TEXT}$INPUT_ECS_SERVICE_NAME.";
else
    sleep 5;
    pollForSpecificServiceUpdate "$DEPLOYMENT_ID" "$LAST_EVENT_DATE"
    echo -e "${GREEN}Cluster updated: ${RESET_TEXT}$INPUT_ECS_CLUSTER_NAME${BLUE}, within service: ${RESET_TEXT}$INPUT_ECS_SERVICE_NAME!";
fi

exit 0;
