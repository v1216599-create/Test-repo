#!/bin/bash
export AZURE_AKS_DISABLE_AUTO_VERSION_CHECK=true
set -e

export AZURE_CONFIG_DIR="$HOME/.azure"
REPORT_DIR="reports"
mkdir -p "$REPORT_DIR"
FINAL_REPORT="$REPORT_DIR/AKS Cluster Health.html"

############################################################
# DATE FORMATTER (MATCH AZURE PORTAL)
############################################################
format_schedule() {
  local start="$1"; local freq="$2"; local dow="$3"
  if [[ -z "$start" || "$start" == "null" ]]; then echo "Not Configured"; return; fi
  if formatted=$(date -d "$start" '+%a %b %d %Y %H:%M %z (Coordinated Universal Time)' 2>/dev/null); then
      formatted="${formatted/%+0000/+00:00}"
  else formatted="$start"; fi
  if [[ -n "$freq" && -n "$dow" ]]; then
      echo -e "Start On : $formatted\nRepeats  : Every week on $dow"
  else echo "Start On : $formatted"; fi
}

############################################################
# HTML HEADER
############################################################
HTML_HEADER='
<html><head>
<title>AKS Cluster Health – Report</title>
<style>
body {font-family:Arial;background:#eef2f7;margin:20px;}
h1 {color:white;}
.card {background:white;padding:20px;margin-bottom:35px;border-radius:12px;
 box-shadow:0 4px 12px rgba(0,0,0,0.08);}
table {width:100%;border-collapse:collapse;margin-top:15px;font-size:15px;}
th {background:#2c3e50;color:white;padding:12px;text-align:left;}
td {padding:10px;border-bottom:1px solid #eee;}
.healthy-all {background:#c8f7c5 !important;color:#145a32 !important;font-weight:bold;}
.version-ok {background:#c8f7c5 !important;color:#145a32 !important;font-weight:bold;}
.collapsible {background:#3498db;color:white;cursor:pointer;padding:12px;width:100%;
 border-radius:6px;font-size:16px;text-align:left;margin-top:25px;}
.collapsible:hover {background:#2980b9;}
.content {padding:12px;display:none;border:1px solid #ccc;border-radius:6px;
 background:#fafafa;margin-bottom:25px;}
pre {background:#2d3436;color:#dfe6e9;padding:10px;border-radius:6px;overflow-x:auto;}
</style>
<script>
document.addEventListener("DOMContentLoaded",()=>{
  var c=document.getElementsByClassName("collapsible");
  for(let i=0;i<c.length;i++){
    c[i].addEventListener("click",function(){
      var e=this.nextElementSibling;
      e.style.display=e.style.display==="block"?"none":"block";
    });
  }
});
</script></head><body>
'

echo "$HTML_HEADER" > "$FINAL_REPORT"

echo "<div style='background:#3498db;padding:15px;border-radius:6px;'>
<h1>AKS Cluster Health – Report</h1></div>" >> "$FINAL_REPORT"

############################################################
# SUBSCRIPTIONS
############################################################
SUBSCRIPTION="3f499502-898a-4be8-8dc6-0b6260bd0c8c"
SUBS=$(az account list --query "[?id=='$SUBSCRIPTION']" -o json)

############################################################
# SUBSCRIPTION LOOP
############################################################
for S in $(echo "$SUBS" | jq -r '.[] | @base64'); do
  pull(){ echo "$S" | base64 --decode | jq -r "$1"; }

  SUB_ID=$(pull '.id')
  SUB_NAME=$(pull '.name')

  echo "<div class='card'><h2>Subscription: $SUB_NAME</h2>
  <b>ID:</b> $SUB_ID<br>" >> "$FINAL_REPORT"

  az account set --subscription "$SUB_ID"

  CLUSTERS=$(az aks list -o json)
  if [[ $(echo "$CLUSTERS" | jq length) -eq 0 ]]; then
     echo "<p>No AKS clusters found.</p></div>" >> "$FINAL_REPORT"
     continue
  fi

############################################################
# CLUSTER LOOP
############################################################
for CL in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do
  pullc(){ echo "$CL" | base64 --decode | jq -r "$1"; }

  CLUSTER=$(pullc '.name')
  RG=$(pullc '.resourceGroup')

  echo "[INFO] Processing: $CLUSTER"

  set +e
  az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null 2>&1
  set -e

############################################################
# HEALTH CHECKS
############################################################
VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv)

NODE_ERR=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"')
POD_ERR=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="CrashLoopBackOff"')
PVC_ERR=$(kubectl get pvc -A 2>/dev/null | grep -i failed)

[[ -z "$NODE_ERR" ]] && NC="healthy-all" || NC="bad"
[[ -z "$POD_ERR" ]]  && PC="healthy-all" || PC="bad"
[[ -z "$PVC_ERR" ]]  && PVC="healthy-all" || PVC="bad"

############################################################
# SUMMARY TABLE
############################################################
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
# AUTOMATIC UPGRADE MODE (new + old fields)
############################################################
RAW_AUTO_NEW=$(az aks show -g "$RG" -n "$CLUSTER" --query "autoUpgradeProfile.upgradeChannel" -o tsv)
RAW_AUTO_OLD=$(az aks show -g "$RG" -n "$CLUSTER" --query "autoUpgradeChannel" -o tsv)

if [[ -n "$RAW_AUTO_NEW" && "$RAW_AUTO_NEW" != "null" ]]; then RAW_AUTO="$RAW_AUTO_NEW"; else RAW_AUTO="$RAW_AUTO_OLD"; fi

case "$RAW_AUTO" in
  patch|Patch) AUTO_MODE="Enabled with patch (recommended)" ;;
  stable|Stable) AUTO_MODE="Enabled with stable" ;;
  rapid|Rapid) AUTO_MODE="Enabled with rapid" ;;
  nodeimage|NodeImage) AUTO_MODE="Enabled with node image" ;;
  ""|null) AUTO_MODE="Disabled" ;;
  *) AUTO_MODE="Disabled" ;;
esac

############################################################
# UPGRADE SCHEDULERS
############################################################
AUTO_MC=$(az aks maintenanceconfiguration show --name aksManagedAutoUpgradeSchedule -g "$RG" --cluster-name "$CLUSTER" -o json 2>/dev/null)
if [[ -n "$AUTO_MC" ]]; then
  AD=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startDate')
  AT=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startTime')
  AU=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.utcOffset')
  AW=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek')
  AUTO_SCHED=$(format_schedule "$AD $AT $AU" "Weekly" "$AW")
else AUTO_SCHED="Not Configured"; fi

NODE_MC=$(az aks maintenanceconfiguration show --name aksManagedNodeOSUpgradeSchedule -g "$RG" --cluster-name "$CLUSTER" -o json 2>/dev/null)
if [[ -n "$NODE_MC" ]]; then
  ND=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.startDate')
  NT=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.startTime')
  NU=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.utcOffset')
  NW=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek')
  NODE_SCHED=$(format_schedule "$ND $NT $NU" "Weekly" "$NW")
else NODE_SCHED="Not Configured"; fi

############################################################
# NODE SECURITY CHANNEL TYPE
############################################################
RAW_NODE=$(az aks show -g "$RG" -n "$CLUSTER" --query "autoUpgradeProfile.nodeOSUpgradeChannel" -o tsv)

case "$RAW_NODE" in
  NodeImage) NODE_TYPE="Node Image" ;;
  SecurityPatch) NODE_TYPE="Security Patch" ;;
  Patch) NODE_TYPE="Patch" ;;
  Stable) NODE_TYPE="Stable" ;;
  Rapid) NODE_TYPE="Rapid" ;;
  ""|null) NODE_TYPE="Unmanaged" ;;
  *) NODE_TYPE="Unmanaged" ;;
esac

############################################################
# UPGRADE BLOCK
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
# AUTOSCALING STATUS
############################################################
SCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" -o json \
 | jq -r '.[] |
      if .enableAutoScaling==true then
        "\(.name): autoscale=true, min=\(.minCount), max=\(.maxCount)"
      else
        "\(.name): autoscale=false, count=\(.count)"
      end')

echo "<button class='collapsible'>Autoscaling Status – All Node Pools</button>
<div class='content'><pre>$SCALE</pre></div>" >> "$FINAL_REPORT"

############################################################
# SCALE METHOD (Autoscale / Manual)
############################################################
NODEPOOL_METHOD=$(az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" -o json \
 | jq -r '
   .[] |
   if .enableAutoScaling then
       "\(.name): Scale method = Autoscale (min=\(.minCount), max=\(.maxCount))"
   else
       "\(.name): Scale method = Manual (count=\(.count))"
   end')

############################################################
# NODE LIST
############################################################
echo "<button class='collapsible'>Node List</button>
<div class='content'><pre>" >> "$FINAL_REPORT"

echo "=== Node Pool Scale Method ===" >> "$FINAL_REPORT"
echo "$NODEPOOL_METHOD" >> "$FINAL_REPORT"
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
# SERVICES LIST
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
kubectl top pods -A 2>/dev/null || echo "Metrics Server Not Installed" >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# END CLUSTER LOOP
############################################################
done

echo "</div>" >> "$FINAL_REPORT"

############################################################
# END SUB LOOP
############################################################
done

echo "</body></html>" >> "$FINAL_REPORT"

echo "===================================================="
echo "AKS HTML Report Generated Successfully"
echo "Saved at: $FINAL_REPORT"
echo "===================================================="
