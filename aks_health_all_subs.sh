#!/bin/bash
set -e

mkdir -p reports

echo "[INFO] Fetching all subscriptions..."
SUBS=$(az account list --query "[].id" -o tsv)

for SUB in $SUBS; do
    echo "------------------------------------------------"
    echo "[INFO] Switching to subscription: $SUB"
    echo "------------------------------------------------"
    az account set --subscription "$SUB"

    echo "[INFO] Getting AKS clusters..."
    CLUSTERS=$(az aks list --query "[].{name:name, rg:resourceGroup}" -o json)

    if [[ $(echo $CLUSTERS | jq length) -eq 0 ]]; then
        echo "[INFO] No AKS clusters found in subscription $SUB"
        continue
    fi

    for row in $(echo "${CLUSTERS}" | jq -r '.[] | @base64'); do
        _jq() {
            echo "${row}" | base64 --decode | jq -r "${1}"
        }

        CLUSTER_NAME=$(_jq '.name')
        CLUSTER_RG=$(_jq '.rg')

        echo ""
        echo "==============================================="
        echo "[INFO] Processing Cluster: $CLUSTER_NAME"
        echo "==============================================="

        az aks get-credentials -g "$CLUSTER_RG" -n "$CLUSTER_NAME" --overwrite-existing

        REPORT="reports/${SUB}_${CLUSTER_NAME}_health.html"
        echo "<html><body>" > "$REPORT"
        echo "<h1>AKS Health Report: $CLUSTER_NAME</h1>" >> "$REPORT"
        echo "<h2>Subscription: $SUB</h2>" >> "$REPORT"

        echo "<h3>Cluster Info</h3><pre>" >> "$REPORT"
        az aks show -g "$CLUSTER_RG" -n "$CLUSTER_NAME" -o table >> "$REPORT"
        echo "</pre>" >> "$REPORT"

        echo "<h3>Node Health</h3><pre>" >> "$REPORT"
        kubectl get nodes -o wide >> "$REPORT"
        echo "</pre>" >> "$REPORT"

        echo "<h3>Node CPU/Memory</h3><pre>" >> "$REPORT"
        kubectl top nodes >> "$REPORT" || echo "Metrics server not installed" >> "$REPORT"
        echo "</pre>" >> "$REPORT"

        echo "<h3>Pods (All Namespaces)</h3><pre>" >> "$REPORT"
        kubectl get pods --all-namespaces -o wide >> "$REPORT"
        echo "</pre>" >> "$REPORT"

        echo "<h3>Pod CPU/Memory</h3><pre>" >> "$REPORT"
        kubectl top pods --all-namespaces >> "$REPORT" || echo "Metrics server not installed" >> "$REPORT"
        echo "</pre>" >> "$REPORT"

        echo "<h3>Kubernetes Versions</h3><pre>" >> "$REPORT"
        kubectl version --short >> "$REPORT"
        echo "</pre>" >> "$REPORT"

        echo "</body></html>" >> "$REPORT"

        echo "[INFO] Report created: $REPORT"
    done
done

echo "[INFO] All reports generated in reports/ folder."
