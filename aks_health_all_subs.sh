#!/bin/bash
set -e

REPORT_DIR="reports"
mkdir -p $REPORT_DIR

INDEX_FILE="$REPORT_DIR/index.html"
echo "<html><body>" > $INDEX_FILE
echo "<h1>AKS Health Scan Results</h1>" >> $INDEX_FILE
echo "<ul>" >> $INDEX_FILE

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

        REPORT_FILE="${SUB}_${CLUSTER_NAME}_health.html"
        REPORT_PATH="$REPORT_DIR/$REPORT_FILE"

        echo "<html><body>" > "$REPORT_PATH"
        echo "<h1>AKS Health Report - $CLUSTER_NAME</h1>" >> "$REPORT_PATH"
        echo "<h3>Subscription: $SUB</h3>" >> "$REPORT_PATH"

        echo "<h3>Cluster Info</h3><pre>" >> "$REPORT_PATH"
        az aks show -g "$CLUSTER_RG" -n "$CLUSTER_NAME" -o yaml >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "<h3>Node List</h3><pre>" >> "$REPORT_PATH"
        kubectl get nodes -o wide >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "<h3>Node CPU/Memory Usage</h3><pre>" >> "$REPORT_PATH"
        kubectl top nodes >> "$REPORT_PATH" || echo "Metrics server not installed" >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "<h3>Pods (All Namespaces)</h3><pre>" >> "$REPORT_PATH"
        kubectl get pods --all-namespaces -o wide >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "<h3>Pod CPU/Memory Usage</h3><pre>" >> "$REPORT_PATH"
        kubectl top pods --all-namespaces >> "$REPORT_PATH" || echo "Metrics server not installed" >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "<h3>Kubernetes Version</h3><pre>" >> "$REPORT_PATH"
        kubectl version --output=yaml >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "</body></html>" >> "$REPORT_PATH"

        echo "[INFO] Report created: $REPORT_PATH"

        # Add link to index
        echo "<li><a href=\"$REPORT_FILE\">$CLUSTER_NAME ($SUB)</a></li>" >> $INDEX_FILE

    done
done

echo "</ul>" >> $INDEX_FILE
echo "<p>Generated on: $(date)</p>" >> $INDEX_FILE
echo "</body></html>" >> $INDEX_FILE

echo "[INFO] Master index created: $INDEX_FILE"
