// ============================================================
// STEP 3 of 5 — Web Tier VMs
// ============================================================
// Deploys:
//   - 2x Public IPs (Standard, Static)
//   - 2x NICs attached to web-subnet
//   - 2x Windows Server 2022 VMs (Zone 1 and Zone 2)
//   - Custom Script Extension on each VM:
//       installs IIS, creates Hello World site that calls
//       the App LB on port 8080 and returns the response
//
// PRE-REQUISITES: Steps 1 and 2 must be deployed first.
//
// Build to ARM JSON:
//   az bicep build --file bicep_files/03-web-vms.bicep --outfile arm_files/03-web-vms.json
//
// Deploy:
//   az deployment group create \
//     --name flowdemo-step3-web-vms \
//     --resource-group rg-jxd-ddd \
//     --template-file 03-web-vms.bicep
//
// Verify:
//   az vm list -g rg-jxd-ddd -o table
//   az network public-ip list -g rg-jxd-ddd -o table
//
// RDP access after deployment:
//   mstsc /v:<web1PublicIp>
//   mstsc /v:<web2PublicIp>
//   Username: azureadmin
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────
@description('Short prefix used in every resource name.')
param prefix string = 'flowdemo'

@description('Azure region — must match Step 1.')
param location string = 'eastus'

@description('Admin username for both VMs.')
param adminUsername string = 'azureadmin'

@description('Admin password for both VMs. Min 12 chars, must have upper, lower, digit and special character.')
@secure()
param adminPassword string

@description('Private IP of the App Load Balancer VM — set in Step 4.')
param appLbIp string = '10.0.4.4'

// ── Reference to web-subnet from Step 1 ──────────────────────
resource webSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  name: '${prefix}-vnet/web-subnet'
  scope: resourceGroup('rg-jxd-ddd')
}

// ── Public IP — Web VM 1 ──────────────────────────────────────
resource pip1 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${prefix}-web1-pip'
  location: location
  sku: { name: 'Standard' }
  zones: ['1']
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${prefix}-web1'
    }
  }
}

// ── Public IP — Web VM 2 ──────────────────────────────────────
resource pip2 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${prefix}-web2-pip'
  location: location
  sku: { name: 'Standard' }
  zones: ['2']
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${prefix}-web2'
    }
  }
}

// ── NIC — Web VM 1 ────────────────────────────────────────────
resource nic1 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${prefix}-web1-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: webSubnet.id }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip1.id }
        }
      }
    ]
  }
}

// ── NIC — Web VM 2 ────────────────────────────────────────────
resource nic2 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${prefix}-web2-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: webSubnet.id }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip2.id }
        }
      }
    ]
  }
}

// ── Web VM 1 (Zone 1) ─────────────────────────────────────────
resource webVm1 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${prefix}-web1'
  location: location
  zones: ['1']
  properties: {
    hardwareProfile: { vmSize: 'Standard_D2s_v6' }
    osProfile: {
      computerName: '${prefix}web1'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic1.id }]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}

// ── Web VM 2 (Zone 2) ─────────────────────────────────────────
resource webVm2 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${prefix}-web2'
  location: location
  zones: ['2']
  properties: {
    hardwareProfile: { vmSize: 'Standard_D2s_v6' }
    osProfile: {
      computerName: '${prefix}web2'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic2.id }]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}

// ── Custom Script Extension — Web VM 1 ───────────────────────
// Installs IIS and deploys the Hello World site.
// The site calls the App LB at appLbIp:8080 on each request.
resource webVm1Script 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: webVm1
  name: 'CustomScriptExtension'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: '''
        powershell -ExecutionPolicy Unrestricted -Command "
          Install-WindowsFeature -Name Web-Server,Web-Asp-Net45,NET-Framework-45-ASPNET,Web-Net-Ext45,Web-Mgmt-Tools -IncludeManagementTools;
          & 'C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\aspnet_regiis.exe' -iru;
          Import-Module WebAdministration;
          Get-Website | Remove-Website -ErrorAction SilentlyContinue;
          $sitePath = 'C:\\inetpub\\wwwroot';
          $appLbIp = '${appLbIp}';
          $aspx = @'
<%@ Page Language=C# %><%@ Import Namespace=System.Net %><%@ Import Namespace=System.IO %>
<script runat=server>void Page_Load(object s,EventArgs e){
  var host=System.Net.Dns.GetHostName();
  var t=DateTime.UtcNow.ToString(\"yyyy-MM-dd HH:mm:ss UTC\");
  string app=\"(not yet available)\";
  try{var r=(System.Net.HttpWebRequest)System.Net.WebRequest.Create(\"http://__APPLBIP__/\");
  r.Timeout=5000;using(var rs=r.GetResponse())using(var sr=new StreamReader(rs.GetResponseStream())){app=sr.ReadToEnd();}}
  catch(Exception ex){app=\"Error: \"+ex.Message;}
  Response.Write(\"<!DOCTYPE html><html><head><title>FlowDemo Web1</title></head><body>\");
  Response.Write(\"<h1>Hello from flowdemo-web1</h1>\");
  Response.Write(\"<p>VM: \"+host+\" | Time: \"+t+\"</p>\");
  Response.Write(\"<h2>App Server Response</h2><pre>\"+Server.HtmlEncode(app)+\"</pre>\");
  Response.Write(\"</body></html>\");}</script>
'@;
          $aspx = $aspx.Replace('__APPLBIP__', $appLbIp);
          $aspx | Out-File \"$sitePath\\default.aspx\" -Encoding UTF8;
          '<%@ Page Language=C# %><% Response.Write(\"OK\"); %>' | Out-File \"$sitePath\\health.aspx\" -Encoding UTF8;
          New-Website -Name FlowDemo -PhysicalPath $sitePath -Port 80 -IPAddress '*' -Force;
          Set-WebConfigurationProperty -Filter system.webServer/security/authentication/anonymousAuthentication -PSPath 'IIS:\\Sites\\FlowDemo' -Name enabled -Value True;
          $existing = Get-WebConfiguration system.webServer/defaultDocument/files -PSPath 'IIS:\\Sites\\FlowDemo' | Select-Object -ExpandProperty Collection | Where-Object { $_.value -eq 'default.aspx' };
          if (-not $existing) { Add-WebConfiguration system.webServer/defaultDocument/files -PSPath 'IIS:\\Sites\\FlowDemo' -Value @{value='default.aspx'}; };
          icacls $sitePath /grant 'IIS_IUSRS:(OI)(CI)R' /T;
          New-NetFirewallRule -DisplayName 'Allow HTTP 80' -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -ErrorAction SilentlyContinue;
          Start-Website -Name FlowDemo;
          iisreset /restart;
        "
      '''
    }
  }
}

// ── Custom Script Extension — Web VM 2 ───────────────────────
resource webVm2Script 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: webVm2
  name: 'CustomScriptExtension'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: '''
        powershell -ExecutionPolicy Unrestricted -Command "
          Install-WindowsFeature -Name Web-Server,Web-Asp-Net45,NET-Framework-45-ASPNET,Web-Net-Ext45,Web-Mgmt-Tools -IncludeManagementTools;
          & 'C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\aspnet_regiis.exe' -iru;
          Import-Module WebAdministration;
          Get-Website | Remove-Website -ErrorAction SilentlyContinue;
          $sitePath = 'C:\\inetpub\\wwwroot';
          $appLbIp = '${appLbIp}';
          $aspx = @'
<%@ Page Language=C# %><%@ Import Namespace=System.Net %><%@ Import Namespace=System.IO %>
<script runat=server>void Page_Load(object s,EventArgs e){
  var host=System.Net.Dns.GetHostName();
  var t=DateTime.UtcNow.ToString(\"yyyy-MM-dd HH:mm:ss UTC\");
  string app=\"(not yet available)\";
  try{var r=(System.Net.HttpWebRequest)System.Net.WebRequest.Create(\"http://__APPLBIP__/\");
  r.Timeout=5000;using(var rs=r.GetResponse())using(var sr=new StreamReader(rs.GetResponseStream())){app=sr.ReadToEnd();}}
  catch(Exception ex){app=\"Error: \"+ex.Message;}
  Response.Write(\"<!DOCTYPE html><html><head><title>FlowDemo Web2</title></head><body>\");
  Response.Write(\"<h1>Hello from flowdemo-web2</h1>\");
  Response.Write(\"<p>VM: \"+host+\" | Time: \"+t+\"</p>\");
  Response.Write(\"<h2>App Server Response</h2><pre>\"+Server.HtmlEncode(app)+\"</pre>\");
  Response.Write(\"</body></html>\");}</script>
'@;
          $aspx = $aspx.Replace('__APPLBIP__', $appLbIp);
          $aspx | Out-File \"$sitePath\\default.aspx\" -Encoding UTF8;
          '<%@ Page Language=C# %><% Response.Write(\"OK\"); %>' | Out-File \"$sitePath\\health.aspx\" -Encoding UTF8;
          New-Website -Name FlowDemo -PhysicalPath $sitePath -Port 80 -IPAddress '*' -Force;
          Set-WebConfigurationProperty -Filter system.webServer/security/authentication/anonymousAuthentication -PSPath 'IIS:\\Sites\\FlowDemo' -Name enabled -Value True;
          $existing = Get-WebConfiguration system.webServer/defaultDocument/files -PSPath 'IIS:\\Sites\\FlowDemo' | Select-Object -ExpandProperty Collection | Where-Object { $_.value -eq 'default.aspx' };
          if (-not $existing) { Add-WebConfiguration system.webServer/defaultDocument/files -PSPath 'IIS:\\Sites\\FlowDemo' -Value @{value='default.aspx'}; };
          icacls $sitePath /grant 'IIS_IUSRS:(OI)(CI)R' /T;
          New-NetFirewallRule -DisplayName 'Allow HTTP 80' -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -ErrorAction SilentlyContinue;
          Start-Website -Name FlowDemo;
          iisreset /restart;
        "
      '''
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────
output web1PublicIp   string = pip1.properties.ipAddress
output web2PublicIp   string = pip2.properties.ipAddress
output web1Fqdn       string = pip1.properties.dnsSettings.fqdn
output web2Fqdn       string = pip2.properties.dnsSettings.fqdn
output web1PrivateIp  string = nic1.properties.ipConfigurations[0].properties.privateIPAddress
output web2PrivateIp  string = nic2.properties.ipConfigurations[0].properties.privateIPAddress
output web1PublicIpId string = pip1.id
output web2PublicIpId string = pip2.id
