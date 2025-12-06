#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generates VyOS configuration for Azure Virtual WAN Site-to-Site VPN from deployment outputs.

.DESCRIPTION
    This script retrieves Azure deployment information and generates a complete VyOS router
    configuration file for establishing IPsec VPN tunnels with BGP peering to Azure Virtual WAN.
    
    The generated configuration includes:
    - Dual IPsec tunnels (active-active) to Azure VPN Gateway
    - BGP peering over both tunnels
    - Static routes to Azure BGP peers
    - Local network advertisements via BGP
    
.PARAMETER DeploymentName
    The name of the Azure subscription-level deployment to query for VPN Gateway information.
    Use 'az deployment sub list' to find your deployment name.
    
.PARAMETER VyOsLocalAddress
    The local IP address of the VyOS router's external interface (typically eth0).
    This is the address that will establish the VPN tunnels to Azure.
    
.PARAMETER LocalASN
    The BGP Autonomous System Number for your local VyOS router.
    Must match the ASN configured in the Azure VPN Site.
    Default: 65001
    
.PARAMETER LocalNetworks
    Array of CIDR network ranges to advertise to Azure via BGP.
    These are your on-premises or nested virtual networks.
    
.PARAMETER PSK
    The pre-shared key (PSK) for IPsec authentication.
    Must match the shared key configured in Azure VPN Connection.

.EXAMPLE
    .\generate-vyos-config.ps1 `
        -DeploymentName "bicep-deploy-1764769806079" `
        -VyOsLocalAddress "172.31.100.254" `
        -LocalASN "65001" `
        -LocalNetworks @("172.30.0.0/16", "172.31.0.0/16") `
        -PSK "YourSecurePreSharedKey123!"
    
    Generates VyOS configuration for the specified deployment with two local networks.

.EXAMPLE
    .\generate-vyos-config.ps1 `
        -DeploymentName "my-azure-deployment" `
        -VyOsLocalAddress "10.0.0.1" `
        -LocalNetworks @("10.0.0.0/8") `
        -PSK $env:VPN_PSK
    
    Uses environment variable for PSK and advertises a single large network range.

.NOTES
    File Name      : generate-vyos-config.ps1
    Prerequisite   : Azure CLI must be installed and authenticated
    
.LINK
    https://docs.vyos.io/en/latest/configuration/vpn/site2site_ipsec.html
    
.LINK
    https://learn.microsoft.com/azure/virtual-wan/virtual-wan-site-to-site-portal
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$DeploymentName,
    
    [Parameter(Mandatory=$true)]
    [string]$VyOsLocalAddress,
    
    [Parameter(Mandatory=$false)]
    [string]$LocalASN = "65001",
    
    [Parameter(Mandatory=$true)]
    [string[]]$LocalNetworks,
    
    [Parameter(Mandatory=$true)]
    [string]$PSK
)

function Get-IncrementedIpAddress {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Ip,
        [Parameter(Mandatory=$true)]
        [int]$Increment
    )

    $bytes = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
    [Array]::Reverse($bytes)
    $value = [BitConverter]::ToUInt32($bytes, 0) + [uint32]$Increment
    $newBytes = [BitConverter]::GetBytes($value)
    [Array]::Reverse($newBytes)
    return ([System.Net.IPAddress]::new($newBytes)).ToString()
}

# Get deployment outputs
Write-Host "Fetching deployment outputs..." -ForegroundColor Cyan
$deployment = az deployment sub show --name $DeploymentName | ConvertFrom-Json

if (-not $deployment) {
    Write-Error "Deployment '$DeploymentName' not found"
    exit 1
}

# Extract required information
$vpnGatewayId = $deployment.properties.outputs.vpnGatewayId.value
$vhubId = $deployment.properties.outputs.vhubId.value

Write-Host "Getting VPN Gateway details..." -ForegroundColor Cyan

# Fetch the VPN Gateway directly by resource ID to avoid name/RG parsing issues
$vpnGateway = az resource show --ids $vpnGatewayId --api-version 2023-11-01 | ConvertFrom-Json

if (-not $vpnGateway.properties.bgpSettings.bgpPeeringAddresses) {
    Write-Error "No BGP peering addresses returned for gateway '$vpnGatewayId'. Check the deployment."
    exit 1
}

# Get the VPN connection to find BGP settings
$hvVpnConnectionId = $deployment.properties.outputs.hvVpnConnectionId.value
$connectionName = ($hvVpnConnectionId -split '/')[-1]

$connectionId = "${hvVpnConnectionId}"
$connection = az resource show --ids $connectionId | ConvertFrom-Json

# Get VPN Site information
$hvVpnSiteId = $deployment.properties.outputs.hvVpnSiteId.value
$vpnSiteName = ($hvVpnSiteId -split '/')[-1]
$vpnSite = az resource show --ids $hvVpnSiteId | ConvertFrom-Json

# Get BGP peering addresses from gateway instances
$instance0 = $vpnGateway.properties.bgpSettings.bgpPeeringAddresses[0]
$instance1 = $vpnGateway.properties.bgpSettings.bgpPeeringAddresses[1]

$publicIp0 = $instance0.tunnelIpAddresses[0]
$publicIp1 = $instance1.tunnelIpAddresses[0]

$azureBgp0 = $instance0.defaultBgpIpAddresses[0]
$azureBgp1 = $instance1.defaultBgpIpAddresses[0]

# Get VyOS BGP peering address from VPN site link
$vyosBgpPeer = $vpnSite.properties.vpnSiteLinks[0].properties.bgpProperties.bgpPeeringAddress
$vyosVti10Address = $vyosBgpPeer
$vyosVti11Address = Get-IncrementedIpAddress -Ip $vyosBgpPeer -Increment 4

$azureASN = $vpnGateway.properties.bgpSettings.asn

# Generate VyOS configuration
Write-Host "`nGenerating VyOS configuration..." -ForegroundColor Cyan

$vyosConfig = @"
# VyOS Configuration for Azure Virtual WAN S2S VPN
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Deployment: $DeploymentName
# Local ASN: $LocalASN
# Azure ASN: $azureASN
#
# Configuration: Dual IPsec tunnels (active-active) with BGP on both tunnels
# - Each VWAN gateway instance has its own tunnel and BGP session
# - BGP sourced from per-tunnel VTI interfaces

# ESP Group Configuration
set vpn ipsec esp-group AZURE-VWAN lifetime '3600'
set vpn ipsec esp-group AZURE-VWAN mode 'tunnel'
set vpn ipsec esp-group AZURE-VWAN pfs 'dh-group2'
set vpn ipsec esp-group AZURE-VWAN proposal 1 encryption 'aes256'
set vpn ipsec esp-group AZURE-VWAN proposal 1 hash 'sha1'

# IKE Group Configuration
set vpn ipsec ike-group AZURE-VWAN dead-peer-detection action 'restart'
set vpn ipsec ike-group AZURE-VWAN dead-peer-detection interval '15'
set vpn ipsec ike-group AZURE-VWAN dead-peer-detection timeout '30'
set vpn ipsec ike-group AZURE-VWAN ikev2-reauth
set vpn ipsec ike-group AZURE-VWAN key-exchange 'ikev2'
set vpn ipsec ike-group AZURE-VWAN lifetime '28800'
set vpn ipsec ike-group AZURE-VWAN proposal 1 dh-group '2'
set vpn ipsec ike-group AZURE-VWAN proposal 1 encryption 'aes256'
set vpn ipsec ike-group AZURE-VWAN proposal 1 hash 'sha1'

# IPsec Interface
set vpn ipsec interface 'eth0'

# Pre-Shared Keys
set vpn ipsec authentication psk azure-vwan id '$publicIp0'
set vpn ipsec authentication psk azure-vwan id '$publicIp1'
set vpn ipsec authentication psk azure-vwan secret '$PSK'

# VTI Interface (Primary tunnel with BGP)
set interfaces vti vti10 address '$vyosVti10Address/30'
set interfaces vti vti10 description 'Azure VWAN Primary Tunnel (BGP)'
set interfaces vti vti10 ip adjust-mss '1350'

set interfaces vti vti11 address '$vyosVti11Address/30'
set interfaces vti vti11 description 'Azure VWAN Secondary Tunnel (BGP)'
set interfaces vti vti11 ip adjust-mss '1350'

# Site-to-Site Peer 0 (Primary tunnel to Instance0)
set vpn ipsec site-to-site peer AZURE-VWAN-0 authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer AZURE-VWAN-0 authentication remote-id '$publicIp0'
set vpn ipsec site-to-site peer AZURE-VWAN-0 connection-type 'initiate'
set vpn ipsec site-to-site peer AZURE-VWAN-0 description 'AZURE VWAN PRIMARY TUNNEL'
set vpn ipsec site-to-site peer AZURE-VWAN-0 ike-group 'AZURE-VWAN'
set vpn ipsec site-to-site peer AZURE-VWAN-0 ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer AZURE-VWAN-0 local-address '$VyOsLocalAddress'
set vpn ipsec site-to-site peer AZURE-VWAN-0 remote-address '$publicIp0'
set vpn ipsec site-to-site peer AZURE-VWAN-0 vti bind 'vti10'
set vpn ipsec site-to-site peer AZURE-VWAN-0 vti esp-group 'AZURE-VWAN'

# Site-to-Site Peer 1 (Secondary tunnel to Instance1)
set vpn ipsec site-to-site peer AZURE-VWAN-1 authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer AZURE-VWAN-1 authentication remote-id '$publicIp1'
set vpn ipsec site-to-site peer AZURE-VWAN-1 connection-type 'initiate'
set vpn ipsec site-to-site peer AZURE-VWAN-1 description 'AZURE VWAN SECONDARY TUNNEL'
set vpn ipsec site-to-site peer AZURE-VWAN-1 ike-group 'AZURE-VWAN'
set vpn ipsec site-to-site peer AZURE-VWAN-1 ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer AZURE-VWAN-1 local-address '$VyOsLocalAddress'
set vpn ipsec site-to-site peer AZURE-VWAN-1 remote-address '$publicIp1'
set vpn ipsec site-to-site peer AZURE-VWAN-1 vti bind 'vti11'
set vpn ipsec site-to-site peer AZURE-VWAN-1 vti esp-group 'AZURE-VWAN'

# Static Routes to BGP Peers
set protocols static route $azureBgp0/32 interface 'vti10'
set protocols static route $azureBgp1/32 interface 'vti11'

# BGP Configuration
set protocols bgp system-as '$LocalASN'

# BGP Neighbors (one per tunnel)
set protocols bgp neighbor $azureBgp0 remote-as '$azureASN'
set protocols bgp neighbor $azureBgp0 address-family ipv4-unicast soft-reconfiguration 'inbound'
set protocols bgp neighbor $azureBgp0 timers holdtime '30'
set protocols bgp neighbor $azureBgp0 timers keepalive '10'
set protocols bgp neighbor $azureBgp0 ebgp-multihop '2'
set protocols bgp neighbor $azureBgp0 update-source 'vti10'

set protocols bgp neighbor $azureBgp1 remote-as '$azureASN'
set protocols bgp neighbor $azureBgp1 address-family ipv4-unicast soft-reconfiguration 'inbound'
set protocols bgp neighbor $azureBgp1 timers holdtime '30'
set protocols bgp neighbor $azureBgp1 timers keepalive '10'
set protocols bgp neighbor $azureBgp1 ebgp-multihop '2'
set protocols bgp neighbor $azureBgp1 update-source 'vti11'

# Advertise Local Networks
"@

foreach ($network in $LocalNetworks) {
    $vyosConfig += "`nset protocols bgp address-family ipv4-unicast network '$network'"
}

# Save to file
$outputFile = "vyos-config-$(Get-Date -Format 'yyyyMMdd-HHmmss').sh"
$vyosConfig | Out-File -FilePath $outputFile -Encoding utf8

Write-Host "`nConfiguration saved to: $outputFile" -ForegroundColor Green
Write-Host "`nConfiguration Summary:" -ForegroundColor Yellow
Write-Host "  Azure VPN Gateway Instance0 Public IP: $publicIp0" -ForegroundColor White
Write-Host "  Azure VPN Gateway Instance1 Public IP: $publicIp1" -ForegroundColor White
Write-Host "  Azure BGP Peer (Instance0): $azureBgp0" -ForegroundColor White
Write-Host "  Azure BGP Peer (Instance1): $azureBgp1" -ForegroundColor White
Write-Host "  VyOS BGP Peer (vti10): $vyosVti10Address" -ForegroundColor White
Write-Host "  VyOS BGP Peer (vti11): $vyosVti11Address" -ForegroundColor White
Write-Host "  Azure ASN: $azureASN" -ForegroundColor White
Write-Host "  Local ASN: $LocalASN" -ForegroundColor White
Write-Host "  Local VyOS Address: $VyOsLocalAddress" -ForegroundColor White
Write-Host "  Local Networks: $($LocalNetworks -join ', ')" -ForegroundColor White
Write-Host "  Architecture: Dual IPsec tunnels with BGP (active-active)" -ForegroundColor White

Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "  1. Copy $outputFile to your VyOS router"
Write-Host "  2. Enter configuration mode: configure"
Write-Host "  3. Load the configuration: source /path/to/$outputFile"
Write-Host "  4. Commit the changes: commit"
Write-Host "  5. Save the configuration: save"
Write-Host "  6. Verify tunnels: show vpn ipsec sa"
Write-Host "  7. Verify BGP: show ip bgp summary"
