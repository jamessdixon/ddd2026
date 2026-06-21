// ============================================================
// STEP 5 of 5 — Azure Front Door Standard
// ============================================================
// Deploys:
//   - Front Door profile (Standard tier)
//   - Endpoint
//   - Origin group with 2 web VM origins (health probe every 30s)
//   - Route: /* → origin group
//
// PRE-REQUISITES: Steps 1-4 must be deployed first.
//
// Build to ARM JSON:
//   az bicep build --file bicep_files/05-front-door.bicep --outfile arm_files/05-front-door.json
//
// Deploy:
//   az deployment group create \
//     --name flowdemo-step5-front-door \
//     --resource-group rg-jxd-ddd \
//     --template-file bicep_files/05-front-door.bicep
//
// Verify:
//   az afd endpoint list -g rg-jxd-ddd --profile-name flowdemo-afd -o table
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────
@description('Short prefix used in every resource name.')
param prefix string = 'flowdemo'

@description('Azure region — used for resources that need a location.')
param location string = 'global'

@description('Public IP address of web VM 1.')
param web1PublicIp string = '20.84.120.171'

@description('Public IP address of web VM 2.')
param web2PublicIp string = '20.127.212.231'

@description('Health probe path — must return 200.')
param healthProbePath string = '/health.aspx'

// ── Front Door Profile ────────────────────────────────────────
resource afdProfile 'Microsoft.Cdn/profiles@2023-05-01' = {
  name: '${prefix}-afd'
  location: 'global'
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 30
  }
}

// ── Endpoint ─────────────────────────────────────────────────
resource afdEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-05-01' = {
  parent: afdProfile
  name: '${prefix}-endpoint'
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

// ── Origin Group ─────────────────────────────────────────────
resource originGroup 'Microsoft.Cdn/profiles/originGroups@2023-05-01' = {
  parent: afdProfile
  name: '${prefix}-web-origins'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: healthProbePath
      probeRequestType: 'HEAD'
      probeProtocol: 'Http'
      probeIntervalInSeconds: 30
    }
    sessionAffinityState: 'Disabled'
  }
}

// ── Origin 1 — flowdemo-web1 ─────────────────────────────────
resource origin1 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  parent: originGroup
  name: '${prefix}-web1'
  properties: {
    hostName: web1PublicIp
    httpPort: 80
    httpsPort: 443
    originHostHeader: web1PublicIp
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: false
  }
}

// ── Origin 2 — flowdemo-web2 ─────────────────────────────────
resource origin2 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  parent: originGroup
  name: '${prefix}-web2'
  properties: {
    hostName: web2PublicIp
    httpPort: 80
    httpsPort: 443
    originHostHeader: web2PublicIp
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: false
  }
}

// ── Route — /* to origin group ───────────────────────────────
resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = {
  parent: afdEndpoint
  name: '${prefix}-route'
  dependsOn: [origin1, origin2]   // origins must exist before route
  properties: {
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: ['Http', 'Https']
    patternsToMatch: ['/*']
    forwardingProtocol: 'HttpOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Disabled'
    enabledState: 'Enabled'
  }
}

// ── Outputs ───────────────────────────────────────────────────
output frontDoorEndpointHostname string = afdEndpoint.properties.hostName
output frontDoorEndpointUrl      string = 'http://${afdEndpoint.properties.hostName}'
output originGroupId             string = originGroup.id
