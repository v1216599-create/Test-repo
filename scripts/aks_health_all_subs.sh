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
td { padding: 10px; border-bottom: 1px solid #e8e8e8; vertical-align: top; white-space: normal; }

.healthy-all {
  background:#c8f7c5 !important;
  color:#145a32 !important;
  font-weight:bold;
}

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
  background:#2d3436; color:#dfe6e9; padding:10px;
  border-radius: 6px; overflow-x:auto;
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

# Blue title header
echo "<div style='background:#3498db;padding:15px;border-radius:6px;margin-bottom:25px;'>
<h1 style='color:white;margin:0;font-weight:bold;'>AKS Cluster Health – Report</h1>
</div>" >> "$FINAL_REPORT"

############################################################
# SUBSCRIPTIONS (ADD MORE IF NEEDED)
############################################################
SUB1="3f499502-898a-4be8-8dc6-0b6260bd0c8c"

SUBS=$(az account list --query "[?id=='$SUB1'].{id:id,name:name}" -o json)

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
    echo "<p>No AKS clusters.</p></div>" >> "$FINAL_REPORT"
    continue
fi

############################################################
# PROCESS EACH CLUSTER
############################################################
for cluster in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do

set +e  # Important: Prevent GitHub Actions from failing

_cjq(){ echo "$cluster" | base64 --decode | jq -r "$1"; }

CLUSTER=$(_cjq '.name')
RG=$(_cjq '.rg')

echo "[INFO] Processing $CLUSTER"

az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null 2>&1

############################################################
# BASIC CHECKS
############################################################
CLUSTER_VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv 2>/dev/null)

NODEPOOL_SCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" -o json \
 | jq -r '.[] | "\(.name): autoscale=\(.enableAutoScaling), min=\(.minCount), max=\(.maxCount)"')

NODEPOOL_SCALE_FORMATTED=$(echo "$NODEPOOL_SCALE" | sed '/^$/d')

NODE_NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print}')
POD_CRASH=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="CrashLoopBackOff" || $3=="Error"')
PVC_FAIL=$(kubectl get pvc -A 2>/dev/null | grep -i failed)

[[ -z "$NODE_NOT_READY" ]] && NODE_CLASS="healthy-all" || NODE_CLASS="bad"
[[ -z "$POD_CRASH" ]] && POD_CLASS="healthy-all" || POD_CLASS="bad"
[[ -z "$PVC_FAIL" ]] && PVC_CLASS="healthy-all" || PVC_CLASS="bad"

NODE_STATUS=$([[ $NODE_CLASS == "healthy-all" ]] && echo "✓ Healthy" || echo "✗ Issues")
POD_STATUS=$([[ $POD_CLASS == "healthy-all" ]] && echo "✓ Healthy" || echo "✗ Pod Issues")
PVC_STATUS=$([[ $PVC_CLASS == "healthy-all" ]] && echo "✓ Healthy" || echo "✗ PVC Failures")

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
<tr class='version-ok'><td>Cluster Version</td><td>$CLUSTER_VERSION</td></tr>

</table></div>" >> "$FINAL_REPORT"

############################################################
# UPGRADE & SECURITY SCHEDULE (MODERN + LEGACY)
############################################################

# Automatic upgrade mode (modern + legacy)
AUTO_MODE_NEW=$(az aks show -g "$RG" -n "$CLUSTER" --query "autoUpgradeProfile.upgradeChannel" -o tsv 2>/dev/null)
AUTO_MODE_OLD=$(az aks show -g "$RG" -n "$CLUSTER" --query "nodeImageUpgradeChannel" -o tsv 2>/dev/null)

if [[ -n "$AUTO_MODE_NEW" ]]; then
  AUTO_UPGRADE_MODE="$AUTO_MODE_NEW"
elif [[ -n "$AUTO_MODE_OLD" ]]; then
  AUTO_UPGRADE_MODE="$AUTO_MODE_OLD"
else
  AUTO_UPGRADE_MODE="Not Configured"
fi

# Automatic upgrade schedule (modern + legacy)
AUTO_SCHED_NEW=$(az aks show -g "$RG" -n "$CLUSTER" --query "autoUpgradeProfile.maintenanceWindow.schedule" -o json 2>/dev/null)
AUTO_SCHED_OLD=$(az aks show -g "$RG" -n "$CLUSTER" --query "maintenanceWindow.schedule" -o json 2>/dev/null)
AUTO_SCHED_OLD2=$(az aks show -g "$RG" -n "$CLUSTER" --query "nodeOsUpgradeProfile.schedule" -o json 2>/dev/null)

if [[ -n "$AUTO_SCHED_NEW" && "$AUTO_SCHED_NEW" != "null" ]]; then
  AUTO_UPGRADE_SCHEDULE="$AUTO_SCHED_NEW"
elif [[ -n "$AUTO_SCHED_OLD" && "$AUTO_SCHED_OLD" != "null" ]]; then
  AUTO_UPGRADE_SCHEDULE="$AUTO_SCHED_OLD"
elif [[ -n "$AUTO_SCHED_OLD2" && "$AUTO_SCHED_OLD2" != "null" ]]; then
  AUTO_UPGRADE_SCHEDULE="$AUTO_SCHED_OLD2"
else
  AUTO_UPGRADE_SCHEDULE="Not Configured"
fi

# Node security channel type (modern + legacy)
SEC_TYPE_NEW=$(az aks show -g "$RG" -n "$CLUSTER" --query "securityProfile.nodeOsUpgradeChannel" -o tsv 2>/dev/null)
SEC_TYPE_OLD=$(az aks show -g "$RG" -n "$CLUSTER" --query "upgradeSettings.nodeOSUpgradeChannel" -o tsv 2>/dev/null)

if [[ -n "$SEC_TYPE_NEW" ]]; then
  SECURITY_CHANNEL_TYPE="$SEC_TYPE_NEW"
elif [[ -n "$SEC_TYPE_OLD" ]]; then
  SECURITY_CHANNEL_TYPE="$SEC_TYPE_OLD"
else
  SECURITY_CHANNEL_TYPE="Not Configured"
fi

# Security channel schedule (modern + legacy)
SEC_SCHED_NEW=$(az aks show -g "$RG" -n "$CLUSTER" --query "securityProfile.maintenanceWindow.schedule" -o json 2>/dev/null)
SEC_SCHED_OLD=$(az aks show -g "$RG" -n "$CLUSTER" --query "nodeOsUpgradeProfile.schedule" -o json 2>/dev/null)

if [[ -n "$SEC_SCHED_NEW" && "$SEC_SCHED_NEW" != "null" ]]; then
  SECURITY_CHANNEL_SCHEDULE="$SEC_SCHED_NEW"
elif [[ -n "$SEC_SCHED_OLD" && "$SEC_SCHED_OLD" != "null" ]]; then
  SECURITY_CHANNEL_SCHEDULE="$SEC_SCHED_OLD"
else
  SECURITY_CHANNEL_SCHEDULE="Not Configured"
fi

echo "<button class='collapsible'>Cluster Upgrade & Security Schedule</button>
<div class='content'><pre>
Automatic Upgrade Mode     : $AUTO_UPGRADE_MODE
Upgrade Window Schedule    : $AUTO_UPGRADE_SCHEDULE

Node Security Channel Type : $SECURITY_CHANNEL_TYPE
Security Channel Schedule  : $SECURITY_CHANNEL_SCHEDULE
</pre></div>" >> "$FINAL_REPORT"

############################################################
# AUTOSCALING DETAILS
############################################################
echo "<button class='collapsible'>Autoscaling Status – All Node Pools</button>
<div class='content'><pre>$NODEPOOL_SCALE_FORMATTED</pre></div>" >> "$FINAL_REPORT"

############################################################
# NETWORKING CHECKS
############################################################
NETWORK_MODEL=$(az aks show -g "$RG" -n "$CLUSTER" --query "networkProfile.networkPlugin" -o tsv 2>/dev/null)
API_STATUS=$(kubectl get --raw='/healthz' 2>/dev/null | grep -i ok || echo "FAILED")
API_LATENCY=$(kubectl get --raw='/metrics' 2>/dev/null | grep apiserver_request_duration_seconds_sum | head -1)

echo "<button class='collapsible'>Networking Checks</button>
<div class='content'><pre>
Network Model       : $NETWORK_MODEL
API Server Status   : $API_STATUS
API Server Latency  : $API_LATENCY
</pre></div>" >> "$FINAL_REPORT"

############################################################
# IDENTITY & ACCESS
############################################################
MANAGED_ID=$(az aks show -g "$RG" -n "$CLUSTER" --query identity.type -o tsv 2>/dev/null)
RBAC_ENABLED=$(az aks show -g "$RG" -n "$CLUSTER" --query enableRBAC -o tsv 2>/dev/null)
AAD_ENABLED=$(az aks show -g "$RG" -n "$CLUSTER" --query aadProfile -o json 2>/dev/null | jq -r 'if . == null then "Disabled" else "Enabled" end')

SP_ID=$(az aks show -g "$RG" -n "$CLUSTER" --query servicePrincipalProfile.clientId -o tsv 2>/dev/null)
SP_EXPIRY=$(az ad sp show --id "$SP_ID" --query "passwordCredentials[0].endDateTime" -o tsv 2>/dev/null)

echo "<button class='collapsible'>Identity & Access Checks</button>
<div class='content'><pre>
Managed Identity Type : $MANAGED_ID
RBAC Enabled          : $RBAC_ENABLED
AAD Integration       : $AAD_ENABLED
Service Principal ID  : $SP_ID
Service Principal Exp : $SP_EXPIRY
</pre></div>" >> "$FINAL_REPORT"

############################################################
# OBSERVABILITY CHECKS
############################################################
METRICS_SERVER=$(kubectl get deployment -n kube-system 2>/dev/null | grep metrics-server || echo "Not Installed")
PROM_NODE_EXPORTER=$(kubectl get pods -A 2>/dev/null | grep node-exporter || echo "Not Found")
PROM_PROMETHEUS=$(kubectl get pods -A 2>/dev/null | grep prometheus || echo "Not Found")
GRAFANA=$(kubectl get pods -A 2>/dev/null | grep grafana || echo "Not Found")

echo "<button class='collapsible'>Observability Checks</button>
<div class='content'><pre>
Metrics Server  : $METRICS_SERVER
Node Exporter   : $PROM_NODE_EXPORTER
Prometheus      : $PROM_PROMETHEUS
Grafana         : $GRAFANA
</pre></div>" >> "$FINAL_REPORT"

############################################################
# SECURITY CHECKS
############################################################
POD_SECURITY=$(az aks show -g "$RG" -n "$CLUSTER" --query "securityProfile.podSecurityPolicy.enabled" -o tsv 2>/dev/null)
TLS_ENF=$(az aks show -g "$RG" -n "$CLUSTER" --query "securityProfile.enableTLS" -o tsv 2>/dev/null)
DEFENDER=$(az aks show -g "$RG" -n "$CLUSTER" --query "securityProfile.azureDefender.enabled" -o tsv 2>/dev/null)

echo "<button class='collapsible'>Security Checks</button>
<div class='content'><pre>
Pod Security Admission : $POD_SECURITY
TLS Enforcement        : $TLS_ENF
Azure Defender Enabled : $DEFENDER
Image Scanning         : N/A
</pre></div>" >> "$FINAL_REPORT"

############################################################
# NAMESPACE POD SECURITY ADMISSION
############################################################
NAMESPACE_PSA=$(kubectl get ns -o json 2>/dev/null | \
  jq -r '.items[] |
    [
      .metadata.name,
      (.metadata.labels["pod-security.kubernetes.io/enforce"] // "none"),
      (.metadata.labels["pod-security.kubernetes.io/audit"] // "none"),
      (.metadata.labels["pod-security.kubernetes.io/warn"] // "none")
    ] | @tsv')

echo "<button class='collapsible'>Namespace Pod Security Admission</button>
<div class='content'><pre>" >> "$FINAL_REPORT"

echo -e "NAMESPACE\tENFORCE\tAUDIT\tWARN" >> "$FINAL_REPORT"
echo "$NAMESPACE_PSA" >> "$FINAL_REPORT"

echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# NAMESPACE RBAC (ROLEBINDINGS + CLUSTERROLEBINDINGS)
############################################################
echo "<button class='collapsible'>Namespace RBAC (RoleBindings & ClusterRoleBindings)</button>
<div class='content'><pre>" >> "$FINAL_REPORT"

echo "RoleBindings (namespaced)" >> "$FINAL_REPORT"
kubectl get rolebindings -A -o wide 2>/dev/null | column -t >> "$FINAL_REPORT" || echo "No RoleBindings found" >> "$FINAL_REPORT"

echo "" >> "$FINAL_REPORT"
echo "ClusterRoleBindings (cluster-wide)" >> "$FINAL_REPORT"
kubectl get clusterrolebindings -o wide 2>/dev/null | column -t >> "$FINAL_REPORT" || echo "No ClusterRoleBindings found" >> "$FINAL_REPORT"

echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# NODE LIST (ROLES REMOVED)
############################################################
echo "<button class='collapsible'>Node List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get nodes -o wide 2>/dev/null | awk '{ $3=""; print }' | column -t >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# POD LIST
############################################################
echo "<button class='collapsible'>Pod List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get pods -A -o wide 2>/dev/null | column -t >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# SERVICES LIST
############################################################
echo "<button class='collapsible'>Services List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get svc -A -o wide 2>/dev/null | column -t >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# POD CPU/MEM USAGE
############################################################
echo "<button class='collapsible'>Pod CPU / Memory Usage</button>
<div class='content'><pre>" >> "$FINAL_REPORT"

kubectl top pods -A 2>/dev/null | column -t >> "$FINAL_REPORT" \
 || echo "Metrics Not Available" >> "$FINAL_REPORT"

echo "</pre></div>" >> "$FINAL_REPORT"

set -e  # Restore strict mode for safety

done # cluster loop

echo "</div>" >> "$FINAL_REPORT"

done # subscription loop

echo "</body></html>" >> "$FINAL_REPORT"

echo "===================================================="
echo "AKS HTML Report Generated Successfully"
echo "Saved at: $FINAL_REPORT"
echo "===================================================="
