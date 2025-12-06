// VPN Gateway Module
param vpnGatewayName string
param location string
param vhubId string
param tags object = {}

resource vhub 'Microsoft.Network/virtualHubs@2023-11-01' existing = {
  name: split(vhubId, '/')[8]
}

resource vpnGateway 'Microsoft.Network/vpnGateways@2023-11-01' = {
  name: vpnGatewayName
  location: location
  properties: {
    virtualHub: {
      id: vhubId
    }
    bgpSettings: {
      // Keep default ip configurations; do not set custom BGP peering addresses for Virtual WAN gateways
      asn: 65515
    }
    vpnGatewayScaleUnit: 1
  }
  tags: tags
}

output vpnGatewayId string = vpnGateway.id
output vpnGatewayName string = vpnGateway.name
