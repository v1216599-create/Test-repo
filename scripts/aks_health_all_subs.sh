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
# FORMAT DATE LIKE AZURE PORTAL
############################################################
format_schedule() {
  local start="$1"   # format: YYYY-MM-DD 00:00 +00:00
  local freq="$2"    # Weekly
  local days="$3"    # Sunday

  if [[ -z "$start" || "$start" == "null" ]]; then
    echo "Not Configured"
    return 0
  fi

  if formatted=$(date -d "$start" '+%a %b %d %Y %H:%M %z (Coordinated Universal Time)' 2>/dev/null); then
    formatted="${formatted/%+0000/+00:00}"
  else
    formatted="$start"
  fi

  if [[ -n "$freq" && -n "$days" ]]; then
    echo -e "Start On : $formatted\nRepeats  : Every week on $days"
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
.card { background:white; padding:20px; margin-bottom:25px;
        border-radius:12px; box-shadow:0 4px 12px rgba(0,0,0,0.08); }

table { width:100%; border-collapse:collapse; margin-top:15px; border-radius:12px;
        overflow:hidden; font-size:15px; }
th { background:#2c3e50; color:white; padding:12px; text-align:left; }
td { padding:10px; border-bottom:1px solid #eee; }

.healthy-all { background:#c8f7c5 !important; color:#145a32 !important; font-weight:bold; }
.version-ok  { background:#c8f7c5 !important; color:#145a32 !important; font-weight:bold; }

.collapsible {
  background:#3498db; color:white; cursor:pointer; padding:12px;
  width:100%; border-radius:6px; font-size:16px; text-align:left;
  margin-top:12px; }
.collapsible:hover { background:#2980b9; }

.content { padding:12px; display:none; border:1px solid #ccc;
           border-radius:6px; background:#fafafa; }

pre { background:#2d3436; color:#dfe6e9; padding:10px; border-radius:6px; overflow-x:auto; }
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

  if [[ $(echo "$CLUSTERS" | jq length) -eq 0 ]]; then
    echo "<p>No clusters found.</p></div>" >> "$FINAL_REPORT"
    continue
  fi

  ############################################################
  # PROCESS CLUSTERS
  ############################################################
  for cluster in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do

    set +e  # prevent failures

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
    [[ -z "$POD_ERR"  ]] && PC="healthy-all" || PC="bad"
    [[ -z "$PVC_ERR"  ]] && PVC="healthy-all" || PVC="bad"

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
    # MAPPING-BASED AUTOMATIC UPGRADE MODE (PORTAL MATCH)
    ############################################################

    RAW_AUTO=$(az aks show -g "$RG" -n "$CL_NAME" --query "autoUpgradeChannel" -o tsv 2>/dev/null)

    case "$RAW_AUTO" in
      patch)
        AUTO_TYPE="Enabled with patch (recommended)"
        ;;
      stable)
        AUTO_TYPE="Enabled with stable"
        ;;
      rapid)
        AUTO_TYPE="Enabled with rapid"
        ;;
      nodeimage|node-image)
        AUTO_TYPE="Enabled with node image"
        ;;
      none|"")
        AUTO_TYPE="Disabled"
        ;;
      *)
        AUTO_TYPE="Disabled"
        ;;
    esac

    ############################################################
    # MAINTENANCE CONFIG (AUTO UPGRADE)
    ############################################################
    AUTO_MC=$(az aks maintenanceconfiguration show \
        --name aksManagedAutoUpgradeSchedule \
        -g "$RG" \
        --cluster-name "$CL_NAME" -o json 2>/dev/null)

    if [[ -n "$AUTO_MC" ]]; then
      AD=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startDate // empty')
      AT=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startTime // "00:00"')
      AU=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.utcOffset // "+00:00"')
      AW=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek // empty')
      AS="$AD $AT $AU"

      AUTO_SCHED=$(format_schedule "$AS" "Weekly" "$AW")
    else
      AUTO_SCHED="Not Configured"
    fi

    ############################################################
    # NODE OS UPGRADE CHANNEL (PORTAL MAPPING)
    ############################################################
    RAW_NODE=$(az aks show -g "$RG" -n "$CL_NAME" --query "nodeOsUpgradeChannel" -o tsv 2>/dev/null)

    case "$RAW_NODE" in
      NodeImage)
        NODE_TYPE="Node Image"
        ;;
      SecurityPatch)
        NODE_TYPE="Security Patch"
        ;;
      Rapid)
        NODE_TYPE="Rapid"
        ;;
      Stable)
        NODE_TYPE="Stable"
        ;;
      Patch)
        NODE_TYPE="Patch"
        ;;
      ""|null)
        NODE_TYPE="Unmanaged"
        ;;
      *)
        NODE_TYPE="Unmanaged"
        ;;
    esac

    ############################################################
    # MAINTENANCE CONFIG (NODE OS UPGRADE)
    ############################################################
    NODE_MC=$(az aks maintenanceconfiguration show \
        --name aksManagedNodeOSUpgradeSchedule \
        -g "$RG" \
        --cluster-name "$CL_NAME" -o json 2>/dev/null)

    if [[ -n "$NODE_MC" ]]; then
      ND=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.startDate // empty')
      NT=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.startTime // "00:00"')
      NU=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.utcOffset // "+00:00"')
      NW=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek // empty')
      NS="$ND $NT $NU"

      NODE_SCHED=$(format_schedule "$NS" "Weekly" "$NW")
    else
      NODE_SCHED="Not Configured"
    fi

    ############################################################
    # OUTPUT BLOCK
    ############################################################
    echo "<button class='collapsible'>Cluster Upgrade & Security Schedule</button>
<div class='content'><pre>
Automatic Upgrade Mode     : $AUTO_TYPE
Upgrade Window Schedule    :
$AUTO_SCHED

Node Security Channel Type : $NODE_TYPE
Security Channel Schedule  :
$NODE_SCHED
</pre></div>" >> "$FINAL_REPORT"

    ############################################################
    # AUTOSCALING / PSA / RBAC / NODES / PODS / SERVICES / METRICS
    ############################################################

    SCALE=$(az aks nodepool list -g "$RG" --cluster-name "$CL_NAME" -o json \
      | jq -r '.[] | "\(.name): autoscale=\(.enableAutoScaling), min=\(.minCount), max=\(.maxCount)"')

    echo "<button class='collapsible'>Autoscaling Status – All Node Pools</button>
<div class='content'><pre>$SCALE</pre></div>" >> "$FINAL_REPORT"

    PSA=$(kubectl get ns -o json 2>/dev/null | jq -r \
      '.items[] | [.metadata.name,
       (.metadata.labels["pod-security.kubernetes.io/enforce"] // "none"),
       (.metadata.labels["pod-security.kubernetes.io/audit"] // "none"),
       (.metadata.labels["pod-security.kubernetes.io/warn"] // "none")] | @tsv')

    echo "<button class='collapsible'>Namespace Pod Security Admission</button>
<div class='content'><pre>
NAMESPACE    ENFORCE    AUDIT    WARN
$PSA
</pre></div>" >> "$FINAL_REPORT"

    RB1=$(kubectl get rolebindings -A -o wide 2>/dev/null)
    RB2=$(kubectl get clusterrolebindings -o wide 2>/dev/null)

    echo "<button class='collapsible'>Namespace RBAC</button>
<div class='content'><pre>
RoleBindings:
$RB1

ClusterRoleBindings:
$RB2
</pre></div>" >> "$FINAL_REPORT"

    NODES=$(kubectl get nodes -o wide 2>/dev/null)
    PODS=$(kubectl get pods -A -o wide 2>/dev/null)
    SERVICES=$(kubectl get svc -A -o wide 2>/dev/null)

    echo "<button class='collapsible'>Node List</button>
<div class='content'><pre>$NODES</pre></div>" >> "$FINAL_REPORT"

    echo "<button class='collapsible'>Pod List</button>
<div class='content'><pre>$PODS</pre></div>" >> "$FINAL_REPORT"

    echo "<button class='collapsible'>Services List</button>
<div class='content'><pre>$SERVICES</pre></div>" >> "$FINAL_REPORT"

    METRICS=$(kubectl top pods -A 2>/dev/null || echo "Metrics Not Available")

    echo "<button class='collapsible'>Pod CPU/Memory Usage</button>
<div class='content'><pre>$METRICS</pre></div>" >> "$FINAL_REPORT"

    set -e
  done

  echo "</div>" >> "$FINAL_REPORT"

done

echo "</body></html>" >> "$FINAL_REPORT"

echo "===================================================="
echo "AKS HTML Report Generated Successfully"
echo "Saved at: $FINAL_REPORT"
echo "===================================================="
