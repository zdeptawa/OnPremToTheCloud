param (
    $ResourceGroupName = 'onpremtothecloud',
    $StorageAccountName = 'optcdsc',
    $StorageContainerName = 'configurations',
    $ConfigurationPath = 'MercHealthConfig.ps1',
    [switch]$FreshStart
)

if ($FreshStart) {
    Remove-AzResourceGroup -Name $ResourceGroupName -Force
    Remove-Item ./current.parameters.json -Force
}

### Policy?

# Set up resource group
New-AzResourceGroup -Name $ResourceGroupName -Location 'eastus'
$TemplateSpecParams = @{
    Version =  '1.0.2'
    ResourceGroupName = $ResourceGroupName 
    Location = 'eastus' 
}

# Deploy templates to template specs
New-AzTemplateSpec -Name MercuryHealthWeb -TemplateFile ./azuredeploy.json @TemplateSpecParams
New-AzTemplateSpec -Name DscStorage -TemplateFile ./DscStorage.json @TemplateSpecParams

# 
$DSCStorageSpec = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Resources/templateSpecs/DscStorage/versions/$($TemplateSpecParams.Version)"
$MercuryHealthSpec = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Resources/templateSpecs/MercuryHealthWeb/versions/$($TemplateSpecParams.Version)"

New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateSpecId $DSCStorageSpec -Mode Complete -Force

# Stage the application files
$Storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
Set-AzStorageBlobContent -File ../MercuryHealth.zip -Container $StorageContainerName -Context $Storage.Context

if (-not (Get-Module -ListAvailable xWebAdministration)) {
    Install-Module xWebAdministration -RequiredVersion 3.2.0 -Scope CurrentUser
}

$Parameters = @{
    ResourceGroupName = $ResourceGroupName 
    ConfigurationPath = $ConfigurationPath
    StorageAccountName = $StorageAccountName
    ContainerName = $StorageContainerName
}

Publish-AzVMDscConfiguration @Parameters

$ExecutionContext.InvokeCommand.ExpandString((get-content './azuredeploy.parameters.json' -raw)) | 
    out-file current.parameters.json -Force
$FullDeploymentParameters = @{
    ResourceGroupName = $ResourceGroupName
    TemplateSpecId = $MercuryHealthSpec 
    TemplateParameterFile = 'current.parameters.json'
    Mode = 'Complete'
    Force = $true
}
New-AzResourceGroupDeployment @FullDeploymentParameters 


<#
# Helpers


Set-AzVMDscExtension -ResourceGroupName $rg -VMName mercuryheathvm -ArchiveStorageAccountName optcdsc -ConfigurationName MercuryHealthWeb -ArchiveBlobName MercHealthConfig.ps1.zip -ArchiveContainerName configurations -Version "2.83"

$template = @'
WindowsFeature $Name {
    Name = '$Name'
    Ensure = 'Present'
}
'@
$templatedep = @'
WindowsFeature $Name {
    Name = '$Name'
    Ensure = 'Present'
    DependsOn = $DependsOn
}
'@

$f | 
    sort depth | 
    % { 
        $Name = $_.Name
        $currenttemplate = if ($_.DependsOn) { $templatedep; $DependsOn = "'[WindowsFeature]" + ($_.DependsOn -join "','[WindowsFeature]") + "'" } else { $template }
        $ExecutionContext.InvokeCommand.ExpandString($currenttemplate)
        }  | clip
    
#>
