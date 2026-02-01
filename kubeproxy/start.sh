#!/bin/bash

# Default namespace
NAMESPACE=${1:-default}
# Default context (use current if not specified)
CONTEXT=${2:-$(kubectl config current-context)}

export KUBE_NAMESPACE=$NAMESPACE

echo "=== Local K8s Service Proxy ==="
echo "Target Context:   $CONTEXT"
echo "Target Namespace: $KUBE_NAMESPACE"

# --- Dependency Check ---

if ! command -v caddy &> /dev/null; then
    echo "❌ Error: caddy is not installed."
    echo "Please install Caddy first: https://caddyserver.com/docs/install"
    echo "Or via Homebrew: brew install caddy"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "❌ Error: kubectl is not installed. Please install it first."
    exit 1
fi

# --- Generate Hosts File & Caddyfile ---
echo "📝 Generating configuration files..."
HOSTS_FILE="./proxy.hosts"
CADDY_FILE="./Caddyfile.dynamic"

echo "# Kubernetes Hosts for Context: $CONTEXT Namespace: $NAMESPACE" > $HOSTS_FILE

# Initialize Caddyfile
cat <<EOF > $CADDY_FILE
{
    auto_https off
}

:80 {
EOF

# Get Services
echo "   - Fetching Services..."
kubectl --context "$CONTEXT" -n "$NAMESPACE" get services -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read svc; do
    # Add to Hosts: 127.0.0.1 svcname.svc svcname
    echo "127.0.0.1 $svc.svc $svc" >> $HOSTS_FILE
    
    # Add to Caddyfile
    cat <<EOF >> $CADDY_FILE
    # Service: $svc
    @svc_$svc host $svc.svc $svc
    handle @svc_$svc {
        rewrite * /api/v1/namespaces/$NAMESPACE/services/$svc/proxy{uri}
        reverse_proxy localhost:8001 {
            header_up Host localhost:8001
        }
    }
EOF
done

# Get Pods
echo "   - Fetching Pods..."
kubectl --context "$CONTEXT" -n "$NAMESPACE" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read pod; do
    # Add to Hosts: 127.0.0.1 podname.pod podname
    echo "127.0.0.1 $pod.pod $pod" >> $HOSTS_FILE

    # Add to Caddyfile
    cat <<EOF >> $CADDY_FILE
    # Pod: $pod
    @pod_$pod host $pod.pod $pod
    handle @pod_$pod {
        rewrite * /api/v1/namespaces/$NAMESPACE/pods/$pod/proxy{uri}
        reverse_proxy localhost:8001 {
            header_up Host localhost:8001
        }
    }
EOF
done

# Close Caddyfile block
cat <<EOF >> $CADDY_FILE
    # Fallback
    handle {
        respond "Host {host} not recognized as a valid Service or Pod in namespace $NAMESPACE" 404
    }
}
EOF

echo "✅ Hosts file generated at: $HOSTS_FILE"
echo "✅ Caddyfile generated at: $CADDY_FILE"

# --- Runtime Management ---

# Cleanup function
cleanup() {
    echo ""
    echo "Stopping background processes..."
    if [ -n "$KUBECTL_PID" ]; then
        kill $KUBECTL_PID 2>/dev/null
    fi
    # Remove temporary Caddyfile if desired, or keep for debugging
    # rm $CADDY_FILE
    echo "Done."
    exit
}

# Trap signals
trap cleanup SIGINT SIGTERM

# Start kubectl proxy
echo "🚀 Starting kubectl proxy on port 8001..."
kubectl --context "$CONTEXT" proxy --port=8001 --accept-hosts='^localhost$,^127\.0\.0\.1$' &
KUBECTL_PID=$!

# Wait a moment for proxy to start
sleep 2

# Check if kubectl proxy is running
if ! kill -0 $KUBECTL_PID 2>/dev/null; then
    echo "❌ Error: kubectl proxy failed to start."
    echo "   Check if port 8001 is already in use or if your kubeconfig is valid."
    exit 1
fi

# Start Caddy
echo "🚀 Starting Caddy on port 80..."
echo "ℹ️  Note: If this fails with 'permission denied', run this script with 'sudo -E'."
echo ""
echo "🔗 Access Services via: http://<service-name> or http://<service-name>.svc"
echo "🔗 Access Pods via:     http://<pod-name> or http://<pod-name>.pod"
echo ""

caddy run --config $CADDY_FILE --adapter caddyfile

# If caddy stops, cleanup
cleanup
