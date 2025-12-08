# 01 - Core Network

## Configuration

- Configure region and region abbreviation in the bicep file
- Configure the Region, Region Abbreviation, VM administrator password and pre-shared key in the parameters file.

## Notes

- When you deploy the template, you need to make a note of the Deployment Name - you will need this in subsequent steps.
- The Bicep extension in VSCode will say that several of the dependsOn entries are unnecessary.  This is incorrect.

## Steps

1. Configure the parameters file to specify the region and security parameters.
2.  Deploy `01-core-network.bicep using the parameters file.  Make a note of the Deployment Name - if you deploy it via VSCode's deployment pane, it'll be named similar to "bicep-deploy-1765036016188".  At times, portions of the deployment may fail due to either contention or race conditions - re-running the deployment should succeed.
3.  In the portal, navigate to the Virtual Machine within the rg-nestedenvs resource group.  Request JIT access and connect via RDP to the VM over the Public IP address.
4.  **[Hyper-V Host]** Launch Disk Management and extend the C: volume to consume the remainder of the provisioned disk.
5.  **[Hyper-V Host]** Run PowerShell / Terminal as Administrator.  Run the following command to create the Virtual Network and NAT for the nested environment.  This will create a virtual network and configure the gateway was 172.30.100.1 and allow NAT across that interface.
```PowerShell
$switchName = "InternalNAT" 
New-VMSwitch -Name $switchName -SwitchType Internal 
New-NetNat -Name $switchName -InternalIPInterfaceAddressPrefix "172.30.100.0/24" 
$ifIndex = (Get-NetAdapter | ? {$_.name -like "*$switchName)"}).ifIndex 
New-NetIPAddress -IPAddress 172.30.100.1 -InterfaceIndex $ifIndex -PrefixLength 24
```
6.  **[Hyper-V Host]**  Download the most recent rolling release of VYOS [here](https://vyos.net/get/nightly-builds/).
7.  **[Hyper-V Host]** Launch Hyper-V Manager and create a Generation 1 Hyper-V VM with 4GB of RAM, Dynamic Memory, 10GB of  and attached to the InternalNAT network.  Configure the VYOS ISO as the install media and boot the VirtuaL Machine.
8.  **[Hyper-V VYOS Guest]** Login with vyos/vyos and run the following command to attach it to the network, configure the hostname, and set up a default DNS server.
```bash
conf
set system name-server 8.8.8.8
set interfaces ethernet eth0 address 172.30.100.254/24
set protocols static route 0.0.0.0/0 next-hop 172.30.100.1
set service ssh port 22
set system host-name vyos-router
commit
exit
```
9.  **[Hyper-V VYOS Guest]** At this point, ping www.bing.com to make sure that networking and DNS is functional from the nested Hyper-V network.  
10.  If that succeeds, from the machine you deployed from, run generate-vyos-config.ps1 to generate the VPN and BGP configuration for the VYOS VM replacing the Deployment Name and PSK with the values from above.

```PowerShell
.\generate-vyos-config.ps1 -DeploymentName DeploymentFromAbove -LocalNetworks @('172.30.100.0/24') -LocalASN 65001 -VyOsLocalAddress 172.30.100.254 -PSK "PSK_Listed_above"
```

11.  **[Hyper-V Host]** SSH into the guest VM using the terminal to make it easier to past in the configuration.  Open terminal and type `ssh vyos@172.30.100.254`.
12.  **[Hyper-V VYOS Guest]** Enter `conf` mode and paste in the output from the PowerShell script - the file name should being with vyos-config.  After pasting it in, type `commit` and then `exit`.
13.  **[Hyper-V VYOS Guest]** Validate that you have two VPN tunnels established and 2 BGP sessions.  Run `show vpn ipsec sa` - you should see two connections both with the state 'up'.  Run `show ip bgp summary` - you should see two neighbors with messages being transmitted across both of them.
14.  From the Azure Portal, navigate to Virtual WANs and select the deployed Virtual WAN.  From there, navigate to Hubs and select the deployed hub. Navigate to VPN (Site to site) and select the deployed site.  Under BGP Dashboard, you should see two connected BGP Peers.
15.  **[Hyper-V VYOS Guest]** At this point, we're ready to commit the VYOS image to disk.  Type `config` to enter the config mode and type `save`.  Run `install image` and follow the prompts.  Choose a more secure password than the default 'vyos'.  Once it indicates that the image installed successfully, eject the ISO and reboot the VM.

At this point, you should have a functioning site-to-site configuration between the nested Hyper-V environment and Azure.  Virtual machines that are deployed in Hyper-V should use 172.30.100.254 as the default gateway and will be able to access virtual machines running within Azure (and vice-versa).