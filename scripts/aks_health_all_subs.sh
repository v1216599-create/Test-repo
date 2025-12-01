#!/bin/bash
set -e

REPORT_DIR="reports"
mkdir -p "$REPORT_DIR"

MASTER="$REPORT_DIR/index.html"

############################################
# BEAUTIFUL HTML TEMPLATE
############################################
HTML_HEADER='
<html>
<head>
<title>AKS Health Dashboard</title>

<style>

body {
  font-family: Arial, sans-serif;
  margin: 20px;
  background: #eef2f7;
}

h1 {
  color: #2c3e50;
  margin-bottom: 10px;
}

.card {
  background: white;
  padding: 20px;
  margin-bottom: 25px;
  border-radius: 12px;
  box-shadow: 0 4px 12px rgba(0,0,0,0.08);
}

table {
  width: 100%;
  border-collapse: collapse;
  margin-top: 15px;
  border-radius: 12px;
  overflow: hidden;
  font-size: 15px;
}

th {
  background: #2c3e50;
  color: white;
  padding: 12px;
  text-align: left;
}

td {
  padding: 10px;
  border-bottom: 1px solid #e8e8e8;
}

.ok {
  background:#d4edda !important;
  color:#155724 !important;
}

.warn {
  background:#fff3cd !important;
  color:#856404 !important;
}

.bad {
  background:#f8d7da !important;
  color:#721c24 !important;
}

.collapsible {
  background-color: #3498db;
  color: white;
  cursor: pointer;
  padding: 12px;
  width: 100%;
  border: none;
  outline: none;
  font-size: 16px;
  border-radius: 6px;
  margin-top: 12px;
  text-align:left;
}

.collapsible:hover {
  background-color: #2980b9;
}

.content {
  padding: 12px;
  display: none;
  border-radius: 6px;
  border: 1px solid #dcdcdc;
  background: #fafafa;
}

pre {
  background:#2d3436;
  color:#dfe6e9;
  padding:10px;
  border-radius: 6px;
  overflow-x:auto;
}

</style>

<script>
document.addEventListener("DOMContentLoaded", () => {
  var coll = document.getElementsByClassName("collapsible");
  for (let i=0;i<coll.length;i++){
    coll[i].addEventListener("click", function(){
      this.classList.toggle("active");
      var content = this.nextElementSibling;
      content.style.display = content.style.display === "block" ? "none":"block";
    });
  }
});
</script>

</head>
<body>
'

############################################
# INDEX PAGE (SUBSCRIPTION LIST)
############################################

echo "$HTML_HEADER" > "$MASTER"
echo "<div class='card'><h1>AKS Subscriptions</h1>" >> "$MASTER"
echo "<table><tr><th>Subscription</th><th>Page</th></tr>" >> "$MASTER"

############################################
# GET ALL SUBSCRIPTIONS
############################################
SUBS=$(az account list --query "[].{id:id, name:name}" -o json)

for row in $(echo "$SUBS" | jq -r '.[] | @base64'); do

    _jq() { echo "$row" | base64 --decode | jq -r "$1"; }

    SUB_ID=$(_jq '.id')
    SUB_NAME=$(_jq '.name')

    # output subscription page filename exactly like portal name
    SUB_FILE="$REPORT_DIR/$SUB_NAME.html"

    echo "[INFO] Processing subscription: $SUB_NAME"

    ############################################
    # BUILD SUBSCRIPTION PAGE
    ############################################
    echo "$HTML_HEADER" > "$SUB_FILE"
    echo "<div class='card'><h1>$SUB_NAME</h1>" >> "$SUB_FILE"
    echo "<h2>AKS Clusters</h2>" >> "$SUB_FILE"

    echo "<table>
    <tr>
        <th>Cluster Name</th>
        <th>Health</th>
        <th>Report</th>
    </tr>" >> "$SUB_FILE"

    az account set --subscription "$SUB_ID"

    # list clusters
    CLUSTERS=$(az aks list --query "[].{name:name,rg:resourceGroup}" -o json)

    ############################################
    # PROCESS CLUSTERS IN THIS SUBSCRIPTION
    ############################################
    for cluster in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do

        _cjq() { echo "$cluster" | base64 --decode | jq -r "$1"; }

        CLUSTER=$(_cjq '.name')
        RG=$(_cjq '.rg')

        echo "[INFO] Processing cluster: $CLUSTER"

        # report filename
        REPORT="$REPORT_DIR/${SUB_NAME}_${CLUSTER}.html"

        # prepare kubeconfig
        az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null

        ###################################
        # HEALTH CHECKS
        ###################################

        # cluster version
        CLUSTER_VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv)

        # autoscaling
        AUTOSCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" --query '[0].enableAutoScaling' -o tsv)
        MIN_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" --query '[0].minCount' -o tsv)
        MAX_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" --query '[0].maxCount' -o tsv)

        # node health
        NODE_NOT_READY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print}')

        # pod health
        CRASH=$(kubectl get pods --all-namespaces | grep -i crashloop || true)

        # pvc health
        PVC_FAIL=$(kubectl get pvc --all-namespaces 2>/dev/null | grep -i failed || true)

        ####################################################
        # CLASSIFICATION
        ####################################################

        [[ -z "$NODE_NOT_READY" ]] \
            && NODE_CLASS="ok" && NODE_STATUS="✓ Healthy" \
            || NODE_CLASS="bad" && NODE_STATUS="✗ Issues"

        [[ -z "$CRASH" ]] \
            && POD_CLASS="ok" && POD_STATUS="✓ Healthy" \
            || POD_CLASS="bad" && POD_STATUS="✗ CrashLoop"

        [[ -z "$PVC_FAIL" ]] \
            && PVC_CLASS="ok" && PVC_STATUS="✓ Healthy" \
            || PVC_CLASS="bad" && PVC_STATUS="✗ PVC Failures"

        if [[ "$AUTOSCALE" == "true" ]]; then
            AUTO_CLASS="ok"
            AUTO_STATUS="Enabled (Min: $MIN_COUNT, Max: $MAX_COUNT)"
        else
            AUTO_CLASS="warn"
            AUTO_STATUS="Disabled"
        fi

        # cluster overall
        if [[ "$NODE_CLASS" = "bad" || "$POD_CLASS" = "bad" || "$PVC_CLASS" = "bad" ]]; then
            OVERALL_CLASS="bad"
            CLUSTER_HEALTH="Unhealthy"
        elif [[ "$AUTO_CLASS" = "warn" ]]; then
            OVERALL_CLASS="warn"
            CLUSTER_HEALTH="Warning"
        else
            OVERALL_CLASS="ok"
            CLUSTER_HEALTH="Healthy"
        fi

        ####################################################
        # BUILD CLUSTER REPORT
        ####################################################

        echo "$HTML_HEADER" > "$REPORT"

        echo "<div class='card'>
        <h1>$CLUSTER</h1>
        <h2>Summary</h2>

        <table>
        <tr><th>Check</th><th>Status</th></tr>

        <tr class='$OVERALL_CLASS'><td>Cluster Health</td><td>$CLUSTER_HEALTH</td></tr>
        <tr class='$NODE_CLASS'><td>Node Health</td><td>$NODE_STATUS</td></tr>
        <tr class='$POD_CLASS'><td>Pod Health</td><td>$POD_STATUS</td></tr>
        <tr class='$PVC_CLASS'><td>PVC Health</td><td>$PVC_STATUS</td></tr>
        <tr class='$AUTO_CLASS'><td>Autoscaling</td><td>$AUTO_STATUS</td></tr>
        <tr class='ok'><td>Cluster Version</td><td>$CLUSTER_VERSION</td></tr>

        </table>
        </div>
        " >> "$REPORT"

        ###############################################
        # Node List (NEW ALIGNMENT, no kernel version)
        ###############################################
        
        echo "<button class='collapsible'>Node List</button>
        <div class='content'>
        <table>
            <tr>
                <th>Name</th><th>Status</th><th>Roles</th><th>Age</th>
                <th>Version</th><th>CPU</th><th>Memory</th>
                <th>Internal-IP</th><th>External-IP</th><th>OS-Image</th><th>Container Runtime</th>
            </tr>" >> "$REPORT"

        # Get node names
        NODES=$(kubectl get nodes -o json)

        for node in $(echo "$NODES" | jq -r '.items[] | @base64'); do
            _n() { echo "$node" | base64 --decode | jq -r "$1"; }

            NAME=$(_n '.metadata.name')
            STATUS=$(_n '.status.conditions[] | select(.type=="Ready") | .status')
            ROLES=$(_n '.metadata.labels["kubernetes.io/role"]')
            AGE=$(kubectl get node "$NAME" | awk 'NR==2{print $5}')
            VERSION=$(_n '.status.nodeInfo.kubeletVersion')
            INTERNAL=$(_n '.status.addresses[] | select(.type=="InternalIP") | .address')
            EXTERNAL=$(_n '.status.addresses[] | select(.type=="ExternalIP") | .address')
            OS=$(_n '.status.nodeInfo.osImage')
            RUNTIME=$(_n '.status.nodeInfo.containerRuntimeVersion')

            # CPU/Mem from metrics server
            if kubectl top nodes &>/dev/null; then
                CPU=$(kubectl top node "$NAME" | awk 'NR==2{print $2}')
                MEM=$(kubectl top node "$NAME" | awk 'NR==2{print $4}')
            else
                CPU="N/A"
                MEM="N/A"
            fi

            echo "<tr>
                <td>$NAME</td>
                <td>$STATUS</td>
                <td>$ROLES</td>
                <td>$AGE</td>
                <td>$VERSION</td>
                <td>$CPU</td>
                <td>$MEM</td>
                <td>$INTERNAL</td>
                <td>$EXTERNAL</td>
                <td>$OS</td>
                <td>$RUNTIME</td>
            </tr>" >> "$REPORT"

        done

        echo "</table></div>" >> "$REPORT"

        ###############################################
        # Pods + Metrics
        ###############################################

        echo "<button class='collapsible'>Pod List</button><div class='content'><pre>" >> "$REPORT"
        kubectl get pods --all-namespaces -o wide >> "$REPORT"
        echo "</pre></div>" >> "$REPORT"

        echo "<button class='collapsible'>Pod CPU/Memory Usage</button><div class='content'><pre>" >> "$REPORT"
        if kubectl top pods --all-namespaces &>/dev/null; then
            kubectl top pods --all-namespaces >> "$REPORT"
        else
            echo "Metrics server not installed." >> "$REPORT"
        fi
        echo "</pre></div>" >> "$REPORT"

        echo "</body></html>" >> "$REPORT"

        #################################################
        # ADD CLUSTER ENTRY TO SUBSCRIPTION PAGE
        #################################################
        echo "<tr class='$OVERALL_CLASS'>
            <td>$CLUSTER</td>
            <td>$CLUSTER_HEALTH</td>
            <td><a href='${SUB_NAME}_${CLUSTER}.html'>View</a></td>
        </tr>" >> "$SUB_FILE"

    done

    echo "</table></div></body></html>" >> "$SUB_FILE"

    #################################################
    # ADD SUBSCRIPTION ENTRY TO MASTER INDEX
    #################################################
    echo "<tr><td>$SUB_NAME</td><td><a href='$SUB_NAME.html'>Open</a></td></tr>" >> "$MASTER"

done

echo "</table></div></body></html>" >> "$MASTER"

echo "====================================================================="
echo "AKS Health Reports Generated Successfully!"
echo "Open: reports/index.html"
echo "====================================================================="
