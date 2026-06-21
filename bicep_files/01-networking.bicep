// ============================================================
// STEP 1 of 5 — Networking Foundation
// ============================================================
// Deploys:
//   - Virtual Network (10.0.0.0/16)
//   - web-subnet    10.0.1.0/24  + web-nsg
//   - lb-subnet     10.0.4.0/24  + lb-nsg   (App LB VM — own subnet for cross-subnet flow visibility)
//   - app-subnet    10.0.2.0/24  + app-nsg  (App VMs)
//   - db-subnet     10.0.3.0/24  + db-nsg
//
// All parameters have defaults — edit them directly below before deploying.
// ⚠ Set rdpAllowedCidr to your own IP: curl ifconfig.me
//
// PRE-REQUISITE — create the resource group first (one-time):
//   az group create --name flowdemo-rg --location eastus
//
// Build to ARM JSON:
//   az bicep build --file bicep_files/01-networking.bicep --outfile arm_files/01-networking.json
//
// Deploy:
//   az deployment group create \
//     --name flowdemo-step1-networking \
//     --resource-group flowdemo-rg \
//     --template-file 01-networking.bicep
//
// Verify:
//   az network vnet list -g flowdemo-rg -o table
//   az network nsg list  -g flowdemo-rg -o table
//   az network vnet subnet list -g flowdemo-rg --vnet-name flowdemo-vnet -o table
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────
@description('Short prefix used in every resource name.')
param prefix string = 'flowdemo'

@description('Azure region for all resources. Must support Availability Zones.')
param location string = 'eastus'

@description('''
Source CIDR allowed to RDP into the Web VMs.
Restrict to your own IP for security, e.g. "203.0.113.42/32".
Find your IP:  curl ifconfig.me
Default 0.0.0.0/0 is open to the world — fine for a short demo, not production.
''')
param rdpAllowedCidr string = '0.0.0.0/0'

// ── Web NSG ───────────────────────────────────────────────────
// Sits on web-subnet (10.0.1.0/24).
// Allows HTTP only from Azure Front Door service tags so the
// Front Door → Web VM hop is visible in NTANetAnalytics.
resource webNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-web-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTP-From-FrontDoor-Backend'
        properties: {
          description: 'AFD backend egress IPs — appear as source hop in NTANetAnalytics'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'AzureFrontDoor.Backend'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-HTTP-From-FrontDoor-HealthProbe'
        properties: {
          description: 'AFD health probe IPs — HEAD /health every 30s'
          priority: 105
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'AzureFrontDoor.FirstParty'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-RDP'
        properties: {
          description: 'RDP for Web VM management — restrict rdpAllowedCidr to your IP'
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: rdpAllowedCidr
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-All-Other-Inbound'
        properties: {
          description: 'Block everything not explicitly allowed above'
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-All-Outbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ── App NSG ───────────────────────────────────────────────────
// Sits on app-subnet (10.0.2.0/24).
// Accepts :8080 only from the web subnet and internally within
// the app subnet (App LB VM → App VMs).
resource appNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-app-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTP-From-WebSubnet'
        properties: {
          description: 'Web VMs calling nginx App LB on port 80'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '10.0.1.0/24'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-8080-From-LbSubnet'
        properties: {
          description: 'App LB VM (lb-subnet) distributing to App VMs on port 8080'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '8080'
          sourceAddressPrefix: '10.0.4.0/24'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-SSH-From-WebSubnet'
        properties: {
          description: 'SSH jump from Web VMs for operational access'
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '10.0.1.0/24'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-All-Other-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-All-Outbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ── LB NSG ────────────────────────────────────────────────────
// Applied to the App Load Balancer VM's NIC.
// Kept separate from appNsg so flow log records distinguish
// LB traffic from App VM traffic in NTANetAnalytics.
resource lbNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-lb-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTP-From-WebSubnet'
        properties: {
          description: 'Inbound from Web VMs to the nginx LB on port 80'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '10.0.1.0/24'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-All-Other-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-All-Outbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ── DB NSG ────────────────────────────────────────────────────
// Sits on db-subnet (10.0.3.0/24).
// Only the app subnet and the db subnet itself (replication)
// can reach Postgres port 5432. Everything else is denied.
resource dbNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-db-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Postgres-From-AppSubnet'
        properties: {
          description: 'App VMs connecting to Postgres primary on 5432'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5432'
          sourceAddressPrefix: '10.0.2.0/24'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-Postgres-Replication-Internal'
        properties: {
          description: 'Primary → Secondary WAL streaming within db-subnet'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5432'
          sourceAddressPrefix: '10.0.3.0/24'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-All-Other-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-All-Outbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ── Virtual Network ───────────────────────────────────────────
// NSGs are referenced inline on each subnet. Bicep resolves
// the dependency order automatically (NSGs created before VNet).
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: {
    project: 'vnet-flow-logs-demo'
  }
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'web-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: webNsg.id }
        }
      }
      {
        name: 'lb-subnet'
        properties: {
          addressPrefix: '10.0.4.0/24'
          networkSecurityGroup: { id: lbNsg.id }
        }
      }
      {
        name: 'app-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
          networkSecurityGroup: { id: appNsg.id }
        }
      }
      {
        name: 'db-subnet'
        properties: {
          addressPrefix: '10.0.3.0/24'
          networkSecurityGroup: { id: dbNsg.id }
        }
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────
// Referenced by every subsequent step.
output vnetId       string = vnet.id
output vnetName     string = vnet.name
output webSubnetId  string = vnet.properties.subnets[0].id
output lbSubnetId   string = vnet.properties.subnets[1].id
output appSubnetId  string = vnet.properties.subnets[2].id
output dbSubnetId   string = vnet.properties.subnets[3].id
output webNsgId     string = webNsg.id
output appNsgId     string = appNsg.id
output lbNsgId      string = lbNsg.id
output dbNsgId      string = dbNsg.id

// Static private IPs — used by later steps without re-typing.
output appLbPrivateIp  string = '10.0.4.4'
output appVmPrivateIps array  = ['10.0.2.10', '10.0.2.11', '10.0.2.12', '10.0.2.13']
output dbPrimaryIp     string = '10.0.3.4'
output dbSecondaryIp   string = '10.0.3.5'
