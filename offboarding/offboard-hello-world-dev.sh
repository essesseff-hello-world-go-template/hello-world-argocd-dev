#!/bin/bash
set -e

# Templated variables - replaced at onboarding
APP_NAME="hello-world"
NAMESPACE="essesseff-hello-world-go-template"
ENV="dev"  # or qa, staging, prod
GITHUB_REPO_ID="{{REPOSITORY_ID}}"

# Argo CD application names
APP_OF_APPS="${APP_NAME}-argocd-${ENV}"
CHILD_APP="${APP_NAME}-${ENV}"

echo "=========================================="
echo "Offboarding Deployment: ${APP_NAME}-${ENV}"
echo "Namespace: ${NAMESPACE}"
echo "GitHub Repo ID: ${GITHUB_REPO_ID}"
echo "=========================================="
echo ""
echo "App-of-Apps Pattern:"
echo "  Parent: ${APP_OF_APPS}"
echo "  Child:  ${CHILD_APP}"
echo ""

# Delete the parent Argo CD Application (app-of-apps)
echo "Deleting parent Argo CD Application (app-of-apps): ${APP_OF_APPS}..."
if kubectl get application ${APP_OF_APPS} -n argocd &>/dev/null; then
    kubectl delete application ${APP_OF_APPS} -n argocd --ignore-not-found=true
    echo "✓ Parent application ${APP_OF_APPS} deleted"
    
    # Wait for parent to be removed
    echo "Waiting for parent application to finalize..."
    kubectl wait --for=delete application/${APP_OF_APPS} -n argocd --timeout=60s || true
else
    echo "⚠ Parent application ${APP_OF_APPS} not found (may already be deleted)"
fi

# Verify child application is also deleted (should cascade from parent)
echo ""
echo "Verifying child application ${CHILD_APP} is removed..."
sleep 5  # Give Argo CD a moment to cascade delete

if kubectl get application ${CHILD_APP} -n argocd &>/dev/null; then
    echo "⚠ Child application ${CHILD_APP} still exists, deleting explicitly..."
    kubectl delete application ${CHILD_APP} -n argocd --ignore-not-found=true
    kubectl wait --for=delete application/${CHILD_APP} -n argocd --timeout=300s || true
    echo "✓ Child application ${CHILD_APP} deleted"
else
    echo "✓ Child application ${CHILD_APP} automatically removed by parent deletion"
fi

# Wait for Argo CD to clean up managed resources
echo ""
echo "Waiting for Argo CD to finalize resource cleanup..."
sleep 10

# Clean up Argo CD repository secrets
echo ""
echo "Cleaning up Argo CD repository secrets..."

# Delete argocd repo secret
if kubectl get secret ${APP_NAME}-argocd-${ENV}-repo -n argocd &>/dev/null; then
    kubectl delete secret ${APP_NAME}-argocd-${ENV}-repo -n argocd
    echo "✓ Deleted secret '${APP_NAME}-argocd-${ENV}-repo'"
else
    echo "⚠ Secret '${APP_NAME}-argocd-${ENV}-repo' not found"
fi

# Delete config repo secret
if kubectl get secret ${APP_NAME}-config-${ENV}-repo -n argocd &>/dev/null; then
    kubectl delete secret ${APP_NAME}-config-${ENV}-repo -n argocd
    echo "✓ Deleted secret '${APP_NAME}-config-${ENV}-repo'"
else
    echo "⚠ Secret '${APP_NAME}-config-${ENV}-repo' not found"
fi

# Clean up Argo CD Notifications ConfigMap entries
echo ""
echo "Cleaning up Argo CD Notifications ConfigMap entries..."

if kubectl get configmap argocd-notifications-cm -n argocd &>/dev/null; then
    echo "Removing repo-specific webhook service..."
    
    # Remove webhook service for this repository
    kubectl patch configmap argocd-notifications-cm -n argocd --type=json \
        -p="[{'op': 'remove', 'path': '/data/service.webhook.webhook-${GITHUB_REPO_ID}'}]" \
        2>/dev/null || echo "  (service.webhook.webhook-${GITHUB_REPO_ID} not found or already removed)"
    
    # Remove subscription for this repository
    echo "Removing webhook subscription for configenvrepoid=${GITHUB_REPO_ID}..."
    
    # Get current subscriptions
    CURRENT_SUBSCRIPTIONS=$(kubectl get configmap argocd-notifications-cm -n argocd -o jsonpath='{.data.subscriptions}' 2>/dev/null || echo "")
    
    if [ -n "$CURRENT_SUBSCRIPTIONS" ] && [ "$CURRENT_SUBSCRIPTIONS" != "null" ]; then
        # Remove the subscription block for this repository ID using awk
        # This removes the entire subscription entry that contains "webhook-${GITHUB_REPO_ID}"
        FILTERED_SUBSCRIPTIONS=$(echo "$CURRENT_SUBSCRIPTIONS" | awk -v webhook="webhook-${GITHUB_REPO_ID}" -v repoid="${GITHUB_REPO_ID}" '
        BEGIN { in_block=0; block="" }
        /^- recipients:/ { 
            if (in_block && block !~ webhook && block !~ ("configenvrepoid=" repoid)) {
                printf "%s", block
            }
            in_block=1
            block=$0 "\n"
            next
        }
        {
            if (in_block) {
                block = block $0 "\n"
            } else {
                print
            }
        }
        END {
            if (in_block && block !~ webhook && block !~ ("configenvrepoid=" repoid)) {
                printf "%s", block
            }
        }')
        
        # Create temporary patch file
        TEMP_PATCH=$(mktemp)
        
        # Escape the YAML content for JSON
        if command -v jq &> /dev/null; then
            ESCAPED_SUBS=$(printf '%s' "$FILTERED_SUBSCRIPTIONS" | jq -Rs . | sed 's/^"//;s/"$//')
        elif command -v python3 &> /dev/null; then
            ESCAPED_SUBS=$(printf '%s' "$FILTERED_SUBSCRIPTIONS" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read())[1:-1])")
        else
            ESCAPED_SUBS=$(printf '%s' "$FILTERED_SUBSCRIPTIONS" | \
                awk 'BEGIN{ORS=""} {gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); if (NR>1) printf "\\n"; printf "%s", $0}')
        fi
        
        cat > "$TEMP_PATCH" <<EOF
{
  "data": {
    "subscriptions": "${ESCAPED_SUBS}"
  }
}
EOF
        
        # Patch the subscriptions field
        kubectl patch configmap argocd-notifications-cm -n argocd \
            --type merge \
            --patch-file "$TEMP_PATCH"
        
        # Clean up
        rm -f "$TEMP_PATCH"
        
        echo "✓ Removed subscription for 'webhook-${GITHUB_REPO_ID}'"
    else
        echo "⚠ No subscriptions found in ConfigMap"
    fi
    
    echo "✓ Notification ConfigMap entries cleaned up"
    echo "  Note: Shared templates and triggers (app-sync-status, on-sync-started, etc.) are preserved for other apps"
else
    echo "⚠ argocd-notifications-cm not found in argocd namespace"
fi

# Clean up Argo CD Notifications Secret entries
echo ""
echo "Cleaning up Argo CD Notifications Secret entries..."

if kubectl get secret argocd-notifications-secret -n argocd &>/dev/null; then
    echo "Removing namespace and repo-specific notification secrets..."
    
    # DO NOT remove argocd-webhook-url - it's shared across all apps
    echo "  ⊘ Preserving shared 'argocd-webhook-url'"
    
    # Remove app secret for this repo (repository-specific)
    kubectl patch secret argocd-notifications-secret -n argocd --type=json \
        -p="[{'op': 'remove', 'path': '/data/app-secret-${GITHUB_REPO_ID}'}]" \
        2>/dev/null && echo "  ✓ Removed 'app-secret-${GITHUB_REPO_ID}'" \
        || echo "  ⚠ 'app-secret-${GITHUB_REPO_ID}' not found or already removed"
    
    echo "✓ Notification Secret entries cleaned up"
else
    echo "⚠ argocd-notifications-secret not found in argocd namespace"
fi

# Restart notification controller to reload configuration
echo ""
echo "🔄 Restarting notifications controller to reload configuration..."
kubectl rollout restart deploy argocd-notifications-controller -n argocd

# Remove any ConfigMaps or Secrets specific to this deployment
echo ""
echo "Cleaning up deployment-specific ConfigMaps and Secrets..."
kubectl delete configmap -n ${NAMESPACE} -l app=${APP_NAME} --ignore-not-found=true
kubectl delete secret -n ${NAMESPACE} -l app=${APP_NAME} --ignore-not-found=true

echo ""
echo "=========================================="
echo "✅ Deployment offboarding complete"
echo "=========================================="
echo ""
echo "Cleaned up:"
echo "  ✓ Argo CD App-of-Apps: ${APP_OF_APPS}"
echo "  ✓ Argo CD Child Application: ${CHILD_APP}"
echo "  ✓ Argo CD repository secrets: ${APP_NAME}-argocd-${ENV}-repo, ${APP_NAME}-config-${ENV}-repo"
echo "  ✓ Webhook service: webhook-${GITHUB_REPO_ID}"
echo "  ✓ Webhook subscription for repo ${GITHUB_REPO_ID}"
echo "  ✓ App secret: app-secret-${GITHUB_REPO_ID}"
echo ""
echo "Preserved (shared across apps):"
echo "  • Webhook URL: argocd-webhook-url"
echo "  • Template: app-sync-status"
echo "  • Triggers: on-sync-started, on-sync-succeeded, on-sync-failed, on-deployed, on-health-degraded"
echo ""
echo "Note: Namespace '${NAMESPACE}' still exists."
echo "To remove the entire namespace, run: ./offboard-namespace.sh"
