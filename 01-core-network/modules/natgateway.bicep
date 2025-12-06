// NAT Gateway Module
param natGatewayName string
param location string
param publicIpId string
param tags object = {}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = {
  name: natGatewayName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: publicIpId
      }
    ]
  }
  tags: tags
}

output natGatewayId string = natGateway.id
