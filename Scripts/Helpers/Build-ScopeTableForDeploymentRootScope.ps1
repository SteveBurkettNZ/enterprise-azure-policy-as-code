function Build-ScopeTableForDeploymentRootScope {

    param(
        [hashtable] $PacEnvironment
    )

    $deploymentRootScope = $PacEnvironment.deploymentRootScope
    $tenantId = $PacEnvironment.tenantId
    Write-Information ""
    Write-Information "==================================================================================================="
    Write-Information "Get scope tree for EPAC environment '$($PacEnvironment.pacSelector)' at root scope $($deploymentRootScope -replace '/providers/Microsoft.Management','')"
    Write-Information "==================================================================================================="

    $scopeTable = @{}
    $tenantId = $PacEnvironment.tenantId
    $resourceGroupsBySubscriptionId = @{}
    $deploymentRootScopeSubscriptionId = $null
    $deploymentRootScopeManagementGroupName = $null
    $scopeSplat = $null
    $resourceGroupQuery = "resourcecontainers | where type == 'microsoft.resources/subscriptions/resourcegroups'"
    if ($deploymentRootScope.StartsWith("/providers/Microsoft.Management/managementGroups/")) {
        $deploymentRootScopeManagementGroupName = $deploymentRootScope -replace "/providers/Microsoft.Management/managementGroups/"
        $scopeSplat = @{
            ManagementGroup = $deploymentRootScopeManagementGroupName
        }
    }
    elseif ($deploymentRootScope.StartsWith("/subscriptions/")) {
        $deploymentRootScopeSubscriptionId = $deploymentRootScope -replace "/subscriptions/"
        $scopeSplat = @{
            Subscription = $deploymentRootScopeSubscriptionId
        }
        $resourceGroupQuery = "resourcecontainers | where type == 'microsoft.resources/subscriptions/resourcegroups' and subscriptionId == '$($deploymentRootScopeSubscriptionId)'"
    }
    else {
        throw "Invalid deploymentRootScope: $deploymentRootScope"
    }

    #region collect resource groups
    $resourceGroups = Search-AzGraphAllItems `
        -Query $resourceGroupQuery `
        -ScopeSplat $scopeSplat `
        -ProgressItemName "Resource Groups"
    Write-Information "Processing $($resourceGroups.Count) Resource Groups..."
    foreach ($resourceGroup in $resourceGroups) {
        $subscriptionId = $resourceGroup.subscriptionId
        $id = $resourceGroup.id
        $isExcluded = $false
        $isInGlobalNotScope = $false
        foreach ($globalNotScope in $PacEnvironment.globalNotScopesResourceGroups) {
            if ($id -like $globalNotScope) {
                $isExcluded = $true
                $isInGlobalNotScope = $true
                break
            }
        }
        if (!$isExcluded) {
            foreach ($excludedScope in $PacEnvironment.globalExcludedScopesResourceGroups) {
                if ($id -like $excludedScope) {
                    $isExcluded = $true
                    break
                }
            }
        }
        $scopeDetails = @{
            id                  = $resourceGroup.id
            type                = $resourceGroup.type
            name                = $resourceGroup.name
            displayName         = $resourceGroup.name
            parentTable         = @{}
            childrenTable       = @{}
            resourceGroupsTable = @{}
            notScopesList       = [System.Collections.ArrayList]::new()
            notScopesTable      = @{}
            excludedScopesTable = @{}
            isExcluded          = $isExcluded
            isInGlobalNotScope  = $isInGlobalNotScope
            state               = $resourceGroup.properties.provisioningState
            location            = $resourceContainer.location
        }

        $resourceGroupList = $null
        if ($resourceGroupsBySubscriptionId.ContainsKey($subscriptionId)) {
            $resourceGroupList = $resourceGroupsBySubscriptionId.$subscriptionId
        }
        else {
            $resourceGroupList = [System.Collections.ArrayList]::new()
            $null = $resourceGroupsBySubscriptionId.Add($subscriptionId, $resourceGroupList)
        }
        $null = $resourceGroupList.Add($scopeDetails)
    }
    #endregion collect resource groups

    #region process subscriptions and/or management groups
    $scopeDetails = $null
    if ($null -ne $deploymentRootScopeSubscriptionId) {
        try {
            $subscription = Get-AzSubscription -SubscriptionId $deploymentRootScopeSubscriptionId -TenantId $tenantId
        }
        catch {
            Write-Error "You do not have sufficient permissions over the default context.  Please set the 'defaultContext' parameter for this pacSelector in the globalSettings file.  This is usually only an issue when a Lighthouse tenant is being deployed to."
        }
        $subscriptionId = $subscription.Id
        $scopeDetails = Build-ScopeTableForSubscription `
            -SubscriptionId $subscriptionId `
            -SubscriptionName $subscription.Name `
            -ResourceGroupsBySubscriptionId $resourceGroupsBySubscriptionId `
            -PacEnvironment $PacEnvironment `
            -ScopeTable $scopeTable
    }
    else {
        try {
            $managementGroup = Get-AzManagementGroup -GroupName $deploymentRootScopeManagementGroupName -Expand -Recurse
        }
        catch {
            Write-Error "You do not have sufficient permissions over the default context.  Please set the 'defaultContext' parameter for this pacSelector in the globalSettings file"
        }
        $scopeDetails = Build-ScopeTableForManagementGroup `
            -ManagementGroup $managementGroup `
            -ResourceGroupsBySubscriptionId $resourceGroupsBySubscriptionId `
            -PacEnvironment $PacEnvironment `
            -ScopeTable $scopeTable
    }
    $null = $scopeTable.Add($scopeDetails.id, $scopeDetails)
    $null = $scopeTable.Add("root", $scopeDetails)

    # count each type of scope
    $numberOfManagementGroups = 0
    $numberOfSubscriptions = 0
    $numberofResourceGroups = 0
    foreach ($scopeDetails in $scopeTable.Values) {
        if ($scopeDetails.type -eq "Microsoft.Management/managementGroups") {
            $numberOfManagementGroups++
        }
        elseif ($scopeDetails.type -eq "/subscriptions") {
            $numberOfSubscriptions++
        }
        elseif ($scopeDetails.type -eq "microsoft.resources/subscriptions/resourcegroups") {
            $numberofResourceGroups++
        }
    }
    #endregion process subscriptions and/or management groups

    Write-Information ""
    Write-Information "Scope tree for EPAC environment '$($PacEnvironment.pacSelector)' at root scope $($deploymentRootScope -replace '/providers/Microsoft.Management','') complete."
    if ($numberOfManagementGroups -gt 0) {
        $numberOfManagementGroups-- # subtract 1 for the root scope
        Write-Information "    Management groups = $($numberOfManagementGroups)"
    }
    Write-Information "    Subscriptions     = $($numberOfSubscriptions)"
    Write-Information "    Resource groups   = $($numberofResourceGroups)"

    return $scopeTable
}