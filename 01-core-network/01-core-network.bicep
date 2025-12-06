targetScope = 'subscription'

// Parameters
param location string
param location_abbr string
param tags object
param hvVmAdminUsername string
@secure()
param hvVmAdminPassword string
@secure()
param hvVpnSharedKey string
param deploymentTimestamp string = utcNow('yyyy-MM-dd HH:mm:ss')

// Variables
var mergedTags = union(tags, { deployedAt: deploymentTimestamp })
var description = 'corenetwork'
var hvDescription = 'nestedenvs'
var hvDescription_abbr string = 'hyv'
var resourceGroupName = 'rg-${description}-${location_abbr}-001'
var hvResourceGroupName = 'rg-${hvDescription}-${location_abbr}-001'
var vnetName = 'vnet-${description}-${location_abbr}-001'
var vnetAddressSpace = '10.30.0.0/16'
var natGatewayName = 'natgw-${description}-${location_abbr}-001'
var publicIpName = 'pip-natgw-${description}-${location_abbr}-001'
var vwanName = 'vwan-${description}-${location_abbr}-001'
var vhubName = 'vhub-${description}-${location_abbr}-001'
var vhubAddressPrefix = '10.254.254.0/24'
var vhubConnectionName = 'vhubconn-${vnetName}'
var vpnGatewayName = 'vpngw-${description}-${location_abbr}-001'
var hvVnetName = 'vnet-${hvDescription}-${location_abbr}-001'
var hvVnetAddressSpace = '172.30.254.0/24'
var hvVmName = 'vm-${hvDescription_abbr}-${location_abbr}-001'
var hvVpnSiteName = 'vpnsite-${hvDescription_abbr}-${location_abbr}-001'
var hvVpnConnectionName = 'vpnconn-${hvDescription_abbr}-${location_abbr}-001'
var hvVpnAddressPrefixes = ['172.30.0.0/16']

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: mergedTags
}

// Resource Group for Nested Environments
resource hvRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: hvResourceGroupName
  location: location
  tags: mergedTags
}

// Public IP for NAT Gateway
module natGatewayPublicIp 'modules/publicip.bicep' = {
  scope: rg
  name: 'pip-deployment'
  params: {
    publicIpName: publicIpName
    location: location
    tags: mergedTags
  }
}

// NAT Gateway
module natGateway 'modules/natgateway.bicep' = {
  scope: rg
  name: 'natgw-deployment'
  params: {
    natGatewayName: natGatewayName
    location: location
    publicIpId: natGatewayPublicIp.outputs.publicIpId
    tags: mergedTags
  }
}

// Virtual Network Module
module vnet 'br/public:avm/res/network/virtual-network:0.1.0' = {
  scope: rg
  name: 'vnet-deployment'
  params: {
    name: vnetName
    location: location
    addressPrefixes: [
      vnetAddressSpace
    ]
    subnets: [
      {
        name: 'snet-domainservices-${location_abbr}-001'
        addressPrefix: '10.30.0.0/24'
        natGatewayResourceId: natGateway.outputs.natGatewayId
      }
      {
        name: 'snet-serverservices-${location_abbr}-001'
        addressPrefix: '10.30.100.0/24'
        natGatewayResourceId: natGateway.outputs.natGatewayId
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: '10.30.254.0/24'
      }
    ]
    tags: mergedTags
  }
}

// Hyper-V Isolated Virtual Network
module hvVnet 'br/public:avm/res/network/virtual-network:0.1.0' = {
  scope: hvRg
  name: 'hvvnet-deployment'
  params: {
    name: hvVnetName
    location: location
    addressPrefixes: [
      hvVnetAddressSpace
    ]
    subnets: [
      {
        name: 'snet-${hvDescription}-${location_abbr}-001'
        addressPrefix: '172.30.254.0/26'
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: '172.30.254.64/26'
      }
    ]
    tags: mergedTags
  }
}

// Hyper-V Virtual Machine
module hvVm 'modules/hypervvm.bicep' = {
  scope: hvRg
  name: 'hvvm-deployment'
  params: {
    vmName: hvVmName
    location: location
    subnetId: hvVnet.outputs.subnetResourceIds[0]
    adminUsername: hvVmAdminUsername
    adminPassword: hvVmAdminPassword
    tags: mergedTags
  }
  dependsOn: [
    hvVnet
  ]
}

// Virtual WAN
module vwan 'modules/virtualwan.bicep' = {
  scope: rg
  name: 'vwan-deployment'
  params: {
    vwanName: vwanName
    location: location
    tags: mergedTags
  }
}

// Virtual Hub
module vhub 'modules/virtualhub.bicep' = {
  scope: rg
  name: 'vhub-deployment'
  params: {
    vhubName: vhubName
    location: location
    vwanId: vwan.outputs.vwanId
    addressPrefix: vhubAddressPrefix
    tags: mergedTags
  }
}

// VPN Gateway
module vpnGateway 'modules/vpngateway.bicep' = {
  scope: rg
  name: 'vpngw-deployment'
  params: {
    vpnGatewayName: vpnGatewayName
    location: location
    vhubId: vhub.outputs.vhubId
    tags: mergedTags
  }
  dependsOn: [
    vhub
  ]
}

// Virtual Hub VNet Connection
module vhubConnection 'modules/vhubconnection.bicep' = {
  scope: rg
  name: 'vhubconn-deployment'
  params: {
    connectionName: vhubConnectionName
    vhubName: vhub.outputs.vhubName
    vhubId: vhub.outputs.vhubId
    vnetId: vnet.outputs.resourceId
    enableInternetSecurity: false
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
  }
  dependsOn: [
    vhub
  ]
}

// VPN Site for Nested Hyper-V Environment
module hvVpnSite 'modules/vpnsite.bicep' = {
  scope: rg
  name: 'hvvpnsite-deployment'
  params: {
    vpnSiteName: hvVpnSiteName
    location: location
    vwanId: vwan.outputs.vwanId
    publicIpAddress: hvVm.outputs.publicIpAddress
    addressPrefixes: hvVpnAddressPrefixes
    bgpAsn: 65001
    tags: mergedTags
  }
  dependsOn: [
    hvVm
    vwan
  ]
}

// VPN Connection for Nested Hyper-V Environment
module hvVpnConnection 'modules/vpnsiteconnection.bicep' = {
  scope: rg
  name: 'hvvpnconn-deployment'
  params: {
    connectionName: hvVpnConnectionName
    vpnGatewayName: vpnGateway.outputs.vpnGatewayName
    vpnSiteId: hvVpnSite.outputs.vpnSiteId
    vpnSiteName: hvVpnSite.outputs.vpnSiteName
    vhubId: vhub.outputs.vhubId
    sharedKey: hvVpnSharedKey
    enableBgp: true
  }
  dependsOn: [
    vpnGateway
    hvVpnSite
  ]
}

// Outputs
output resourceGroupName string = rg.name
output hvResourceGroupName string = hvRg.name
output vnetName string = vnetName
output vnetId string = vnet.outputs.resourceId
output subnetIds array = vnet.outputs.subnetResourceIds
output natGatewayId string = natGateway.outputs.natGatewayId
output natGatewayPublicIpAddress string = natGatewayPublicIp.outputs.publicIpAddress
output vwanId string = vwan.outputs.vwanId
output vhubId string = vhub.outputs.vhubId
output vhubConnectionId string = vhubConnection.outputs.connectionId
output vpnGatewayId string = vpnGateway.outputs.vpnGatewayId
output hvVnetName string = hvVnetName
output hvVnetId string = hvVnet.outputs.resourceId
output hvSubnetIds array = hvVnet.outputs.subnetResourceIds
output hvVmName string = hvVm.outputs.vmName
output hvVmId string = hvVm.outputs.vmId
output hvVmPublicIp string = hvVm.outputs.publicIpAddress
output hvVmPrivateIp string = hvVm.outputs.privateIpAddress
output hvVpnSiteId string = hvVpnSite.outputs.vpnSiteId
output hvVpnConnectionId string = hvVpnConnection.outputs.connectionId
