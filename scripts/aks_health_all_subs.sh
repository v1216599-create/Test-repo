#!/bin/bash
set -e

REPORT_DIR="reports"
mkdir -p "$REPORT_DIR"

FINAL_REPORT="$REPORT_DIR/AKS Cluster Health.html"

############################################
# HTML HEADER (Pretty UI)
############################################
HTML_HEADER='
<html>
<head>
<title>AKS Cluster Health</title>

<style>

body {
  font-family: Arial, sans-serif;
  margin: 20px;
  background: #eef2f7;
}

h1, h2, h3 {
  color: #2c3e50;
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

.ok { background:#d4edda !important; color:#155724 !important; }
.warn { background:#fff3cd !important; color:#856404 !important; }
.bad { background:#f8d7da !important; color:#721c24 !important; }

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

.collapsible:hover { background-color: #2980b9; }

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
document.addEventListener("DOMContentLoaded",()=>{
  var coll=document.getElementsByClassName("collapsible");
  for(let i=0;i<coll.length;i++){
    coll[i].addEventListener("click",function(){
      this.classList.toggle("active");
      var content=this.nextElementSibling;
      content.style.display=content.style.display==="block"?"none":"block";
    });
  }
});
</script>

</head>
<body>
'

############################################
# WRITE HEADER
############################################
echo "$HTML_HEADER" > "$FINAL_REPORT"
echo "<div class='card'><h1>AKS Cluster Health – All Subscriptions</h1></div>" >> "$FINAL_REPORT"

############################################
# GET ALL SUBSCRIPTIONS
############################################
SUBS=$(az account list --query "[].{id:id,name:name}" -o json)

############################################
# PROCESS SUBSCRIPTIONS
############################################
for row in $(echo "$SUBS" | jq -r '.[] | @base64'); do

    _jq() { echo "$row" | base64 --decode | jq -r "$1"; }

    SUB_ID=$(_jq '.id')
    SUB_NAME=$(_jq '.name')

    echo "<div class='card'><h2>Subscription: $SUB_NAME</h2>" >> "$FINAL_REPORT"

    az account set --subscription "$SUB_ID"

    CLUSTERS=$(az aks list --query "[].{name:name,rg:resourceGroup}" -o json)

    if [[ $(echo "$CLUSTERS" | jq length) -eq 0 ]]; then
        echo "<p>No AKS Clusters in this subscription.</p></div>" >> "$FINAL_REPORT"
        continue
    fi

    ############################################
    # PROCESS CLUSTERS
    ############################################
    for cluster in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do

        _cjq() { echo "$cluster" | base64 --decode | jq -r "$1"; }

        CLUSTER=$(_cjq '.name')
        RG=$(_cjq '.rg')

        echo "[INFO] Processing cluster: $CLUSTER"

        az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null

        ############################################
        # HEALTH CHECKS
        ############################################

        CLUSTER_VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv)

        AUTOSCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" \
                        --query '[0].enableAutoScaling' -o tsv)

        MIN_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" \
                        --query '[0].minCount' -o tsv)

        MAX_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" \
                        --query '[0].maxCount' -o tsv)

        ############################################
        # NEW NODE + POD HEALTH LOGIC
        ############################################

        # Node readiness
        NODE_NOT_READY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print}')

        # Pod issues
        POD_CRASH=$(kubectl get pods -A --no-headers | \
                    awk '$4=="CrashLoopBackOff" || $3=="Error" || $3=="Pending"' || true)

        # PVC issues
        PVC_FAIL=$(kubectl get pvc -A 2>/dev/null | grep -i failed || true)

        ############################################
        # CLASSIFICATION
        ############################################

        # Node health depends on nodes + pods
        if [[ -z "$NODE_NOT_READY" && -z "$POD_CRASH" ]]; then
            NODE_CLASS="ok"
            NODE_STATUS="✓ Healthy"
        else
            NODE_CLASS="bad"
            NODE_STATUS="✗ Issues"
        fi

        # Pod Health row
        if [[ -z "$POD_CRASH" ]]; then
            POD_CLASS="ok"
            POD_STATUS="✓ Healthy"
        else
            POD_CLASS="bad"
            POD_STATUS="✗ Pod Issues"
        fi

        # PVC Health
        if [[ -z "$PVC_FAIL" ]]; then
            PVC_CLASS="ok"
            PVC_STATUS="✓ Healthy"
        else
            PVC_CLASS="bad"
            PVC_STATUS="✗ PVC Failures"
        fi

        # Autoscaling
        if [[ "$AUTOSCALE" == "true" ]]; then
            AUTO_CLASS="ok"
            AUTO_STATUS="Enabled (Min: $MIN_COUNT, Max: $MAX_COUNT)"
        else
            AUTO_CLASS="warn"
            AUTO_STATUS="Disabled"
        fi

        # Cluster overall
        if [[ "$NODE_CLASS" = "bad" || "$POD_CLASS" = "bad" ]]; then
            OVERALL_CLASS="bad"
            CLUSTER_HEALTH="✗ Unhealthy"
        elif [[ "$AUTO_CLASS" = "warn" ]]; then
            OVERALL_CLASS="warn"
            CLUSTER_HEALTH="⚠ Warning"
        else
            OVERALL_CLASS="ok"
            CLUSTER_HEALTH="✓ Healthy"
        fi

        ############################################
        # CLUSTER SUMMARY
        ############################################
        echo "<div class='card'>
        <h3>Cluster: $CLUSTER</h3>

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
        " >> "$FINAL_REPORT"

        ############################################
        # NODE LIST (no roles, no kernel)
        ############################################
        echo "<button class='collapsible'>Node List</button>
        <div class='content'>
        <table>
        <tr>
            <th>Name</th>
            <th>Status</th>
            <th>Age</th>
            <th>Version</th>
            <th>CPU</th>
            <th>Memory</th>
            <th>Internal IP</th>
            <th>External IP</th>
            <th>OS Image</th>
            <th>Container Runtime</th>
        </tr>
        " >> "$FINAL_REPORT"

        NODES=$(kubectl get nodes -o json)

        for node in $(echo "$NODES" | jq -r '.items[] | @base64'); do

            _n(){ echo "$node" | base64 --decode | jq -r "$1"; }

            NAME=$(_n '.metadata.name')
            STATUS=$(_n '.status.conditions[] | select(.type=="Ready") | .status')
            AGE=$(kubectl get node "$NAME" | awk 'NR==2{print $5}')
            VERSION=$(_n '.status.nodeInfo.kubeletVersion')
            INTERNAL=$(_n '.status.addresses[] | select(.type=="InternalIP") | .address')
            EXTERNAL=$(_n '.status.addresses[] | select(.type=="ExternalIP") | .address')
            OS=$(_n '.status.nodeInfo.osImage')
            RUNTIME=$(_n '.status.nodeInfo.containerRuntimeVersion')

            # CPU/Mem
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
                <td>$AGE</td>
                <td>$VERSION</td>
                <td>$CPU</td>
                <td>$MEM</td>
                <td>$INTERNAL</td>
                <td>$EXTERNAL</td>
                <td>$OS</td>
                <td>$RUNTIME</td>
            </tr>
            " >> "$FINAL_REPORT"

        done

        echo "</table></div>" >> "$FINAL_REPORT"

        ############################################
        # POD LIST
        ############################################
        echo "<button class='collapsible'>Pods</button>
        <div class='content'><pre>" >> "$FINAL_REPORT"

        kubectl get pods -A -o wide >> "$FINAL_REPORT"

        echo "</pre></div>" >> "$FINAL_REPORT"

        ############################################
        # POD CPU/MEM USAGE
        ############################################
        echo "<button class='collapsible'>Pod CPU/Memory Usage</button>
        <div class='content'><pre>" >> "$FINAL_REPORT"

        if kubectl top pods -A &>/dev/null; then
            kubectl top pods -A >> "$FINAL_REPORT"
        else
            echo "Metrics server not installed." >> "$FINAL_REPORT"
        fi

        echo "</pre></div>" >> "$FINAL_REPORT"

    done

    echo "</div>" >> "$FINAL_REPORT"

done

echo "</body></html>" >> "$FINAL_REPORT"

echo "==================================================="
echo "AKS Cluster Health Report generated successfully!"
echo "Output: $FINAL_REPORT"
echo "==================================================="
