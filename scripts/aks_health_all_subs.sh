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
# HELPER: FORMAT SCHEDULE LIKE PORTAL
############################################################
format_schedule() {
  local start="$1"
  local freq="$2"
  local days="$3"

  if [[ -z "$start" || "$start" == "null" ]]; then
    echo "Not Configured"
    return 0
  fi

  # Format date into: Sat Dec 06 2025 00:00 +00:00 (Coordinated Universal Time)
  local formatted_start
  if formatted_start=$(date -d "$start" '+%a %b %d %Y %H:%M %z (Coordinated Universal Time)' 2>/dev/null); then
    # Insert colon in offset: +0000 -> +00:00
    formatted_start="${formatted_start/%+0000/+00:00}"
  else
    formatted_start="$start"
  fi

  # Build "Repeats" line
  local repeats=""
  if [[ -n "$freq" || -n "$days" ]]; then
    if [[ "$freq" == "Weekly" && -n "$days" ]]; then
      repeats="Every week on $days"
    elif [[ -n "$freq" && -n "$days" ]]; then
      repeats="$freq on $days"
    elif [[ -n "$freq" ]]; then
      repeats="$freq"
    elif [[ -n "$days" ]]; then
      repeats="On $days"
    fi
  fi

  if [[ -n "$repeats" ]]; then
    echo -e "Start On : $formatted_start\nRepeats  : $repeats"
  else
    echo "Start On : $formatted_start"
  fi
}

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

SUBS=$(az account list --query "[?id=='\$SUB1'].{id:id,name:name}" -o json)

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
    # UPGRADE & SECURITY SCHEDULE (PORTAL STYLE)
    ############################################################

    # Automatic upgrade type (Portal: "Automatic upgrade type: Disabled")
    AUTO_UPGRADE_TYPE_RAW=$(az aks show -g "$RG" -n "$CLUSTER" --query "upgradeSettings.automaticUpgradeType" -o tsv 2>/dev/null)
    if [[ -z "$AUTO_UPGRADE_TYPE_RAW" || "$AUTO_UPGRADE_TYPE_RAW" == "None" ]]; then
      AUTO_UPGRADE_TYPE="Disabled"
    else
      AUTO_UPGRADE_TYPE="$AUTO_UPGRADE_TYPE_RAW"
    fi

    # Automatic upgrade schedule (maintenanceWindow)
    AUTO_SCHED_START=$(az aks show -g "$RG" -n "$CLUSTER" --query "maintenanceWindow.schedule.startDate" -o tsv 2>/dev/null)
    AUTO_SCHED_FREQ=$(az aks show -g "$RG" -n "$CLUSTER" --query "maintenanceWindow.schedule.frequency" -o tsv 2>/dev/null)
    AUTO_SCHED_WEEK=$(az aks show -g "$RG" -n "$CLUSTER" --query "maintenanceWindow.schedule.weekDays | join(', ', @)" -o tsv 2>/dev/null)

    AUTO_SCHED_DISPLAY=$(format_schedule "$AUTO_SCHED_START" "$AUTO_SCHED_FREQ" "$AUTO_SCHED_WEEK")

    # Node channel type (Portal: Node channel type)
    NODE_CHANNEL_TYPE_RAW=$(az aks show -g "$RG" -n "$CLUSTER" --query "upgradeSettings.nodeOSUpgradeChannel" -o tsv 2>/dev/null)
    if [[ -z "$NODE_CHANNEL_TYPE_RAW" || "$NODE_CHANNEL_TYPE_RAW" == "null" ]]; then
      NODE_CHANNEL_TYPE="Not Configured"
    else
      NODE_CHANNEL_TYPE="$NODE_CHANNEL_TYPE_RAW"
    fi

    # Node channel schedule (upgradeSettings.maintenanceWindow)
    NODE_SCHED_START=$(az aks show -g "$RG" -n "$CLUSTER" --query "upgradeSettings.maintenanceWindow.schedule.startDate" -o tsv 2>/dev/null)
    NODE_SCHED_FREQ=$(az aks show -g "$RG" -n "$CLUSTER" --query "upgradeSettings.maintenanceWindow.schedule.frequency" -o tsv 2>/dev/null)
    NODE_SCHED_WEEK=$(az aks show -g "$RG" -n "$CLUSTER" --query "upgradeSettings.maintenanceWindow.schedule.weekDays | join(', ', @)" -o tsv 2>/dev/null)

    NODE_SCHED_DISPLAY=$(format_schedule "$NODE_SCHED_START" "$NODE_SCHED_FREQ" "$NODE_SCHED_WEEK")

    {
      echo "<button class='collapsible'>Cluster Upgrade & Security Schedule</button>"
      echo "<div class='content'><pre>"
      echo "Automatic Upgrade Mode     : $AUTO_UPGRADE_TYPE"
      echo "Upgrade Window Schedule    :"
      echo "$AUTO_SCHED_DISPLAY"
      echo
      echo "Node Security Channel Type : $NODE_CHANNEL_TYPE"
      echo "Security Channel Schedule  :"
      echo "$NODE_SCHED_DISPLAY"
      echo "</pre></div>"
    } >> "$FINAL_REPORT"

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
