#!/bin/bash
export AZURE_AKS_DISABLE_AUTO_VERSION_CHECK=true
set -e

############################################################
# REQUIRED FOR GITHUB ACTIONS
############################################################
export AZURE_CONFIG_DIR="$HOME/.azure"

REPORT_DIR="reports"
mkdir -p "$REPORT_DIR"

FINAL_REPORT="$REPORT_DIR/AKS Cluster Health.html"

############################################################
# HTML HEADER
############################################################
HTML_HEADER='
<html>
<head>
<title>AKS Cluster Health – Report</title>

<style>
body { font-family: Arial, sans-serif; margin: 20px; background: #eef2f7; }
h1, h2, h3 { color: #2c3e50; }

.card { background: white; padding: 20px; margin-bottom: 25px;
border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.08); }

table { width: 100%; border-collapse: collapse; margin-top: 15px;
border-radius: 12px; overflow: hidden; font-size: 15px; }

th { background: #2c3e50; color: white; padding: 12px; text-align: left; }
td {
  padding: 10px;
  border-bottom: 1px solid #e8e8e8;
  vertical-align: top;
  word-wrap: break-word;
  white-space: normal;
}

/* NEW — Green for Healthy Rows */
.healthy-all {
  background:#c8f7c5 !important;
  color:#145a32 !important;
  font-weight:bold;
}

/* Dark Green for version row */
.version-ok {
  background:#c8f7c5 !important;
  color:#145a32 !important;
  font-weight:bold;
}

.collapsible {
  background-color: #3498db; color: white; cursor: pointer;
  padding: 12px; width: 100%; border: none; outline: none;
  font-size: 16px; border-radius: 6px; margin-top: 12px; text-align:left;
}

.collapsible:hover { background-color: #2980b9; }

.content {
  padding: 12px; display: none; border-radius: 6px;
  border: 1px solid #dcdcdc; background: #fafafa;
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

############################################################
# START REPORT
############################################################
echo "$HTML_HEADER" > "$FINAL_REPORT"

# NEW Title (Blue Background)
echo "<div style='background:#3498db;padding:15px;border-radius:6px;margin-bottom:25px;'>
<h1 style='color:white;margin:0;font-weight:bold;'>AKS Cluster Health – Report</h1>
</div>" >> "$FINAL_REPORT"

############################################################
# SUBSCRIPTIONS
############################################################
SUB1="3f499502-898a-4be8-8dc6-0b6260bd0c8c"
SUB2="yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

SUBS=$(az account list --query "[?id=='$SUB1' || id=='$SUB2'].{id:id,name:name}" -o json)

############################################################
# PROCESS SUBSCRIPTIONS
############################################################
for row in $(echo "$SUBS" | jq -r '.[] | @base64'); do
_jq(){ echo "$row" | base64 --decode | jq -r "$1"; }

SUB_ID=$(_jq '.id')
SUB_NAME=$(_jq '.name')

echo "<div class='card'><h2>Subscription: $SUB_NAME</h2>
<p><b>Subscription ID:</b> $SUB_ID</p>" >> "$FINAL_REPORT"

az account set --subscription "$SUB_ID"

CLUSTERS=$(az aks list --query "[].{name:name,rg:resourceGroup}" -o json)

if [[ $(echo "$CLUSTERS" | jq length) -eq 0 ]]; then
    echo "<p>No AKS clusters in this subscription.</p></div>" >> "$FINAL_REPORT"
    continue
fi

############################################################
# PROCESS CLUSTERS
############################################################
for cluster in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do

_cjq(){ echo "$cluster" | base64 --decode | jq -r "$1"; }

CLUSTER=$(_cjq '.name')
RG=$(_cjq '.rg')

echo "[INFO] Processing $CLUSTER"

az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null

############################################################
# BASIC CHECKS
############################################################
CLUSTER_VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv)

AUTOSCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" \
--query '[0].enableAutoScaling' -o tsv || echo "false")

MIN_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" \
--query '[0].minCount' -o tsv || echo "N/A")

MAX_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" \
--query '[0].maxCount' -o tsv || echo "N/A")

# All nodepools (raw list)
NODEPOOL_SCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" \
-o json | jq -r '.[] | "\(.name): autoscale=\(.enableAutoScaling), min=\(.minCount), max=\(.maxCount)"' \
| tr '\n' '; ')
[[ -z "$NODEPOOL_SCALE" ]] && NODEPOOL_SCALE="No Node Pools Found"

# Convert to one-per-line
NODEPOOL_SCALE_FORMATTED=$(echo "$NODEPOOL_SCALE" | tr ';' '\n' | sed '/^$/d')

NODE_NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print}' || true)
POD_CRASH=$(kubectl get pods -A --no-headers 2>/dev/null \
| awk '$4=="CrashLoopBackOff" || $3=="Error" || $3=="Pending"' || true)
PVC_FAIL=$(kubectl get pvc -A 2>/dev/null | grep -i failed || true)

[[ -z "$NODE_NOT_READY" ]] && NODE_CLASS="healthy-all" || NODE_CLASS="bad"
[[ -z "$POD_CRASH" ]] && POD_CLASS="healthy-all" || POD_CLASS="bad"
[[ -z "$PVC_FAIL" ]] && PVC_CLASS="healthy-all" || PVC_CLASS="bad"
[[ "$AUTOSCALE" == "true" ]] && AUTO_CLASS="healthy-all" || AUTO_CLASS="warn"

NODE_STATUS=$([[ $NODE_CLASS == "healthy-all" ]] && echo "✓ Healthy" || echo "✗ Issues")
POD_STATUS=$([[ $POD_CLASS == "healthy-all" ]] && echo "✓ Healthy" || echo "✗ Pod Issues")
PVC_STATUS=$([[ $PVC_CLASS == "healthy-all" ]] && echo "✓ Healthy" || echo "✗ PVC Failures")
AUTO_STATUS=$([[ $AUTO_CLASS == "healthy-all" ]] && echo "Enabled (Min:$MIN_COUNT Max:$MAX_COUNT)" || echo "Disabled")

############################################################
# SUMMARY TABLE
############################################################
echo "<div class='card'>
<h3>Cluster: $CLUSTER</h3>
<table>
<tr><th>Check</th><th>Status</th></tr>

<tr class='$NODE_CLASS'><td>Node Health</td><td>$NODE_STATUS</td></tr>
<tr class='$POD_CLASS'><td>Pod Health</td><td>$POD_STATUS</td></tr>
<tr class='$PVC_CLASS'><td>PVC Health</td><td>$PVC_STATUS</td></tr>
<tr class='$AUTO_CLASS'><td>Autoscaling</td><td>$AUTO_STATUS</td></tr>

<tr class='version-ok'><td>Cluster Version</td><td>$CLUSTER_VERSION</td></tr>

</table></div>
" >> "$FINAL_REPORT"

############################################################
# NEW — AUTOSCALING DETAILS COLLAPSIBLE
############################################################
echo "<button class='collapsible'>Autoscaling Status – All Node Pools</button>
<div class='content'><pre>$NODEPOOL_SCALE_FORMATTED</pre></div>" >> "$FINAL_REPORT"

############################################################
# NETWORKING
############################################################
NETWORK_MODEL=$(az aks show -g "$RG" -n "$CLUSTER" --query "networkProfile.networkPlugin" -o tsv)
API_SERVER=$(kubectl get --raw='/healthz' 2>/dev/null | grep -i ok || echo "FAILED")

echo "<button class='collapsible'>Networking Checks</button>
<div class='content'><pre>
Network Model     : $NETWORK_MODEL
API Server Status : $API_SERVER
</pre></div>" >> "$FINAL_REPORT"

############################################################
# IDENTITY / ACCESS
############################################################
MANAGED_ID=$(az aks show -g "$RG" -n "$CLUSTER" --query identity.type -o tsv)

RBAC_ENABLED=$(az aks show -g "$RG" -n "$CLUSTER" --query enableRBAC -o tsv)

AAD_ENABLED=$(az aks show -g "$RG" -n "$CLUSTER" --query "aadProfile" -o json \
| jq -r 'if . == null then "Disabled" else "Enabled" end')

SP_ID=$(az aks show -g "$RG" -n "$CLUSTER" \
--query servicePrincipalProfile.clientId -o tsv || echo "N/A")

echo "<button class='collapsible'>Identity & Access Checks</button>
<div class='content'><pre>
Managed Identity Type : $MANAGED_ID
RBAC Enabled          : $RBAC_ENABLED
AAD Integration       : $AAD_ENABLED
Service Principal ID  : $SP_ID
</pre></div>
" >> "$FINAL_REPORT"

############################################################
# SECURITY
############################################################
SECRETS_ENC=$(az aks show -g "$RG" -n "$CLUSTER" \
--query 'securityProfile.enableSecretsEncryption' -o tsv 2>/dev/null || echo "N/A")

echo "<button class='collapsible'>Security Checks</button>
<div class='content'><pre>
Secrets Encryption : $SECRETS_ENC
</pre></div>
" >> "$FINAL_REPORT"

############################################################
# NODE LIST (ROLES REMOVED)
############################################################
echo "<button class='collapsible'>Node List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"

kubectl get nodes -o wide | awk '{$3=""; print}' | column -t >> "$FINAL_REPORT"

echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# POD LIST
############################################################
echo "<button class='collapsible'>Pod List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get pods -A -o wide | column -t >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# SERVICES LIST
############################################################
echo "<button class='collapsible'>Services List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get svc -A -o wide | column -t >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# POD CPU / MEM
############################################################
echo "<button class='collapsible'>Pod CPU / Memory Usage</button>
<div class='content'><pre>" >> "$FINAL_REPORT"

if kubectl top pods -A &>/dev/null; then
    kubectl top pods -A | column -t >> "$FINAL_REPORT"
else
    echo "Metrics not available" >> "$FINAL_REPORT"
fi

echo "</pre></div>" >> "$FINAL_REPORT"

done # cluster loop

echo "</div>" >> "$FINAL_REPORT"
done # subscription loop

echo "</body></html>" >> "$FINAL_REPORT"

echo "===================================================="
echo "AKS HTML Report Generated Successfully"
echo "Saved at: $FINAL_REPORT"
echo "===================================================="
