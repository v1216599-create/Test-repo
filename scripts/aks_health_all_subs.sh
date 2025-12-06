#!/bin/bash
# Disable exit-on-error globally (important for GitHub Actions)
set +e

export AZURE_AKS_DISABLE_AUTO_VERSION_CHECK=true

############################################################
# REQUIRED FOR GITHUB ACTIONS
############################################################
export AZURE_CONFIG_DIR="$HOME/.azure"

REPORT_DIR="reports"
mkdir -p "$REPORT_DIR"
FINAL_REPORT="$REPORT_DIR/AKS Cluster Health.html"

############################################################
# FORMAT DATE EXACTLY LIKE AZURE PORTAL
############################################################
format_schedule() {
  local start="$1"
  local freq="$2"
  local dow="$3"

  if [[ -z "$start" || "$start" == "null" ]]; then
    echo "Not Configured"
    return
  fi

  if formatted=$(date -d "$start" '+%a %b %d %Y %H:%M %z (Coordinated Universal Time)' 2>/dev/null); then
    formatted="${formatted/%+0000/+00:00}"
  else
    formatted="$start"
  fi

  if [[ -n "$freq" && -n "$dow" ]]; then
    echo -e "Start On : $formatted\nRepeats  : Every week on $dow"
  else
    echo "Start On : $formatted"
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
body { font-family: Arial; background:#eef2f7; margin:20px; }
h1 { color:white; }

.card {
  background:white; padding:20px; margin-bottom:35px;
  border-radius:12px; box-shadow:0 4px 12px rgba(0,0,0,0.08);
}

table {
  width:100%; border-collapse:collapse; margin-top:15px;
  border-radius:12px; overflow:hidden; font-size:15px;
}

th {
  background:#2c3e50; color:white; padding:12px; text-align:left;
}

td {
  padding:10px; border-bottom:1px solid #eee;
}

.healthy-all {
  background:#c8f7c5 !important; color:#145a32 !important; font-weight:bold;
}

.version-ok {
  background:#c8f7c5 !important; color:#145a32 !important; font-weight:bold;
}

.collapsible {
  background:#3498db; color:white; cursor:pointer;
  padding:12px; width:100%; border-radius:6px;
  font-size:16px; text-align:left; margin-top:25px !important;
}
.collapsible:hover { background:#2980b9; }

.content {
  padding:12px; display:none; border:1px solid #ccc;
  border-radius:6px; background:#fafafa; margin-bottom:25px;
}

pre {
  background:#2d3436; color:#dfe6e9; padding:10px;
  border-radius:6px; overflow-x:auto;
}
</style>

<script>
document.addEventListener("DOMContentLoaded",()=>{
  var c=document.getElementsByClassName("collapsible");
  for(let i=0;i<c.length;i++){
    c[i].addEventListener("click",function(){
      var e=this.nextElementSibling;
      e.style.display = (e.style.display==="block"?"none":"block");
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

echo "<div style='background:#3498db;padding:15px;border-radius:6px;'>
<h1>AKS Cluster Health – Report</h1></div>" >> "$FINAL_REPORT"

############################################################
# SUBSCRIPTIONS (add more if needed)
############################################################
SUBSCRIPTION="3f499502-898a-4be8-8dc6-0b6260bd0c8c"
SUBS=$(az account list --query "[?id=='$SUBSCRIPTION']" -o json 2>/dev/null)

############################################################
# SUBSCRIPTION LOOP
############################################################
for S in $(echo "$SUBS" | jq -r '.[] | @base64'); do
  pull(){ echo "$S" | base64 --decode | jq -r "$1"; }

  SUB_ID=$(pull '.id')
  SUB_NAME=$(pull '.name')

  echo "<div class='card'><h2>Subscription: $SUB_NAME</h2>
<b>ID:</b> $SUB_ID<br>" >> "$FINAL_REPORT"

  az account set --subscription "$SUB_ID" >/dev/null 2>&1

  CLUSTERS=$(az aks list --query "[].{name:name,rg:resourceGroup}" -o json 2>/dev/null)

  if [[ -z "$CLUSTERS" || $(echo "$CLUSTERS" | jq length) -eq 0 ]]; then
     echo "<p>No AKS clusters found.</p></div>" >> "$FINAL_REPORT"
     continue
  fi

############################################################
# CLUSTER LOOP
############################################################
for CL in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do

  pullc(){ echo "$CL" | base64 --decode | jq -r "$1"; }

  CLUSTER=$(pullc '.name')
  RG=$(pullc '.rg')

  echo "[INFO] Processing: $CLUSTER"

  ########################################################
  # SAFE CREDENTIALS
  ########################################################
  az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
      echo "[ERROR] Cannot get credentials for $CLUSTER – skipping"
      continue
  fi

  kubectl get nodes >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
      echo "[ERROR] kubectl cannot contact $CLUSTER – skipping"
      continue
  fi

  ########################################################
  # HEALTH CHECKS
  ########################################################
  VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv 2>/dev/null)

  NODE_ERR=$(kubectl get nodes --no-headers | awk '$2!="Ready"')
  POD_ERR=$(kubectl get pods -A --no-headers | awk '$4=="CrashLoopBackOff"')
  PVC_ERR=$(kubectl get pvc -A | grep -i failed)

  [[ -z "$NODE_ERR" ]] && NC="healthy-all" || NC="bad"
  [[ -z "$POD_ERR"  ]] && PC="healthy-all"   || PC="bad"
  [[ -z "$PVC_ERR"  ]] && PVC="healthy-all"  || PVC="bad"

  ########################################################
  # SUMMARY
  ########################################################
echo "<div class='card'>
<h3>Cluster: $CLUSTER</h3>
<table>
<tr><th>Check</th><th>Status</th></tr>

<tr class='$NC'><td>Node Health</td><td>$( [[ $NC == healthy-all ]] && echo ✓ Healthy || echo ✗ Issues )</td></tr>
<tr class='$PC'><td>Pod Health</td><td>$( [[ $PC == healthy-all ]] && echo ✓ Healthy || echo ✗ Issues )</td></tr>
<tr class='$PVC'><td>PVC Health</td><td>$( [[ $PVC == healthy-all ]] && echo ✓ Healthy || echo ✗ Issues )</td></tr>
<tr class='version-ok'><td>Cluster Version</td><td>$VERSION</td></tr>
</table></div>" >> "$FINAL_REPORT"


############################################################
# AUTO UPGRADE MODE (new + old fields)
############################################################
RAW_AUTO_NEW=$(az aks show -g "$RG" -n "$CLUSTER" --query "autoUpgradeProfile.upgradeChannel" -o tsv 2>/dev/null)
RAW_AUTO_OLD=$(az aks show -g "$RG" -n "$CLUSTER" --query "autoUpgradeChannel" -o tsv 2>/dev/null)

if [[ "$RAW_AUTO_NEW" != "null" && -n "$RAW_AUTO_NEW" ]]; then
  RAW_AUTO="$RAW_AUTO_NEW"
else
  RAW_AUTO="$RAW_AUTO_OLD"
fi

case "$RAW_AUTO" in
  patch|Patch)        AUTO_MODE="Enabled with patch (recommended)" ;;
  stable|Stable)      AUTO_MODE="Enabled with stable" ;;
  rapid|Rapid)        AUTO_MODE="Enabled with rapid" ;;
  nodeimage|NodeImage|node-image) AUTO_MODE="Enabled with node image" ;;
  ""|null)            AUTO_MODE="Disabled" ;;
  *)                  AUTO_MODE="Disabled" ;;
esac


############################################################
# CLUSTER UPGRADE WINDOW (aksManagedAutoUpgradeSchedule)
############################################################
AUTO_MC=$(az aks maintenanceconfiguration show \
    --name aksManagedAutoUpgradeSchedule \
    -g "$RG" \
    --cluster-name "$CLUSTER" -o json 2>/dev/null)

if [[ -n "$AUTO_MC" ]]; then
  AD=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startDate // empty')
  AT=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startTime // "00:00"')
  AU=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.utcOffset // "+00:00"')
  AW=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek // empty')
  AUTO_SCHED=$(format_schedule "$AD $AT $AU" "Weekly" "$AW")
else
  AUTO_SCHED="Not Configured"
fi


############################################################
# NODE CHANNEL TYPE (Node Security Channel Type)
# Try new field first, then fallback top-level nodeOsUpgradeChannel
############################################################
RAW_NODE=$(az aks show -g "$RG" -n "$CLUSTER" \
           --query "autoUpgradeProfile.nodeOSUpgradeChannel" -o tsv 2>/dev/null)

if [[ -z "$RAW_NODE" || "$RAW_NODE" == "null" ]]; then
  RAW_NODE=$(az aks show -g "$RG" -n "$CLUSTER" \
             --query "nodeOsUpgradeChannel" -o tsv 2>/dev/null)
fi

case "$RAW_NODE" in
  NodeImage|nodeimage|node-image)
    NODE_TYPE="Node Image"
    ;;
  SecurityPatch|securitypatch)
    NODE_TYPE="Security Patch"
    ;;
  Patch|patch)
    NODE_TYPE="Patch"
    ;;
  Stable|stable)
    NODE_TYPE="Stable"
    ;;
  Rapid|rapid)
    NODE_TYPE="Rapid"
    ;;
  Unmanaged|unmanaged|None|none|""|null)
    NODE_TYPE="Unmanaged"
    ;;
  *)
    NODE_TYPE="Unmanaged"
    ;;
esac


############################################################
# NODE OS WINDOW (aksManagedNodeOSUpgradeSchedule)
############################################################
NODE_MC=$(az aks maintenanceconfiguration show \
        --name aksManagedNodeOSUpgradeSchedule \
        -g "$RG" \
        --cluster-name "$CLUSTER" -o json 2>/dev/null)

if [[ -n "$NODE_MC" ]]; then
  ND=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.startDate // empty')
  NT=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.startTime // "00:00"')
  NU=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.utcOffset // "+00:00"')
  NW=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek // empty')
  NODE_SCHED=$(format_schedule "$ND $NT $NU" "Weekly" "$NW")
else
  NODE_SCHED="Not Configured"
fi


############################################################
# SHOW UPGRADE & SECURITY SCHEDULE
############################################################
echo "<button class='collapsible'>Cluster Upgrade & Security Schedule</button>
<div class='content'><pre>
Automatic Upgrade Mode     : $AUTO_MODE

Upgrade Window Schedule    :
$AUTO_SCHED

Node Security Channel Type : $NODE_TYPE
Security Channel Schedule  :
$NODE_SCHED
</pre></div>" >> "$FINAL_REPORT"



############################################################
# SCALE METHOD FIX (Portal Accurate)
############################################################
NODEPOOL_METHOD=""
NODEPOOLS_JSON=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" -o json 2>/dev/null)

for row in $(echo "$NODEPOOLS_JSON" | jq -r '.[] | @base64'); do
  _np() { echo "$row" | base64 --decode | jq -r "$1"; }

  NP_NAME=$(_np '.name')
  NP_AUTO=$(_np '.enableAutoScaling')
  NP_MIN=$(_np '.minCount')
  NP_MAX=$(_np '.maxCount')
  NP_COUNT=$(_np '.count')

  if [[ "$NP_AUTO" == "true" ]]; then
    METHOD="Scale method = Autoscale (min=$NP_MIN, max=$NP_MAX)"
  else
    # Fix NULL count: when count is null, derive from kubectl
    if [[ "$NP_COUNT" == "null" || -z "$NP_COUNT" ]]; then
      REAL_COUNT=$(kubectl get nodes --selector agentpool="$NP_NAME" --no-headers 2>/dev/null | wc -l)
      METHOD="Scale method = Manual (count=$REAL_COUNT)"
    else
      METHOD="Scale method = Manual (count=$NP_COUNT)"
    fi
  fi

  NODEPOOL_METHOD="${NODEPOOL_METHOD}${NP_NAME}: ${METHOD}\n"
done


############################################################
# AUTOSCALING STATUS (raw autoscale=true/false)
############################################################
SCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" -o json 2>/dev/null \
  | jq -r '
      .[] |
      if .enableAutoScaling == true then
         "\(.name): autoscale=true,  min=\(.minCount), max=\(.maxCount)"
      else
         "\(.name): autoscale=false, count=\(.count)"
      end
    ')

echo "<button class='collapsible'>Autoscaling Status – All Node Pools</button>
<div class='content'><pre>$SCALE</pre></div>" >> "$FINAL_REPORT"



############################################################
# PSA
############################################################
PSA=$(kubectl get ns -o json 2>/dev/null | jq -r '
  .items[] |
  [.metadata.name,
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
# NODE LIST (with Scale Method)
############################################################
echo "<button class='collapsible'>Node List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"

echo "=== Node Pool Scale Method ===" >> "$FINAL_REPORT"
echo -e "$NODEPOOL_METHOD" >> "$FINAL_REPORT"

echo "" >> "$FINAL_REPORT"
echo "=== Kubernetes Nodes ===" >> "$FINAL_REPORT"
kubectl get nodes -o wide 2>/dev/null >> "$FINAL_REPORT"

echo "</pre></div>" >> "$FINAL_REPORT"


############################################################
# POD LIST
############################################################
echo "<button class='collapsible'>Pod List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get pods -A -o wide 2>/dev/null >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"


############################################################
# SERVICES
############################################################
echo "<button class='collapsible'>Services List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get svc -A -o wide 2>/dev/null >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"


############################################################
# METRICS
############################################################
echo "<button class='collapsible'>Pod CPU / Memory Usage</button>
<div class='content'><pre>" >> "$FINAL_REPORT"
kubectl top pods -A 2>/dev/null || echo "Metrics not available" >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"


done   # cluster loop

echo "</div>" >> "$FINAL_REPORT"

done # subscription loop


echo "</body></html>" >> "$FINAL_REPORT"

echo "===================================================="
echo "AKS HTML Report Generated Successfully"
echo "Saved at: $FINAL_REPORT"
echo "===================================================="

exit 0
