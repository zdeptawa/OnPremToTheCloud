$PolicyDefinitionPath = './network-security-rule-with-port.json'
$PolicyJson = Get-Content $PolicyDefinitionPath -Raw | ConvertFrom-Json  

Write-Host "Checking Azure Policy status"
$Policy = Get-AzPolicyDefinition -Name $PolicyJson.displayName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
if ($Policy) {
    if ($PolicyJson.metadata.version -eq $Policy.Properties.metadata.version) {
        Write-Host "Policy $($PolicyJson.displayName) is up to date."
    }
    else {
        Write-Host ""; Write-Host "Updating Policy Definition $($PolicyJson.displayName)."
        $Policy = Set-AzPolicyDefinition -Id $Policy.ResourceId -Policy $PolicyDefinitionPath -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 
    }
}
else {
    Write-Host "Creating New Policy Definition $($PolicyJson.displayName)."
    $Policy = New-AzPolicyDefinition -Name $PolicyJson.displayName -Policy $PolicyDefinitionPath -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
}

$PolicyName = $PolicyJson.displayName.tolower() -replace '\s+', '-'
$PolicyAssignment = Get-AzPolicyAssignment -Name $PolicyName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
if (-not $PolicyAssignment) {
    Write-Host ""; Write-Host "Assigning the policy to block opening 3389 to the internet."
    New-AzPolicyAssignment -Name $PolicyName -DisplayName $PolicyJson.displayName -PolicyDefinition $Policy -PolicyParameterObject @{port = '3389' } | Out-Null
}
else {
    Write-Host ""; Write-Host "Policy already assigned."    
}