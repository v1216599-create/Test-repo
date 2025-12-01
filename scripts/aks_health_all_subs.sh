#!/bin/bash
set -e

REPORT_DIR="reports"
mkdir -p $REPORT_DIR

INDEX_FILE="$REPORT_DIR/index.html"
echo "<html><head><style>
body { font-family: Arial; }
h1 { color:#2c3e50; }
table { width:100%; border-collapse: collapse; margin-bottom:20px; }
th, td { border:1px solid #ccc; padding:8px; text-align:left; }
th { background:#f7f7f7; }
.ok { background:#d4edda; }
.warn { background:#fff3cd; }
.bad { background:#f8d7da; }
</style></head><body>" > $INDEX_FILE

echo "<h1>AKS Daily Health Summary</h1>" >> $INDEX_FILE
echo "<table><tr><th>Subscription</th><th>Cluster</th><th>Status</th><th>Report</th></tr>" >> $INDEX_FILE

echo "[INFO] Fetching all subscriptions..."
SUBS=$(az account list --query "[].id" -o tsv)

for SUB in $SUBS; do
    az account set --subscription "$SUB"

    CLUSTERS=$(az aks list --query "[].{name:name, rg:resourceGroup}" -o json)
    if [[ $(echo $CLUSTERS | jq length) -eq 0 ]]; then continue; fi

    for row in $(echo "${CLUSTERS}" | jq -r '.[] | @base64'); do

        _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }

        CLUSTER_NAME=$(_jq '.name')
        CLUSTER_RG=$(_jq '.rg')

        echo "[INFO] Processing Cluster: $CLUSTER_NAME"

        az aks get-credentials -g "$CLUSTER_RG" -n "$CLUSTER_NAME" --overwrite-existing

        REPORT_FILE="${SUB}_${CLUSTER_NAME}_health.html"
        REPORT_PATH="$REPORT_DIR/$REPORT_FILE"

        ###############################
        # HEALTH CHECKS
        ###############################

        # Node Health
        NODE_NOT_READY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1}')
        if [[ -z "$NODE_NOT_READY" ]]; then NODE_STATUS="Healthy"; NODE_CLASS="ok"; else NODE_STATUS="Unhealthy"; NODE_CLASS="bad"; fi

        # Pods in CrashLoopBackOff
        CRASH_PODS=$(kubectl get pods --all-namespaces | grep -i crashloop || true)
        if [[ -z "$CRASH_PODS" ]]; then POD_STATUS="Healthy"; POD_CLASS="ok"; else POD_STATUS="CrashLoop"; POD_CLASS="bad"; fi

        # Upgrades available
        VERSION_INFO=$(az aks get-upgrades -g "$CLUSTER_RG" -n "$CLUSTER_NAME" --query controlPlaneProfile.upgrades[].kubernetesVersion -o tsv)
        if [[ -n "$VERSION_INFO" ]]; then UPGRADE_STATUS="Upgrade Available"; UPGRADE_CLASS="warn"; else UPGRADE_STATUS="Up-to-date"; UPGRADE_CLASS="ok"; fi

        # Metrics server check
        if kubectl top nodes &>/dev/null; then METRICS="Installed"; METRICS_CLASS="ok"; else METRICS="Not Installed"; METRICS_CLASS="warn"; fi

        # HPA Check
        HPA_COUNT=$(kubectl get hpa --all-namespaces --no-headers | wc -l)
        if [[ "$HPA_COUNT" -gt 0 ]]; then HPA_STATUS="$HPA_COUNT HPAs"; HPA_CLASS="ok"; else HPA_STATUS="No HPA"; HPA_CLASS="warn"; fi

        # PDB Check
        PDB_COUNT=$(kubectl get pdb --all-namespaces --no-headers | wc -l)
        if [[ "$PDB_COUNT" -gt 0 ]]; then PDB_STATUS="$PDB_COUNT PDBs"; PDB_CLASS="ok"; else PDB_STATUS="No PDB"; PDB_CLASS="warn"; fi

        # PVC Health
        PVC_FAILED=$(kubectl get pvc --all-namespaces | grep -i failed || true)
        if [[ -z "$PVC_FAILED" ]]; then PVC_STATUS="Healthy"; PVC_CLASS="ok"; else PVC_STATUS="Failed PVCs"; PVC_CLASS="bad"; fi

        # Ingress Health
        INGRESS_COUNT=$(kubectl get ingress --all-namespaces --no-headers 2>/dev/null | wc -l)
        if [[ "$INGRESS_COUNT" -gt 0 ]]; then INGRESS_STATUS="$INGRESS_COUNT Ingresses"; INGRESS_CLASS="ok"; else INGRESS_STATUS="No Ingress"; INGRESS_CLASS="warn"; fi

        # Combine overall status
        if [[ "$NODE_STATUS" == "Unhealthy" || "$POD_STATUS" == "CrashLoop" || "$PVC_STATUS" == "Failed PVCs" ]]; then
            OVERALL_STATUS="Unhealthy"
            OVERALL_CLASS="bad"
        elif [[ "$UPGRADE_STATUS" == "Upgrade Available" ]]; then
            OVERALL_STATUS="Warning"
            OVERALL_CLASS="warn"
        else
            OVERALL_STATUS="Healthy"
            OVERALL_CLASS="ok"
        fi

        ##############################################
        # GENERATE REPORT
        ##############################################

        echo "<html><body><h1>AKS Health Report - $CLUSTER_NAME</h1>" > "$REPORT_PATH"

        # Summary Table
        echo "<h2>Summary</h2>
        <table>
            <tr><th>Check</th><th>Status</th></tr>
            <tr class=\"$NODE_CLASS\"><td>Node Health</td><td>$NODE_STATUS</td></tr>
            <tr class=\"$POD_CLASS\"><td>Pod Status</td><td>$POD_STATUS</td></tr>
            <tr class=\"$UPGRADE_CLASS\"><td>Upgrade Status</td><td>$UPGRADE_STATUS</td></tr>
            <tr class=\"$METRICS_CLASS\"><td>Metrics Server</td><td>$METRICS</td></tr>
            <tr class=\"$HPA_CLASS\"><td>HPA</td><td>$HPA_STATUS</td></tr>
            <tr class=\"$PDB_CLASS\"><td>PDB</td><td>$PDB_STATUS</td></tr>
            <tr class=\"$PVC_CLASS\"><td>PVC Health</td><td>$PVC_STATUS</td></tr>
            <tr class=\"$INGRESS_CLASS\"><td>Ingress</td><td>$INGRESS_STATUS</td></tr>
        </table>" >> "$REPORT_PATH"

        # Detailed Data
        echo "<h2>Node List</h2><pre>" >> "$REPORT_PATH"
        kubectl get nodes -o wide >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "<h2>Pods</h2><pre>" >> "$REPORT_PATH"
        kubectl get pods --all-namespaces -o wide >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "<h2>Node CPU/Memory</h2><pre>" >> "$REPORT_PATH"
        kubectl top nodes >> "$REPORT_PATH" 2>/dev/null || echo "Metrics server missing" >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "<h2>Pod CPU/Memory</h2><pre>" >> "$REPORT_PATH"
        kubectl top pods --all-namespaces >> "$REPORT_PATH" 2>/dev/null || echo "Metrics server missing" >> "$REPORT_PATH"
        echo "</pre>" >> "$REPORT_PATH"

        echo "</body></html>" >> "$REPORT_PATH"

        # Add to summary index
        echo "<tr class=\"$OVERALL_CLASS\">
               <td>$SUB</td>
               <td>$CLUSTER_NAME</td>
               <td>$OVERALL_STATUS</td>
               <td><a href=\"$REPORT_FILE\">View Report</a></td>
              </tr>" >> $INDEX_FILE

    done
done

echo "</table>" >> $INDEX_FILE
echo "</body></html>" >> $INDEX_FILE

echo "[INFO] All reports generated with enhancements."
