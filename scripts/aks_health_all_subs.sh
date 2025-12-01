#!/bin/bash
set -e

REPORT_DIR="reports"
mkdir -p $REPORT_DIR

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
# MASTER INDEX START
############################################
echo "$HTML_HEADER" > "$MASTER"
echo "<div class='card'><h1>AKS Health Dashboard</h1>" >> "$MASTER"

echo "<table>
<tr>
<th>Subscription</th>
<th>Cluster</th>
<th>Status</th>
<th>Report</th>
</tr>" >> "$MASTER"

############################################
# GET ALL SUBSCRIPTIONS
############################################
SUBS=$(az account list --query "[].id" -o tsv)

for SUB in $SUBS; do

    az account set --subscription "$SUB"

    CLUSTERS=$(az aks list --query "[].{name:name, rg:resourceGroup}" -o json)

    if [[ $(echo $CLUSTERS | jq length) -eq 0 ]]; then continue; fi

    for row in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do

        _jq() { echo "$row" | base64 --decode | jq -r "$1"; }

        CLUSTER=$(_jq '.name')
        RG=$(_jq '.rg')

        az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null

        REPORT_FILE="${SUB}_${CLUSTER}.html"
        REPORT="$REPORT_DIR/$REPORT_FILE"

#######################################
# HEALTH CHECKS
#######################################

# Cluster Kubernetes version
CLUSTER_VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv)

# Node Autoscaling Info (first nodepool)
AUTOSCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" --query '[0].enableAutoScaling' -o tsv)
MIN_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" --query '[0].minCount' -o tsv)
MAX_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" --query '[0].maxCount' -o tsv)

# Node health
NODE_NOT_READY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print}')

# Pod crash detection
CRASH=$(kubectl get pods --all-namespaces | grep -i crashloop || true)

# PVC failures
PVC_FAIL=$(kubectl get pvc --all-namespaces | grep -i failed || true)

# Kubernetes upgrade availability
UPGRADE=$(az aks get-upgrades -g "$RG" -n "$CLUSTER" --query controlPlaneProfile.upgrades[].kubernetesVersion -o tsv)

# Ingress / HPA / PDB counts
INGRESS=$(kubectl get ingress --all-namespaces --no-headers 2>/dev/null | wc -l)
HPA=$(kubectl get hpa --all-namespaces --no-headers 2>/dev/null | wc -l)
PDB=$(kubectl get pdb --all-namespaces --no-headers 2>/dev/null | wc -l)

#######################################
# STATUS MAPPING
#######################################

# Node
[[ -z "$NODE_NOT_READY" ]] && NODE_CLASS="ok" && NODE_STATUS="✓ Healthy" \
                          || NODE_CLASS="bad" && NODE_STATUS="✗ Node Issues"

# Pods
[[ -z "$CRASH" ]] && POD_CLASS="ok" && POD_STATUS="✓ Healthy" \
                  || POD_CLASS="bad" && POD_STATUS="✗ CrashLoop Found"

# PVC
[[ -z "$PVC_FAIL" ]] && PVC_CLASS="ok" && PVC_STATUS="✓ Healthy" \
                     || PVC_CLASS="bad" && PVC_STATUS="✗ PVC Error"

# Autoscaling
if [[ "$AUTOSCALE" == "true" ]]; then
    AUTO_STATUS="✓ Enabled (Min: $MIN_COUNT, Max: $MAX_COUNT)"
    AUTO_CLASS="ok"
else
    AUTO_STATUS="✗ Disabled"
    AUTO_CLASS="warn"
fi

# Upgrade availability
[[ -n "$UPGRADE" ]] && UPGRADE_CLASS="warn" && UPGRADE_STATUS="⚠ Available ($UPGRADE)" \
                    || UPGRADE_CLASS="ok" && UPGRADE_STATUS="✓ Latest"

# Ingress
[[ $INGRESS -gt 0 ]] && ING_CLASS="ok" && ING_STATUS="✓ $INGRESS" \
                    || ING_CLASS="warn" && ING_STATUS="⚠ None"

# HPA
[[ $HPA -gt 0 ]] && HPA_CLASS="ok" && HPA_STATUS="✓ $HPA" \
                || HPA_CLASS="warn" && HPA_STATUS="⚠ None"

# PDB
[[ $PDB -gt 0 ]] && PDB_CLASS="ok" && PDB_STATUS="✓ $PDB" \
                || PDB_CLASS="warn" && PDB_STATUS="⚠ None"

#######################################
# OVERALL STATUS
#######################################

if [[ "$NODE_CLASS" = "bad" || "$POD_CLASS" = "bad" || "$PVC_CLASS" = "bad" ]]; then
    OVERALL="Unhealthy"; CLASS="bad";
elif [[ "$UPGRADE_CLASS" = "warn" || "$AUTO_CLASS" = "warn" ]]; then
    OVERALL="Warning"; CLASS="warn";
else
    OVERALL="Healthy"; CLASS="ok";
fi

#########################################
# BUILD REPORT HTML
#########################################

echo "$HTML_HEADER" > "$REPORT"

echo "<div class='card'>
<h1>AKS Report – $CLUSTER</h1>
<h2>Summary</h2>

<table>
<tr><th>Check</th><th>Status</th></tr>

<tr class='$NODE_CLASS'><td>Node Health</td><td>$NODE_STATUS</td></tr>
<tr class='$POD_CLASS'><td>Pod Status</td><td>$POD_STATUS</td></tr>
<tr class='$PVC_CLASS'><td>PVC Health</td><td>$PVC_STATUS</td></tr>

<tr class='$AUTO_CLASS'><td>Node Autoscaling</td><td>$AUTO_STATUS</td></tr>

<tr class='ok'><td>Cluster Version</td><td>✓ $CLUSTER_VERSION</td></tr>

<tr class='$UPGRADE_CLASS'><td>Upgrade Availability</td><td>$UPGRADE_STATUS</td></tr>

<tr class='$ING_CLASS'><td>Ingress</td><td>$ING_STATUS</td></tr>
<tr class='$HPA_CLASS'><td>HPA</td><td>$HPA_STATUS</td></tr>
<tr class='$PDB_CLASS'><td>PDB</td><td>$PDB_STATUS</td></tr>

</table>
</div>
" >> "$REPORT"

# Collapsible Node List
echo "<button class='collapsible'>Node List</button><div class='content'><pre>" >> "$REPORT"
kubectl get nodes -o wide >> "$REPORT"
echo "</pre></div>" >> "$REPORT"

# Collapsible Pods
echo "<button class='collapsible'>Pods</button><div class='content'><pre>" >> "$REPORT"
kubectl get pods --all-namespaces -o wide >> "$REPORT"
echo "</pre></div>" >> "$REPORT"

echo "</body></html>" >> "$REPORT"

#########################################
# ADD TO MASTER DASHBOARD
#########################################
echo "<tr class='$CLASS'>
<td>$SUB</td>
<td>$CLUSTER</td>
<td>$OVERALL</td>
<td><a href='$REPORT_FILE'>View</a></td>
</tr>" >> "$MASTER"

    done
done

echo "</table></div></body></html>" >> "$MASTER"

echo "--------------------------------------------------------------"
echo "AKS Health Reports Generated Successfully!"
echo "Dashboard: reports/index.html"
echo "--------------------------------------------------------------"
