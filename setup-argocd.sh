#!/bin/bash
# setup-argocd.sh
# Setup Argo CD for hello-world DEV

set -e

echo "=========================================="
echo "Setting up Argo CD for hello-world DEV"
echo "=========================================="

# Check if ghcr-credentials-secret.yaml exists
if [ ! -f "ghcr-credentials-secret.yaml" ]; then
  echo "❌ Error: ghcr-credentials-secret.yaml not found"
  echo "Please ensure ghcr-credentials-secret.yaml exists and has the correct secret for essesseff-hello-world-go-template"
  echo ""
  read -p "Continue anyway (for example, in the case of ghcr-credentials having been previously applied on this K8s cluster)? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted"
    exit 1
  fi
fi

# Check if argocd-repository-secret.yaml exists
if [ ! -f "argocd-repository-secret.yaml" ]; then
  echo "❌ Error: argocd-repository-secret.yaml not found"
  echo "Please ensure argocd-repository-secret.yaml exists and has the correct secrets for hello-world"
  exit 1
fi

# Check if notifications-secret.yaml exists
if [ ! -f "notifications-secret.yaml" ]; then
  echo "❌ Error: notifications-secret.yaml not found"
  echo "Please request essesseff provide your notifications-secret.yaml first for hello-world (or if not using essesseff, you can create a \"dummy\" notifications-secret.yaml)"
  exit 1
fi

# Check if notifications-configmap.yaml exists
if [ ! -f "notifications-configmap.yaml" ]; then
  echo "❌ Error: notifications-configmap.yaml not found"
  exit 1
fi

# Warning about secrets
echo ""
echo "⚠️  WARNING: You are about to apply secrets to your cluster for essesseff-hello-world-go-template organization and hello-world DEV"
echo ""
echo "Make sure ghcr-credentials-secret.yaml contains the correct secrets for essesseff-hello-world-go-template"
echo "Make sure argocd-repository-secret.yaml and notifications-secret.yaml contain the correct secrets for hello-world"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted"
  exit 1
fi

# Apply secrets
if [ -f "ghcr-credentials-secret.yaml" ]; then
  echo ""
  echo "📝 Applying GHCR image pull secrets..."
  kubectl apply -f ghcr-credentials-secret.yaml
fi
echo ""
echo "📝 Applying config repo secrets..."
kubectl apply -f argocd-repository-secret.yaml
echo ""
echo "📝 Applying notification secrets..."
kubectl apply -f notifications-secret.yaml

# Apply configmap
echo "📝 Applying notification configmap..."
kubectl apply -f notifications-configmap.yaml

# Ensure controller uses the correct ConfigMap/Secret
kubectl patch deploy argocd-notifications-controller -n argocd \
  -p '{
    "spec": {
      "template": {
        "spec": {
          "containers": [{
            "name": "argocd-notifications-controller",
            "env": [
              {"name": "NOTIFICATIONS_CM_NAME", "value": "argocd-notifications-cm"},
              {"name": "NOTIFICATIONS_SECRET_NAME", "value": "argocd-notifications-secret"}
            ]
          }]
        }
      }
    }
  }'

# Restart controller to reload config
kubectl rollout restart deploy argocd-notifications-controller -n argocd

# Verify configuration
echo ""
echo "✅ Verifying configuration..."

# Check if secrets exist
if kubectl get secret ghcr-credentials -n essesseff-hello-world-go-template &> /dev/null; then
  echo "  ✓ Secret 'ghcr-credentials' exists"
else
  echo "  ✗ Secret 'ghcr-credentials' not found"
  exit 1
fi
if kubectl get secret hello-world-argocd-dev-repo -n argocd &> /dev/null; then
  echo "  ✓ Secret 'hello-world-argocd-dev-repo' exists"
else
  echo "  ✗ Secret 'hello-world-argocd-dev-repo' not found"
  exit 1
fi
if kubectl get secret hello-world-config-dev-repo -n argocd &> /dev/null; then
  echo "  ✓ Secret 'hello-world-config-dev-repo' exists"
else
  echo "  ✗ Secret 'hello-world-config-dev-repo' not found"
  exit 1
fi
if kubectl get secret argocd-notifications-secret -n argocd &> /dev/null; then
  echo "  ✓ Secret 'argocd-notifications-secret' exists"
else
  echo "  ✗ Secret 'argocd-notifications-secret' not found"
  exit 1
fi

# Check if configmap exists
if kubectl get configmap argocd-notifications-cm -n argocd &> /dev/null; then
  echo "  ✓ ConfigMap 'argocd-notifications-cm' exists"
else
  echo "  ✗ ConfigMap 'argocd-notifications-cm' not found"
  exit 1
fi

# Check if webhook service is configured
if kubectl get configmap argocd-notifications-cm -n argocd -o yaml | grep -q "service.webhook.webhook-hello-world"; then
  echo "  ✓ Webhook service 'webhook-hello-world' configured"
else
  echo "  ✗ Webhook service 'webhook-hello-world' not configured"
  exit 1
fi

# Check if notification controller is running
if kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-notifications-controller | grep -q "Running"; then
  echo "  ✓ Notification controller is running"
else
  echo "  ⚠️  Warning: Notification controller may not be running"
  echo "     Check: kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-notifications-controller"
fi

# Check if app-of-apps.yaml exists
if [ ! -f "app-of-apps.yaml" ]; then
  echo "❌ Error: app-of-apps.yaml not found"
  exit 1
fi

# Check if argocd/hello-world-dev-application.yaml exists
if [ ! -f "argocd/hello-world-dev-application.yaml" ]; then
  echo "❌ Error: argocd/hello-world-dev-application.yaml not found"
  exit 1
fi

# Apply app-of-apps for DEV
echo "📝 Applying app-of-apps for DEV..."
kubectl apply -f app-of-apps.yaml

echo ""
echo "=============================================="
echo "✅ Argo CD for hello-world DEV setup complete!"
echo "=============================================="
echo ""
echo "!!!REMEMBER TO DELETE YOUR SECRETS YAMLS -- DO *NOT* COMMIT THEM TO GITHUB!!!"
