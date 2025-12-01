#!/bin/bash
set -e

REPORT_DIR="reports"
mkdir -p $REPORT_DIR

############################################
# MASTER INDEX HTML (Dashboard)
############################################
INDEX_FILE="$REPORT_DIR/index.html"

echo "<html>
<head>
<title>AKS Health Dashboard</title>
<style>
body { font-family: Arial, sans-serif; margin: 20px; }
h1 { color:#2c3e50; }
h2 { color:#34495e; }

table {
    width: 100%; 
    border-collapse: collapse; 
    margin-bottom: 20px;
    font-size: 15px;
}
th, td {
    padding: 10px;
    border: 1px solid #ccc;
}
th {
    background: #f4f4f4;
}
.ok { background:#d4edda; color:#155724; }
.warn { background:#fff3cd; color:#856404; }
.bad { background:#f8d7da; color:#721c24; }

.collapsible {
    background-color: #f1f1f1;
    cursor: pointer;
    padding: 12px;
    width: 100%;
    border: none;
    text-align: left;
    outline: none;
    font-size: 16px;
}

.active, .collapsible:hover {
    background-color: #ddd;
}

.content {
    padding: 10px;
    display: none;
    border: 1px solid #ccc;
    margin-bottom: 15px;
    background:#fafafa;
}

pre {
    background:#f7f7f7;
    padding: 10px;
    border: 1px solid #ddd;
    overflow-x:auto;
}
</style>

<script>
document.addEventListener('DOMContentLoaded', function() {
    var coll = document.getElementsByClassName('collapsible');
    for (let i = 0; i < coll.length; i++) {
        coll[i].addEventListener('click', function() {
            this.classList.toggle('active');
            var content = this.nextElementSibling;
            content.style.display = content.style.display === 'block' ? 'none' : 'block';
        });
    }
});
</script>

</head>
<body>
<h1>AKS Health Dashboard</h1>
<table>
<tr><th>Subscription</th><th>Cluster</th><th>Status</th><th>Report</th></tr>
" > $INDEX_FILE


############################################
# FETCH ALL SUBSCRIPTIONS
############################################
echo "[INFO] Fetching all subscriptions..."
SUBS=$(az account list --query "[].id" -o tsv)


############################################
# LOOP OVER SUBSCRIPTIONS
############################################
for SUB in $SUBS; do

    az account set --subscription "$SUB"
    CLUSTERS=$(az aks list --query "[].{name:name, rg:resourceGroup}" -o json)

    if [[ $(echo $CLUSTERS | jq length) -eq 0 ]]; then 
        continue 
    fi

    for row in $(echo "${CLUSTERS}" | jq -r '.[] | @base64'); do
        
        # JSON decode helper
        _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }

        CLUSTER_NAME=$(_jq '.name')
        CLUSTER_RG=$(_jq '.rg')

        echo "[INFO] Processing cluster: $CLUSTER_NAME ($SUB)"

        az aks get-credentials -g "$CLUSTER_RG" -n "$CLUSTER_NAME" --overwrite-existing


        ############################################
        # HEALTH CHECKS
        ############################################

        NODE_NOT_READY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1}')
        CRASH_PODS=$(kubectl get pods --all-namespaces | grep -i crashloop || true)
        VERSION_INFO=$(az aks get-upgrades -g "$CLUSTER_RG" -n "$CLUSTER_NAME" --query controlPlaneProfile.upgrades[].kubernetesVersion -o tsv)
        PVC_FAILED=$(kubectl get pvc --all-namespaces 2>/dev/null | grep -i failed || true)
        INGRESS_COUNT=$(kubectl get ingress --all-namespaces --no-headers 2>/dev/null | wc -l)
        HPA_COUNT=$(kubectl get hpa --all-namespaces --no-headers 2>/dev/null | wc -l)
        PDB_COUNT=$(kubectl get pdb --all-namespaces --no-headers 2>/dev/null | wc -l)

        METRICS_WORKING=false
        if kubectl top nodes &>/dev/null; then METRICS_WORKING=true; fi


        ############################################
        # STATUS CLASSIFICATION
        ############################################

        # Node check
        if [[ -z "$NODE_NOT_READY" ]]; then NODE_STATUS="✓ Healthy"; NODE_CLASS="ok";
        else NODE_STATUS="✗ Unhealthy"; NODE_CLASS="bad"; fi

        # Pod check
        if [[ -z "$CRASH_PODS" ]]; then POD_STATUS="✓ Healthy"; POD_CLASS="ok";
        else POD_STATUS="✗ CrashLoop Detected"; POD_CLASS="bad"; fi

        # Upgrade check
        if [[ -n "$VERSION_INFO" ]]; then UPGRADE_STATUS="⚠ Upgrade Available"; UPGRADE_CLASS="warn";
        else UPGRADE_STATUS="✓ Up-to-date"; UPGRADE_CLASS="ok"; fi

        # Metrics
        if $METRICS_WORKING; then METRICS="✓ Installed"; METRICS_CLASS="ok";
        else METRICS="⚠ Missing"; METRICS_CLASS="warn"; fi

        # HPA
        if [[ "$HPA_COUNT" -gt 0 ]]; then HPA_STATUS="✓ $HPA_COUNT HPAs"; HPA_CLASS="ok";
        else HPA_STATUS="⚠ No HPA"; HPA_CLASS="warn"; fi

        # PDB
        if [[ "$PDB_COUNT" -gt 0 ]]; then PDB_STATUS="✓ $PDB_COUNT PDBs"; PDB_CLASS="ok";
        else PDB_STATUS="⚠ No PDB"; PDB_CLASS="warn"; fi

        # PVC
        if [[ -z "$PVC_FAILED" ]]; then PVC_STATUS="✓ Healthy"; PVC_CLASS="ok";
        else PVC_STATUS="✗ PVC Errors"; PVC_CLASS="bad"; fi

        # Ingress
        if [[ "$INGRESS_COUNT" -gt 0 ]]; then INGRESS_STATUS="✓ $INGRESS_COUNT Ingresses"; INGRESS_CLASS="ok";
        else INGRESS_STATUS="⚠ No Ingress"; INGRESS_CLASS="warn"; fi



        ############################################
        # OVERALL CLUSTER HEALTH
        ############################################
        if [[ "$NODE_CLASS" == "bad" || "$POD_CLASS" == "bad" || "$PVC_CLASS" == "bad" ]]; then
            OVERALL_STATUS="Unhealthy"
            OVERALL_CLASS="bad"
        elif [[ "$UPGRADE_CLASS" == "warn" || "$INGRESS_CLASS" == "warn" ]]; then
            OVERALL_STATUS="Warning"
            OVERALL_CLASS="warn"
        else
            OVERALL_STATUS="Healthy"
            OVERALL_CLASS="ok"
        fi


        ############################################
        # CREATE REPORT FILE
        ############################################
        REPORT_FILE="${SUB}_${CLUSTER_NAME}_health.html"
        REPORT_PATH="$REPORT_DIR/$REPORT_FILE"


        ###################### HTML HEADER ########################
        echo "<html>
<head>
<title>AKS Health Report - $CLUSTER_NAME</title>
<style>
body { font-family: Arial, sans-serif; margin: 20px; }
h1 { color:#2c3e50; }
h2 { color:#34495e; }
table { width: 100%; border-collapse: collapse; margin-bottom: 20px; font-size: 15px; }
th, td { padding: 10px; border: 1px solid #ccc; }
th { background: #f4f4f4; }
.ok { background:#d4edda; color:#155724; }
.warn { background:#fff3cd; color:#856404; }
.bad { background:#f8d7da; color:#721c24; }

pre {
    background:#f7f7f7; 
    padding:10px; 
    border:1px solid #ccc; 
    overflow-x:auto;
}

.collapsible {
    background-color: #eee; 
    cursor: pointer; 
    padding: 12px; 
    width: 100%; 
    border: none; 
    text-align: left; 
    outline: none; 
    font-size: 16px;
}
.active, .collapsible:hover { background-color: #ddd; }
.content { padding:10px; display:none; border:1px solid #ccc; margin-bottom:10px; }

</style>
<script>
document.addEventListener('DOMContentLoaded', function(){
    var coll = document.getElementsByClassName('collapsible');
    for(let i=0;i<coll.length;i++){
        coll[i].addEventListener('click', function(){
            this.classList.toggle('active');
            var content = this.nextElementSibling;
            content.style.display = content.style.display === 'block' ? 'none':'block';
        });
    }
});
</script>
</head>
<body>

<h1>AKS Health Report - $CLUSTER_NAME</h1>
" > "$REPORT_PATH"



        ############################################
        # SUMMARY TABLE
        ############################################
        echo "<h2>Summary</h2>
<table>
<tr><th>Check</th><th>Status</th></tr>
<tr class=\"$NODE_CLASS\"><td>Node Health</td><td>$NODE_STATUS</td></tr>
<tr class=\"$POD_CLASS\"><td>Pod Status</td><td>$POD_STATUS</td></tr>
<tr class=\"$UPGRADE_CLASS\"><td>Upgrade Status</td><td>$UPGRADE_STATUS</td></tr>
<tr class=\"$METRICS_CLASS\"><td>Metrics Server</td><td>$METRICS</td></tr>
<tr class=\"$HPA_CLASS\"><td>HPA</td><td>$HPA_STATUS</td></tr>
<tr class=\"$PDB_CLASS\"><td>PDB</td><td>$PDB_STATUS</td></tr>
<tr class=\"$PVC_CLASS\"><td>PVC Status</td><td>$PVC_STATUS</td></tr>
<tr class=\"$INGRESS_CLASS\"><td>Ingress Status</td><td>$INGRESS_STATUS</td></tr>
</table>
" >> "$REPORT_PATH"


        ############################################
        # COLLAPSIBLE DATA SECTIONS
        ############################################

        echo "<button class='collapsible'>Node List</button><div class='content'><pre>" >> "$REPORT_PATH"
        kubectl get nodes -o wide >> "$REPORT_PATH"
        echo "</pre></div>" >> "$REPORT_PATH"

        echo "<button class='collapsible'>Pods</button><div class='content'><pre>" >> "$REPORT_PATH"
        kubectl get pods --all-namespaces -o wide >> "$REPORT_PATH"
        echo "</pre></div>" >> "$REPORT_PATH"

        echo "<button class='collapsible'>Node CPU/Memory</button><div class='content'><pre>" >> "$REPORT_PATH"
        kubectl top nodes >> "$REPORT_PATH" 2>/dev/null || echo "Metrics server missing" >> "$REPORT_PATH"
        echo "</pre></div>" >> "$REPORT_PATH"

        echo "<button class='collapsible'>Pod CPU/Memory</button><div class='content'><pre>" >> "$REPORT_PATH"
        kubectl top pods --all-namespaces >> "$REPORT_PATH" 2>/dev/null || echo "Metrics server missing" >> "$REPORT_PATH"
        echo "</pre></div>" >> "$REPORT_PATH"

        echo "</body></html>" >> "$REPORT_PATH"


        ############################################
        # ADD ENTRY TO MASTER INDEX
        ############################################
        echo "<tr class=\"$OVERALL_CLASS\">
               <td>$SUB</td>
               <td>$CLUSTER_NAME</td>
               <td>$OVERALL_STATUS</td>
               <td><a href=\"$REPORT_FILE\">View Report</a></td>
               </tr>" >> $INDEX_FILE

    done
done


echo "</table></body></html>" >> $INDEX_FILE
echo "[INFO] All reports generated successfully with full styling and colors."
