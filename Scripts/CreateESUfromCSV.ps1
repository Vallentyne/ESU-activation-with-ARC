<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Creates ESU licenses to be used with Azure ARC in bulk, using a exported CSV from the Azure Portal.

.DESCRIPTION
This script will create ARC based ESU licenses that can later be assigned to your servers requiring ESU acvitation.
Creation will fetch parameters information from a CSV file coming from an Azure Portal export of the ARC ESU Eligible resources.
License assignment should be done with another script and so will be removal/unlinking of the license when/if required.

.NOTES
File Name : CreateESUfromCSV.ps1
Author    : David De Backer
Version   : 0.5
Date      : 23-October-2023
Update    : 23-October-2023
Tested on : PowerShell Version 7.3.8
Module    : Azure Powershell version 9.6.0
Requires  : Powershell Core version 7.x or later
Product   : Azure ARC

.LINK
To get more information on Azure ARC ESU license REST API please visit:
https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates

.EXAMPLE-1
./CreateESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "Zil8Q~i5xFbrg.N5ew_UvD1JRZcGgu66VA-DtaEL" `
-licenseResourceGroupName "rg-arclicenses" `
-licenseName "Standard8vcores" `
-location "EastUS" `
-state "Deactivated" `
-edition "Standard" `
-type "vCore" `
-cores 8 

This example will create a license object that is Deactivated with a virtual cores count of 8 and of type Standard

To modify an existing license object, use the same script while providing different values.
Note that you can only change the NUMBER of cores associated to a license as well as the ACTIVATION state.
You CAN NEITHER modify the EDITION nor can you modify the TYPE of the cores configured for the license.

#>

##############################
#Parameters definition block #
##############################

param(
    [Parameter(Mandatory=$true, HelpMessage="The ID of the subscription where the license will be created.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid subscription ID.")]
    [Alias("sub")]
    [string]$subscriptionId,

    [Parameter(Mandatory=$true, HelpMessage="The tenant ID of the Microsoft Entra instance used for authentication.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid tenant ID.")]
    [string]$tenantId,

    [Parameter(Mandatory=$true, HelpMessage="The application (client) ID as shown under App Registrations that will be used to authenticate to the Azure API.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="The input '{0}' has to be a valid application ID.")]
    [string]$appID,

    [Parameter(Mandatory=$true, HelpMessage="A valid (non expired) client secret for App Registration that will be used to authenticate to the Azure API.")]
    [Alias("s","secret","sec")]
    [string]$clientSecret,

    [Parameter(Mandatory=$true, HelpMessage="The name of the resource group where the license will be created.")]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("lrg")]
    [string]$licenseResourceGroupName,

    [Parameter(Mandatory=$true, HelpMessage="The name of the ESU license to be created.")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^(?!.*\.$)[a-zA-Z0-9_()\-.]{1,90}$', ErrorMessage="The resource group name '{0}' did not pass validation (1-90 alphanumeric characters)")]
    [Alias("lpn")]
    [string]$licenseprefixName,

    [Parameter(Mandatory=$true, HelpMessage="The region where the license will be created.")]
    [ValidateNotNullOrEmpty()]
    [Alias("l")]
    [string]$location,

    [Parameter(Mandatory=$true, HelpMessage="The activated state of the license. Valid values are Activated or Deactivated.")]
    [ValidateSet("Activated", "Deactivated",ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [string]$state,

    [Parameter(Mandatory=$false, HelpMessage="The target OS edition for the license. Valid values are Standard or Datacenter.")]
    [ValidateSet("Standard", "Datacenter",ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [Alias( "e", "ed")]
    [string]$edition,

    [Parameter (Mandatory=$false, HelpMessage="The type of license. Valid values are pCore for physical cores or vCore for virtual cores.")]
    [ValidateSet ("pCore", "vCore",ErrorMessage="Value '{0}' is invalid. Try one of: '{1}'")]
    [Alias("ct","type")]
    [string] $coreType,

    [Parameter (Mandatory=$false, HelpMessage="The number of cores to be licensed. Valid values are 16-256 for pCore and 8-128 for vCore.")]
    # The MAX values can be changed in the param validation block below if you need to license more cores (unlikely)
    # Those values have been set as a precaution to avoid accidental licensing of too many cores
    # The minimum value shoud stay as is.
    # Changing the minimum number of cores ($min value herebelow) would have be in violation of with the Microsoft Licensing Terms

    [ValidateScript ({
        switch ($coreType) {
            "pCore" { $min = 16; $max = 256 }
            "vCore" { $min = 8; $max = 128 }
        }
        $_ -ge $min -and $_ -le $max -and $_ % 2 -eq 0
    }, ErrorMessage = "The item '{0}' did not pass validation of statements '{1}'")]
    [Alias("cc","count")]
    [int] $coreCount,

    [Parameter (Mandatory=$true, HelpMessage="The CSV file name to read from")]
    [Alias("csv","file")]
    [string] $csvFilePath
)

#####################################
#End of Parameters definition block #
#####################################



##############################
# Variables definition block #
##############################

# Do NOT change those variables as it will break the script. They are meant to be static.
$global:targetOS = "Windows Server 2012"
# Azure API endpoint
$global:apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName`?api-version=2023-06-20-preview"
$global:method = "PUT"
$global:creator = $MyInvocation.MyCommand.Name


#########################################
# End of the variables definition block #
#########################################



################################
# Function(s) definition block #
################################

function Get-AzureADBearerToken {
    param(
        [string]$appID,
        [string]$clientSecret,
        [string]$tenantId
    )

    # Defines token authorization endpoint
    $oAuthEndpoint = "https://login.microsoftonline.com/$tenantId/oauth2/token"

    # Builds the request body
    $authbody = @{
        grant_type = "client_credentials"
        client_id = $appID
        client_secret = $clientSecret
        resource = "https://management.azure.com/"
    }
    
    # Obtains the token
    Write-Verbose "Authenticating..."
    try { 
            $response = Invoke-WebRequest -Method Post -Uri $oAuthEndpoint -ContentType "application/x-www-form-urlencoded" -Body $authbody
            $accessToken = ($response.Content | ConvertFrom-Json).access_token
            return $accessToken
    }
    
    catch { 
        Write-Error "Error obtaining Bearer token: $_"
        return $null
     }    
}

function CreateESULicense {
    param (
        [string]$appID,
        [string]$clientSecret,
        [string]$tenantId,
        [string]$location,
        [string]$state,
        [string]$edition,
        [string]$coreType,
        [int]$coreCount
    )
    

# Gets a bearer token from the App
$bearerToken = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId 

# Sets the headers for the request
$headers = @{
    "Authorization" = "Bearer $bearerToken"
    "Content-Type" = "application/json"
}

# Defines the request body as a PowerShell hashtable
$requestBody = @{
    location = $location
    properties = @{
        licenseDetails = @{
            state = $state
            target = $global:targetOS
            edition = $edition
            Type = $coreType
            Processors = $coreCount
        }
    }
    tags = @{
        CreatedBy = "$global:creator"
        "ESU Usage" = “WS2012 MULTIPURPOSE”
    }
}

# Converts the request body to JSON
$requestBodyJson = $requestBody | ConvertTo-Json -Depth 5

# Sends the PUT request to update the license
$response = Invoke-RestMethod -Uri $global:apiEndpoint -Method $global:method -Headers $headers -Body $requestBodyJson

# Sends the response to STDOUT, which would be captured by the calling script if any
$response

}

#######################################
# End of Function(s) definition block #
#######################################



#####################
# Main script block #
#####################

# Invoke your second script here using the provided arguments
    # For example:
    # & "Path\To\Your\SecondScript.ps1" -ServerName $ServerName -LicenseEdition $LicenseEdition -CoreType $CoreType -CoreCount $CoreCount

$data = Import-Csv -Path $csvFilePath


# Define the script block for parallel execution
$scriptBlock = {
    param ($rowData)
    CreateESULicense -subscriptionId $subscriptionId `
    -tenantId $tenantId `
    -appID $appID `
    -clientSecret $clientSecret `
    -licenseResourceGroupName $licenseResourceGroupName `
    -licenseName $licenseName `
    -location $location `
    -state $state `
    -edition $edition `
    -coreType $coreType `
    -coreCount $coreCount 
    
    RunSecondScript -ServerName $rowData.servername -LicenseEdition $rowData.licenseedition -CoreType $rowData.coretype -CoreCount $rowData.corecount
}

# Loop through the data and run the script block as a job
foreach ($row in $data) {
    $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $row
}

# Wait for all jobs to finish
Get-Job | Wait-Job

# Retrieve the job results if necessary
Get-Job | Receive-Job

# Remove the jobs
Get-Job | Remove-Job



############################
# End of Main script block #
############################