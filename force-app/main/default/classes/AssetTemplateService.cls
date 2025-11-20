/**
 * Service class for Asset Template operations
 * Handles bulk asset generation from templates and template queries
 */
public with sharing class AssetTemplateService {
    
    // Constants for validation
    private static final Integer MIN_QUANTITY = 1;
    private static final Integer MAX_QUANTITY = 100;
    
    /**
     * Generates multiple Asset records from a template
     * @param templateId - ID of the AssetTemplate__c record
     * @param quantity - Number of assets to create (1-100)
     * @param sitePrefix - Prefix for asset names (e.g., 'SITE-A')
     * @param startNumber - Starting number for sequential naming
     * @return List<Id> - IDs of created Asset records
     * @throws AuraHandledException for validation or DML errors
     */
    @AuraEnabled
    public static List<Id> generateAssetsFromTemplate(
        Id templateId, 
        Integer quantity, 
        String sitePrefix, 
        Integer startNumber
    ) {
        try {
            // Step 1: Validate input parameters
            validateInputs(templateId, quantity, sitePrefix, startNumber);
            
            // Step 2: Query the template with all custom fields
            AssetTemplate__c template = queryTemplate(templateId);
            
            // Step 3: Validate template is active
            if (!template.Is_Active__c) {
                throw new AuraHandledException('Template is not active. Please select an active template.');
            }
            
            // Step 4: Get first account for Asset records (query once outside loop)
            List<Account> accounts = [SELECT Id FROM Account WITH USER_MODE LIMIT 1];
            Id accountId = !accounts.isEmpty() ? accounts[0].Id : null;
            
            // Step 5: Generate assets in bulk
            List<Asset> assetsToInsert = new List<Asset>();
            
            for (Integer i = 0; i < quantity; i++) {
                Asset newAsset = createAssetFromTemplate(template, sitePrefix, startNumber + i, accountId);
                assetsToInsert.add(newAsset);
            }
            
            // Step 6: Check create permission and bulk insert all assets
            if (!Schema.sObjectType.Asset.isCreateable()) {
                throw new AuraHandledException('You do not have permission to create Assets.');
            }
            
            SObjectAccessDecision decision = Security.stripInaccessible(
                AccessType.CREATABLE, assetsToInsert);
            insert decision.getRecords();
            
            // Step 7: Create MaintenancePlans for each asset
            List<MaintenancePlan> maintenancePlansToInsert = new List<MaintenancePlan>();
            for (Asset a : (List<Asset>)decision.getRecords()) {
                MaintenancePlan mp = createMaintenancePlanForAsset(a, template);
                if (mp != null) {
                    maintenancePlansToInsert.add(mp);
                }
            }
            
            // Step 8: Insert MaintenancePlans if any
            if (!maintenancePlansToInsert.isEmpty()) {
                if (Schema.sObjectType.MaintenancePlan.isCreateable()) {
                    SObjectAccessDecision mpDecision = Security.stripInaccessible(
                        AccessType.CREATABLE, maintenancePlansToInsert);
                    insert mpDecision.getRecords();
                }
            }
            
            // Step 9: Return list of created Asset IDs
            List<Id> assetIds = new List<Id>();
            for (SObject a : decision.getRecords()) {
                assetIds.add(a.Id);
            }
            
            return assetIds;
            
        } catch (Exception e) {
            // Handle and throw user-friendly error
            throw new AuraHandledException('Error generating assets: ' + e.getMessage());
        }
    }
    
    /**
     * Retrieves all active Asset Templates for dropdown selection
     * @return List<AssetTemplate__c> - Active templates with key fields
     */
    @AuraEnabled(cacheable=true)
    public static List<AssetTemplate__c> getActiveTemplates() {
        try {
            // Query active templates with essential fields for LWC dropdown
            return [
                SELECT Id, Name, Asset_Type__c, Manufacturer__c, Model__c, Description__c, Is_Active__c
                FROM AssetTemplate__c
                WHERE Is_Active__c = true
                WITH USER_MODE
                ORDER BY Name ASC
                LIMIT 200
            ];
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving templates: ' + e.getMessage());
        }
    }
    
    // ========== PRIVATE HELPER METHODS ==========
    
    /**
     * Validates all input parameters with enhanced validation
     */
    private static void validateInputs(Id templateId, Integer quantity, String sitePrefix, Integer startNumber) {
        if (templateId == null) {
            throw new AuraHandledException('Template ID is required.');
        }
        
        if (quantity == null || quantity < MIN_QUANTITY || quantity > MAX_QUANTITY) {
            throw new AuraHandledException('Quantity must be between ' + MIN_QUANTITY + ' and ' + MAX_QUANTITY + '.');
        }
        
        if (String.isBlank(sitePrefix)) {
            throw new AuraHandledException('Site prefix is required.');
        }
        
        // Validate site prefix format (alphanumeric and hyphens only, max 20 chars)
        Pattern sitePrefixPattern = Pattern.compile('^[A-Za-z0-9-]{1,20}$');
        if (!sitePrefixPattern.matcher(sitePrefix).matches()) {
            throw new AuraHandledException('Site prefix must be alphanumeric with hyphens only (max 20 characters).');
        }
        
        if (startNumber == null || startNumber < 0) {
            throw new AuraHandledException('Start number must be a positive integer.');
        }
        
        if (startNumber > 9999) {
            throw new AuraHandledException('Start number must be less than 10000.');
        }
    }
    
    /**
     * Queries template with all custom fields
     */
    private static AssetTemplate__c queryTemplate(Id templateId) {
        String assetTypeField = NamespaceUtil.getFieldName('Asset_Type__c');
        String manufacturerField = NamespaceUtil.getFieldName('Manufacturer__c');
        String modelField = NamespaceUtil.getFieldName('Model__c');
        String descriptionField = NamespaceUtil.getFieldName('Description__c');
        String defaultStatusField = NamespaceUtil.getFieldName('Default_Status__c');
        String isActiveField = NamespaceUtil.getFieldName('Is_Active__c');
        String maintenanceIntervalField = NamespaceUtil.getFieldName('Maintenance_Interval_Days__c');
        
        String query = 'SELECT Id, Name, ' + descriptionField + ', ' + assetTypeField + ', ' + 
                       manufacturerField + ', ' + modelField + ', ' + defaultStatusField + ', ' + 
                       isActiveField + ', ' + maintenanceIntervalField + 
                       ' FROM AssetTemplate__c WHERE Id = :templateId WITH USER_MODE LIMIT 1';
        
        List<AssetTemplate__c> templates = Database.queryWithBinds(
            query, 
            new Map<String, Object>{'templateId' => templateId}, 
            AccessLevel.USER_MODE
        );
        
        if (templates.isEmpty()) {
            throw new AuraHandledException('Template not found with ID: ' + templateId);
        }
        
        return templates[0];
    }
    
    /**
     * Creates a single Asset record from template
     * Naming format: {sitePrefix}-{AssetType}-{sequenceNum}
     * Example: SITE-A-VEHICLE-0001
     */
    private static Asset createAssetFromTemplate(AssetTemplate__c template, String sitePrefix, Integer sequenceNum, Id accountId) {
        Asset newAsset = new Asset();
        
        String assetTypeField = NamespaceUtil.getFieldName('Asset_Type__c');
        String assetTemplateField = NamespaceUtil.getFieldName('Asset_Template__c');
        String createdFromTemplateField = NamespaceUtil.getFieldName('Created_From_Template__c');
        String templateAppliedDateField = NamespaceUtil.getFieldName('Template_Applied_Date__c');
        String descriptionField = NamespaceUtil.getFieldName('Description__c');
        String defaultStatusField = NamespaceUtil.getFieldName('Default_Status__c');
        
        // Generate asset name with format: SITE-A-VEHICLE-0001
        String assetType = template.get(assetTypeField) != null ? 
                          ((String)template.get(assetTypeField)).toUpperCase() : 'ASSET';
        String formattedNumber = String.valueOf(sequenceNum).leftPad(4, '0');
        newAsset.Name = sitePrefix + '-' + assetType + '-' + formattedNumber;
        
        // Copy template fields to asset
        newAsset.Description = (String)template.get(descriptionField);
        
        // Set account if available
        if (accountId != null) {
            newAsset.AccountId = accountId;
        }
        
        // Set custom fields using namespace-aware field names
        newAsset.put(assetTemplateField, template.Id);
        newAsset.put(createdFromTemplateField, true);
        newAsset.put(templateAppliedDateField, System.now());
        
        // Set status from template default
        if (template.get(defaultStatusField) != null) {
            newAsset.Status = (String)template.get(defaultStatusField);
        }
        
        return newAsset;
    }
    
    /**
     * Creates a MaintenancePlan for an Asset based on template configuration
     */
    private static MaintenancePlan createMaintenancePlanForAsset(Asset asset, AssetTemplate__c template) {
        String maintenanceIntervalField = NamespaceUtil.getFieldName('Maintenance_Interval_Days__c');
        Decimal maintenanceInterval = (Decimal)template.get(maintenanceIntervalField);
        
        // Only create maintenance plan if template has maintenance interval configured
        if (maintenanceInterval == null || maintenanceInterval <= 0) {
            return null;
        }
        
        MaintenancePlan mp = new MaintenancePlan();
        mp.AssetId = asset.Id;
        mp.MaintenancePlanTitle = 'Maintenance Plan - ' + asset.Name;
        mp.StartDate = Date.today();
        mp.Frequency = 'Days';
        mp.FrequencyType = 'Recurring';
        mp.MaintenancePlanDuration = Integer.valueOf(maintenanceInterval);
        
        return mp;
    }
}
