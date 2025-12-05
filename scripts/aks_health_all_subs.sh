#!/bin/bash
export AZURE_AKS_DISABLE_AUTO_VERSION_CHECK=true
set -e    # strict mode for setup steps

############################################################
# REQUIRED FOR GITHUB ACTIONS
############################################################
export AZURE_CONFIG_DIR="$HOME/.azure"

REPORT_DIR="reports"
mkdir -p "$REPORT_DIR"

FINAL_REPORT="$REPORT_DIR/AKS Cluster Health.html"

############################################################
# FORMAT DATE LIKE AZURE PORTAL
############################################################
format_schedule() {
  local start="$1"
  local freq="$2"
  local days="$3"

  if [[ -z "$start" || "$start" == "null" ]]; then
    echo "Not Configured"
    return 0
  fi

  local formatted_start
  if formatted_start=$(date -d "$start" '+%a %b %d %Y %H:%M %z (Coordinated Universal Time)' 2>/dev/null); then
    formatted_start="${formatted_start/%+0000/+00:00}"
  else
    formatted_start="$start"
  fi

  local repeats=""
  if [[ "$freq" == "Weekly" && -n "$days" ]]; then
    repeats="Every week on $days"
  elif [[ -n "$freq" && -n "$days" ]]; then
    repeats="$freq on $days"
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
body { font-family: Arial; background: #eef2f7; margin: 20px; }
h1 { color: white; }
.card { background:white; padding:20px; border-radius:12px; margin-bottom:25px;
        box-shadow:0 4px 12px rgba(0,0,0,0.08); }
table { width:100%; border-collapse:collapse; margin-top:15px;
        border-radius:12px; overflow:hidden; font-size:15px; }
th { background:#2c3e50; color:white; padding:12px; text-align:left; }
td { padding:10px; border-bottom:1px solid #eee; }

.healthy-all { background:#c8f7c5 !important; color:#145a32 !important; font-weight:bold; }
.version-ok { background:#c8f7c5 !important; color:#145a32 !important; font-weight:bold; }

.collapsible {
  background:#3498db; color:white; cursor:pointer; padding:12px; border:none;
  text-align:left; outline:none; font-size:16px; border-radius:6px; margin-top:12px;
}
.collapsible:hover { background:#2980b9; }

.content {
  padding:12px; display:none; border-radius:6px;
  border:1px solid #ccc; background:#fafafa;
}

pre { background:#2d3436; color:#dfe6e9; padding:10px; border-radius:6px; overflow-x:auto; }
</style>

<script>
document.addEventListener("DOMContentLoaded", () => {
  var c=document.getElementsByClassName("collapsible");
  for(let i=0;i<c.length;i++){
    c[i].addEventListener("click", function(){
      var e=this.nextElementSibling;
      e.style.display = (e.style.display==="block"?"none":"block");
    });
  }
});
</script>

</head><body>
'

############################################################
# START REPORT
############################################################
echo "$HTML_HEADER" > "$FINAL_REPORT"

echo "<div style='background:#3498db;padding:15px;border-radius:6px;'>
<h1>AKS Cluster Health – Report</h1></div>" >> "$FINAL_REPORT"

############################################################
# SUBSCRIPTION LIST
############################################################
SUB1="3f499502-898a-4be8-8dc6-0b6260bd0c8c"

SUBS=$(az account list --query "[?id=='$SUB1'].{id:id,name:name}" -o json)

############################################################
# PROCESS SUBSCRIPTIONS
############################################################
for row in $(echo "$SUBS" | jq -r '.[] | @base64'); do

  pull(){ echo "$row" | base64 --decode | jq -r "$1"; }

  SUB_ID=$(pull '.id')
  SUB_NAME=$(pull '.name')

  echo "<div class='card'><h2>Subscription: $SUB_NAME</h2>
<b>ID:</b> $SUB_ID<br>" >> "$FINAL_REPORT"

  az account set --subscription "$SUB_ID"

  CLUSTERS=$(az aks list --query "[].{name:name,rg:resourceGroup}" -o json)

  [[ $(echo "$CLUSTERS" | jq length) -eq 0 ]] && {
    echo "<p>No clusters found.</p></div>" >> "$FINAL_REPORT"
    continue
  }

  ############################################################
  # FOR EACH CLUSTER
  ############################################################
  for cluster in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do

    # ⛔ IMPORTANT FIX — prevent script from exiting on any kubectl/az error
    set +e

    pullc(){ echo "$cluster" | base64 --decode | jq -r "$1"; }

    CL_NAME=$(pullc '.name')
    RG=$(pullc '.rg')

    echo "[INFO] Processing cluster $CL_NAME"

    az aks get-credentials -g "$RG" -n "$CL_NAME" --overwrite-existing >/dev/null 2>&1

    VERSION=$(az aks show -g "$RG" -n "$CL_NAME" --query kubernetesVersion -o tsv)

    NODE_ERR=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"')
    POD_ERR=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="CrashLoopBackOff"')
    PVC_ERR=$(kubectl get pvc -A 2>/dev/null | grep -i failed)

    [[ -z "$NODE_ERR" ]] && NC="healthy-all" || NC="bad"
    [[ -z "$POD_ERR" ]] && PC="healthy-all" || PC="bad"
    [[ -z "$PVC_ERR" ]] && PVC="healthy-all" || PVC="bad"

    echo "<div class='card'>
<h3>Cluster: $CL_NAME</h3>
<table>
<tr><th>Check</th><th>Status</th></tr>
<tr class='$NC'><td>Node Health</td><td>$( [[ $NC == healthy-all ]] && echo ✓ Healthy || echo ✗ Issues )</td></tr>
<tr class='$PC'><td>Pod Health</td><td>$( [[ $PC == healthy-all ]] && echo ✓ Healthy || echo ✗ Issues )</td></tr>
<tr class='$PVC'><td>PVC Health</td><td>$( [[ $PVC == healthy-all ]] && echo ✓ Healthy || echo ✗ Issues )</td></tr>
<tr class='version-ok'><td>Cluster Version</td><td>$VERSION</td></tr>
</table></div>" >> "$FINAL_REPORT"

    ############################################################
    # UPGRADE & MAINTENANCE WINDOWS — ALL VERSION SUPPORT
    ############################################################

    AUTO_TYPE=$(az aks show -g "$RG" -n "$CL_NAME" --query "upgradeSettings.automaticUpgradeType" -o tsv)
    [[ -z "$AUTO_TYPE" || "$AUTO_TYPE" == "None" ]] && AUTO_TYPE="Disabled"

    AUTO_START=$(az aks show -g "$RG" -n "$CL_NAME" --query "maintenanceWindow.schedule.startDate" -o tsv)
    AUTO_FREQ=$(az aks show -g "$RG" -n "$CL_NAME" --query "maintenanceWindow.schedule.frequency" -o tsv)
    AUTO_DAYS=$(az aks show -g "$RG" -n "$CL_NAME" --query "maintenanceWindow.schedule.weekDays | join(', ', @)" -o tsv)

    AUTO_SCHED=$(format_schedule "$AUTO_START" "$AUTO_FREQ" "$AUTO_DAYS")

    NODE_CH=$(az aks show -g "$RG" -n "$CL_NAME" --query "upgradeSettings.nodeOSUpgradeChannel" -o tsv)
    [[ -z "$NODE_CH" || "$NODE_CH" == "null" ]] && NODE_CH="Not Configured"

    NODE_START=$(az aks show -g "$RG" -n "$CL_NAME" --query "upgradeSettings.maintenanceWindow.schedule.startDate" -o tsv)
    NODE_FREQ=$(az aks show -g "$RG" -n "$CL_NAME" --query "upgradeSettings.maintenanceWindow.schedule.frequency" -o tsv)
    NODE_DAYS=$(az aks show -g "$RG" -n "$CL_NAME" --query "upgradeSettings.maintenanceWindow.schedule.weekDays | join(', ', @)" -o tsv)

    NODE_SCHED=$(format_schedule "$NODE_START" "$NODE_FREQ" "$NODE_DAYS")

    echo "<button class='collapsible'>Cluster Upgrade & Security Schedule</button>
<div class='content'><pre>
Automatic Upgrade Mode     : $AUTO_TYPE
Upgrade Window Schedule    :
$AUTO_SCHED

Node Security Channel Type : $NODE_CH
Security Channel Schedule  :
$NODE_SCHED
</pre></div>" >> "$FINAL_REPORT"

    ############################################################
    # AUTOSCALING
    ############################################################
    SCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CL_NAME" -o json \
      | jq -r '.[] | "\(.name): autoscale=\(.enableAutoScaling), min=\(.minCount), max=\(.maxCount)"')

    echo "<button class='collapsible'>Autoscaling Status – All Node Pools</button>
<div class='content'><pre>$SCALE</pre></div>" >> "$FINAL_REPORT"

    ############################################################
    # PSA LABELS
    ############################################################
    PSA=$(kubectl get ns -o json | jq -r \
      '.items[] | [.metadata.name,
       (.metadata.labels["pod-security.kubernetes.io/enforce"] // "none"),
       (.metadata.labels["pod-security.kubernetes.io/audit"] // "none"),
       (.metadata.labels["pod-security.kubernetes.io/warn"] // "none")] | @tsv')

    echo "<button class='collapsible'>Namespace Pod Security Admission</button>
<div class='content'><pre>
NAMESPACE    ENFORCE    AUDIT    WARN
$PSA
</pre></div>" >> "$FINAL_REPORT"

    ############################################################
    # RBAC
    ############################################################
    RB1=$(kubectl get rolebindings -A -o wide 2>/dev/null)
    RB2=$(kubectl get clusterrolebindings -o wide 2>/dev/null)

    echo "<button class='collapsible'>Namespace RBAC</button>
<div class='content'><pre>
RoleBindings:
$RB1

ClusterRoleBindings:
$RB2
</pre></div>" >> "$FINAL_REPORT"

    ############################################################
    # Nodes / Pods / Services
    ############################################################
    NODES=$(kubectl get nodes -o wide 2>/dev/null)
    PODS=$(kubectl get pods -A -o wide 2>/dev/null)
    SERVICES=$(kubectl get svc -A -o wide 2>/dev/null)

    echo "<button class='collapsible'>Node List</button>
<div class='content'><pre>$NODES</pre></div>" >> "$FINAL_REPORT"

    echo "<button class='collapsible'>Pod List</button>
<div class='content'><pre>$PODS</pre></div>" >> "$FINAL_REPORT"

    echo "<button class='collapsible'>Services List</button>
<div class='content'><pre>$SERVICES</pre></div>" >> "$FINAL_REPORT"

    ############################################################
    # METRICS
    ############################################################
    METRICS=$(kubectl top pods -A 2>/dev/null || echo "Metrics Not Available")

    echo "<button class='collapsible'>Pod CPU/Memory Usage</button>
<div class='content'><pre>$METRICS</pre></div>" >> "$FINAL_REPORT"

    # Restore strict mode for next cluster setup
    set -e

  done  # cluster loop

  echo "</div>" >> "$FINAL_REPORT"

done  # subscription loop

############################################################
# FOOTER
############################################################
echo "</body></html>" >> "$FINAL_REPORT"

echo "===================================================="
echo "AKS HTML Report Generated Successfully"
echo "Saved at: $FINAL_REPORT"
echo "===================================================="
