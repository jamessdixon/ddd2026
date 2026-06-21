// ============================================================
// STEP 2 of 5 — VNet Flow Logs + Log Analytics Workspace
// ============================================================
// Uses VNet Flow Logs (not NSG flow logs which are retired).
// VNet Flow Logs capture all traffic at the virtual network
// level and populate NTANetAnalytics via Traffic Analytics.
//
// Deploys:
//   - Log Analytics Workspace (NTANetAnalytics lands here)
//   - Storage Account (raw flow log JSON)
//   - VNet Flow Log on flowdemo-vnet with Traffic Analytics
//
// PRE-REQUISITE: Step 1 must be deployed first.
//
// Build to ARM JSON:
//   az bicep build --file bicep_files/02-flowlogs.bicep --outfile arm_files/02-flowlogs.json
//
// Deploy:
//   az deployment group create \
//     --name flowdemo-step2-flowlogs \
//     --resource-group NetworkWatcherRG \
//     --template-file 02-flowlogs.bicep
//
// Verify:
//   az monitor log-analytics workspace list -g NetworkWatcherRG -o table
//   az storage account list -g NetworkWatcherRG -o table
//   az network watcher flow-log list --location eastus -o table
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────
@description('Short prefix used in every resource name.')
param prefix string = 'flowdemo'

@description('Azure region — must match Step 1.')
param location string = 'eastus'

// ── Reference to VNet created in Step 1 ──────────────────────
// Scoped to rg-jxd-ddd where the VNet lives.
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: '${prefix}-vnet'
  scope: resourceGroup('rg-jxd-ddd')
}

// ── Log Analytics Workspace ───────────────────────────────────
// NTANetAnalytics is populated here by Traffic Analytics.
// Allow 10-20 minutes after first traffic before records appear.
resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${prefix}-law'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ── Storage Account ───────────────────────────────────────────
// Stores raw flow log JSON before Traffic Analytics processes
// them into the Log Analytics workspace.
// Name must be globally unique, 3-24 chars, lowercase alphanumeric.
var storageAccountName = take('${replace(prefix, '-', '')}flowlogs${uniqueString(resourceGroup().id)}', 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

// ── Network Watcher ───────────────────────────────────────────
// Already exists in NetworkWatcherRG — reference it by name.
// This deployment targets NetworkWatcherRG so no scope crossing needed.
resource networkWatcher 'Microsoft.Network/networkWatchers@2023-09-01' existing = {
  name: 'NetworkWatcher_${location}'
}

// ── VNet Flow Log ─────────────────────────────────────────────
// Single flow log on the VNet captures ALL traffic across all
// subnets — web, app, and db — in one resource.
// Traffic Analytics at 10-minute intervals populates
// NTANetAnalytics as fast as possible.
resource vnetFlowLog 'Microsoft.Network/networkWatchers/flowLogs@2023-09-01' = {
  parent: networkWatcher
  name: '${prefix}-vnet-flowlog'
  location: location
  properties: {
    storageId: storageAccount.id
    targetResourceId: vnet.id    // VNet ID — not NSG ID
    enabled: true
    retentionPolicy: {
      days: 7
      enabled: true
    }
    format: {
      type: 'JSON'
      version: 2
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceId: workspace.properties.customerId
        workspaceRegion: location
        workspaceResourceId: workspace.id
        trafficAnalyticsInterval: 10   // 10 min = fastest available
      }
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────
output workspaceName       string = workspace.name
output workspaceId         string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output storageAccountName  string = storageAccount.name
output flowLogName         string = vnetFlowLog.name
