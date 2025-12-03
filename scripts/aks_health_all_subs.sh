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
<title>AKS Cluster Health</title>

<style>
body { font-family: Arial, sans-serif; margin: 20px; background: #eef2f7; }
h1, h2, h3 { color: #2c3e50; }
.card { background: white; padding: 20px; margin-bottom: 25px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.08); }
table { width: 100%; border-collapse: collapse; margin-top: 15px; border-radius: 12px; overflow: hidden; font-size: 15px; }
th { background: #2c3e50; color: white; padding: 12px; text-align: left; }
td { padding: 10px; border-bottom: 1px solid #e8e8e8; }
.ok { background:#d4edda !important; color:#155724 !important; }
.warn { background:#fff3cd !important; color:#856404 !important; }
.bad { background:#f8d7da !important; color:#721c24 !important; }

.collapsible {
  background-color: #3498db; color: white; cursor: pointer;
  padding: 12px; width: 100%; border: none; outline: none;
  font-size: 16px; border-radius: 6px; margin-top: 12px; text-align:left;
}
.collapsible:hover { background-color: #2980b9; }
.content { padding: 12px; display: none; border-radius: 6px;
  border: 1px solid #dcdcdc; background: #fafafa; }
pre { background:#2d3436; color:#dfe6e9; padding:10px; border-radius: 6px; overflow-x:auto; }
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
echo "<div class='card'><h1>AKS Cluster Health – Selected Subscriptions</h1></div>" >> "$FINAL_REPORT"

############################################################
# SUBSCRIPTIONS TO SCAN
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
# BASIC HEALTH CHECKS
############################################################
CLUSTER_VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv)

AUTOSCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" --query '[0].enableAutoScaling' -o tsv || echo "false")
MIN_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" --query '[0].minCount' -o tsv || echo "N/A")
MAX_COUNT=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" --query '[0].maxCount' -o tsv || echo "N/A")

NODE_NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print}' || true)
POD_CRASH=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4=="CrashLoopBackOff" || $3=="Error" || $3=="Pending"' || true)
PVC_FAIL=$(kubectl get pvc -A 2>/dev/null | grep -i failed || true)

[[ -z "$NODE_NOT_READY" ]] && NODE_CLASS="ok" || NODE_CLASS="bad"
[[ -z "$POD_CRASH" ]] && POD_CLASS="ok" || POD_CLASS="bad"
[[ -z "$PVC_FAIL" ]] && PVC_CLASS="ok" || PVC_CLASS="bad"
[[ "$AUTOSCALE" == "true" ]] && AUTO_CLASS="ok" || AUTO_CLASS="warn"

NODE_STATUS=$([[ $NODE_CLASS == "ok" ]] && echo "✓ Healthy" || echo "✗ Issues")
POD_STATUS=$([[ $POD_CLASS == "ok" ]] && echo "✓ Healthy" || echo "✗ Pod Issues")
PVC_STATUS=$([[ $PVC_CLASS == "ok" ]] && echo "✓ Healthy" || echo "✗ PVC Failures")
AUTO_STATUS=$([[ $AUTO_CLASS == "ok" ]] && echo "Enabled (Min:$MIN_COUNT Max:$MAX_COUNT)" || echo "Disabled")

############################################################
# SUMMARY BLOCK
############################################################
echo "<div class='card'>
<h3>Cluster: $CLUSTER</h3>
<table>
<tr><th>Check</th><th>Status</th></tr>
<tr class='$NODE_CLASS'><td>Node Health</td><td>$NODE_STATUS</td></tr>
<tr class='$POD_CLASS'><td>Pod Health</td><td>$POD_STATUS</td></tr>
<tr class='$PVC_CLASS'><td>PVC Health</td><td>$PVC_STATUS</td></tr>
<tr class='$AUTO_CLASS'><td>Autoscaling</td><td>$AUTO_STATUS</td></tr>
<tr><td>Cluster Version</td><td>$CLUSTER_VERSION</td></tr>
</table></div>
" >> "$FINAL_REPORT"


############################################################
# NETWORKING CHECKS
############################################################
NETWORK_MODEL=$(az aks show -g "$RG" -n "$CLUSTER" --query "networkProfile.networkPlugin" -o tsv)

API_SERVER=$(kubectl get --raw='/healthz' 2>/dev/null | grep -i ok || echo "FAILED")

AUDIT_LOGS=$(az monitor diagnostic-settings list \
  --resource "$(az aks show -g "$RG" -n "$CLUSTER" --query id -o tsv)" \
  | jq '(.value // [])[] | select(.logs[]?.category=="kube-apiserver-audit")' | wc -l)

[[ "$AUDIT_LOGS" -gt 0 ]] && AUDIT_STATUS="Enabled" || AUDIT_STATUS="Disabled"

API_LAT=$(kubectl get --raw='/metrics' 2>/dev/null \
  | grep "apiserver_request_duration_seconds_sum" | head -1 || true)

echo "<button class='collapsible'>Networking Checks</button>
<div class='content'><pre>
Network Model               : $NETWORK_MODEL
API Server Status           : $API_SERVER
API Server Audit Logs       : $AUDIT_STATUS
API Server Latency Metric   : $API_LAT
</pre></div>" >> "$FINAL_REPORT"


############################################################
# IDENTITY & ACCESS CHECKS
############################################################
MANAGED_ID=$(az aks show -g "$RG" -n "$CLUSTER" --query identity.type -o tsv || echo "N/A")

RBAC_ENABLED=$(az aks show -g "$RG" -n "$CLUSTER" --query enableRBAC -o tsv || echo "N/A")

AAD_ENABLED=$(az aks show -g "$RG" -n "$CLUSTER" --query "aadProfile" -o json \
  | jq -r 'if . == null then "Disabled" else "Enabled" end' || echo "Unknown")

SP_ID=$(az aks show -g "$RG" -n "$CLUSTER" --query servicePrincipalProfile.clientId -o tsv || echo "N/A")
SP_EXPIRY=$(az ad sp show --id "$SP_ID" --query "passwordCredentials[0].endDateTime" -o tsv 2>/dev/null || echo "N/A")

echo "<button class='collapsible'>Identity & Access Checks</button>
<div class='content'><pre>
Managed Identity Type       : $MANAGED_ID
RBAC Enabled                : $RBAC_ENABLED
AAD Integration             : $AAD_ENABLED
Service Principal ID        : $SP_ID
Service Principal Expiry    : $SP_EXPIRY
</pre></div>
" >> "$FINAL_REPORT"


############################################################
# OBSERVABILITY CHECKS
############################################################
METRICS_SERVER=$(kubectl get deployment -n kube-system 2>/dev/null | grep metrics-server || echo "Not Installed")
PROM=$(kubectl get pods -A 2>/dev/null | grep -i prometheus || echo "Prometheus Not Found")
GF=$(kubectl get pods -A 2>/dev/null | grep -i grafana || echo "Grafana Not Found")
LOGS_FLOW=$(kubectl logs -n kube-system -l k8s-app=kubelet 2>/dev/null || echo "No kubelet logs")

echo "<button class='collapsible'>Observability Checks</button>
<div class='content'><pre>
Metrics Server              : $METRICS_SERVER
Kubelet Logs                : $LOGS_FLOW
Prometheus                  : $PROM
Grafana                     : $GF
</pre></div>
" >> "$FINAL_REPORT"


############################################################
# SECURITY CHECKS
############################################################
PSA=$(kubectl get podsecurityadmissions.config.openshift.io 2>/dev/null || echo "N/A")

SECRETS_ENC=$(az aks show -g "$RG" -n "$CLUSTER" \
    --query 'securityProfile.enableSecretsEncryption' -o tsv 2>/dev/null || echo "N/A")

DEFENDER=$(az security pricing show --name KubernetesService --query pricingTier -o tsv 2>/dev/null || echo "Not Registered")

TLS=$(az aks show -g "$RG" -n "$CLUSTER" --query apiServerAccessProfile.enablePrivateCluster -o tsv || echo "N/A")

IMG_SCAN=$(az security setting show --name "MCAS" --query status -o tsv 2>/dev/null || echo "N/A")

echo "<button class='collapsible'>Security Checks</button>
<div class='content'><pre>
Pod Security Admission      : $PSA
Secrets Encryption          : $SECRETS_ENC
Azure Defender Enabled      : $DEFENDER
TLS Enforcement             : $TLS
Image Scanning              : $IMG_SCAN
</pre></div>
" >> "$FINAL_REPORT"


############################################################
# NODE LIST
############################################################
echo "<button class='collapsible'>Node List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get nodes -o wide >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"


############################################################
# POD LIST
############################################################
echo "<button class='collapsible'>Pod List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get pods -A -o wide >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"


############################################################
# SERVICES LIST  (NEW SECTION)
############################################################
echo "<button class='collapsible'>Services List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get svc -A -o wide >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"


############################################################
# POD CPU/MEM
############################################################
echo "<button class='collapsible'>Pod CPU / Memory Usage</button>
<div class='content'><pre>" >> "$FINAL_REPORT"

if kubectl top pods -A &>/dev/null; then
    kubectl top pods -A >> "$FINAL_REPORT"
else
    echo "Metrics not available" >> "$FINAL_REPORT"
fi

echo "</pre></div>" >> "$FINAL_REPORT"


done  # End cluster loop
echo "</div>" >> "$FINAL_REPORT"

done  # End subscription loop

echo "</body></html>" >> "$FINAL_REPORT"

echo "===================================================="
echo "AKS HTML Report Generated (with Services List)"
echo "Saved at: $FINAL_REPORT"
echo "===================================================="
