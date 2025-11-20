/**
 * @description Unified handler for Asset trigger logic
 * @author Salesforce Technical Architect
 * @date 2025-11-17
 */
public class AssetTriggerHandler {
    
    // Recursion prevention using record-specific tracking
    private static Set<Id> processedMaintenanceAlerts = new Set<Id>();
    private static Set<Id> processedHierarchyValidations = new Set<Id>();
    private static Set<Id> processedTemplateUpdates = new Set<Id>();
    
    /**
     * Validate hierarchy to prevent circular references
     */
    public static void validateHierarchy(List<Asset> newAssets, Map<Id, Asset> oldAssetMap) {
        for (Asset asset : newAssets) {
            // Skip if already processed in this transaction
            if (processedHierarchyValidations.contains(asset.Id)) {
                continue;
            }
            
            if (asset.ParentId != null) {
                Asset oldAsset = oldAssetMap != null ? oldAssetMap.get(asset.Id) : null;
                
                // Only validate if ParentId changed
                if (oldAsset == null || asset.ParentId != oldAsset.ParentId) {
                    if (!AssetHierarchyService.validateHierarchy(asset.Id, asset.ParentId)) {
                        asset.ParentId.addError('Cannot set parent: This would create a circular reference in the asset hierarchy.');
                    }
                    processedHierarchyValidations.add(asset.Id);
                }
            }
        }
    }
    
    /**
     * Handle overdue maintenance alerts with proper error handling
     * Creates WorkOrder records for overdue maintenance
     */
    public static void handleOverdueMaintenanceAlerts(List<Asset> newAssets, Map<Id, Asset> oldAssetMap) {
        // Prevent processing same assets multiple times in this transaction
        List<Asset> assetsToProcess = new List<Asset>();
        for (Asset newAsset : newAssets) {
            if (!processedMaintenanceAlerts.contains(newAsset.Id)) {
                Asset oldAsset = oldAssetMap.get(newAsset.Id);
                
                // Check if Maintenance_Status__c just changed to 'Overdue'
                if (newAsset.Maintenance_Status__c == 'Overdue' && 
                    oldAsset.Maintenance_Status__c != 'Overdue') {
                    assetsToProcess.add(newAsset);
                    processedMaintenanceAlerts.add(newAsset.Id);
                }
            }
        }
        
        if (assetsToProcess.isEmpty()) {
            return;
        }
        
        // Create WorkOrder records for overdue maintenance
        createMaintenanceWorkOrders(assetsToProcess);
        
        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
        
        // Get the email template if it exists
        List<EmailTemplate> templates = [
            SELECT Id, Subject, Body 
            FROM EmailTemplate 
            WHERE DeveloperName = 'Asset_Overdue_Maintenance_Alert' 
            LIMIT 1
        ];
        
        // Get OrgWideEmailAddress if configured
        List<OrgWideEmailAddress> orgWideAddresses = [
            SELECT Id, Address 
            FROM OrgWideEmailAddress 
            WHERE Address LIKE '%maintenance%' OR Address LIKE '%asset%'
            LIMIT 1
        ];
        
        // Get maintenance team email from custom settings
        String maintenanceTeamEmail = getMaintenanceTeamEmail();
        
        for (Asset asset : assetsToProcess) {
            if (templates.isEmpty()) {
                // Send simple email without template
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setToAddresses(new List<String>{maintenanceTeamEmail});
                email.setSubject('Asset Maintenance Overdue: ' + asset.Name);
                email.setPlainTextBody('Asset ' + asset.Name + ' has overdue maintenance. Please schedule maintenance as soon as possible.');
                
                if (!orgWideAddresses.isEmpty()) {
                    email.setOrgWideEmailAddressId(orgWideAddresses[0].Id);
                }
                
                emailsToSend.add(email);
            } else {
                // Use template
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setTemplateId(templates[0].Id);
                email.setTargetObjectId(asset.OwnerId);
                email.setWhatId(asset.Id);
                email.setToAddresses(new List<String>{maintenanceTeamEmail});
                
                if (!orgWideAddresses.isEmpty()) {
                    email.setOrgWideEmailAddressId(orgWideAddresses[0].Id);
                }
                
                email.setSaveAsActivity(false); // Changed to false to avoid governor limits
                emailsToSend.add(email);
            }
        }
        
        // Send all emails in bulk
        if (!emailsToSend.isEmpty()) {
            try {
                Messaging.sendEmail(emailsToSend);
            } catch (Exception e) {
                // Log error but don't fail the transaction
                System.debug(LoggingLevel.ERROR, 'Error sending overdue maintenance emails: ' + e.getMessage());
            }
        }
    }
    
    /**
     * Update template counts when assets are created/updated/deleted
     */
    public static void updateTemplateCounts(List<Asset> newAssets, List<Asset> oldAssets, Boolean isDelete) {
        Set<Id> templateIds = new Set<Id>();
        
        if (isDelete && oldAssets != null) {
            for (Asset asset : oldAssets) {
                if (!processedTemplateUpdates.contains(asset.Id) && 
                    asset.Asset_Template__c != null && asset.Created_From_Template__c) {
                    templateIds.add(asset.Asset_Template__c);
                    processedTemplateUpdates.add(asset.Id);
                }
            }
        } else if (newAssets != null) {
            for (Integer i = 0; i < newAssets.size(); i++) {
                Asset newAsset = newAssets[i];
                
                if (processedTemplateUpdates.contains(newAsset.Id)) {
                    continue;
                }
                
                Asset oldAsset = (oldAssets != null && i < oldAssets.size()) ? oldAssets[i] : null;
                
                if (oldAsset == null) {
                    // Insert
                    if (newAsset.Asset_Template__c != null && newAsset.Created_From_Template__c) {
                        templateIds.add(newAsset.Asset_Template__c);
                        processedTemplateUpdates.add(newAsset.Id);
                    }
                } else {
                    // Update
                    if (newAsset.Asset_Template__c != oldAsset.Asset_Template__c || 
                        newAsset.Created_From_Template__c != oldAsset.Created_From_Template__c) {
                        if (newAsset.Asset_Template__c != null) {
                            templateIds.add(newAsset.Asset_Template__c);
                        }
                        if (oldAsset.Asset_Template__c != null) {
                            templateIds.add(oldAsset.Asset_Template__c);
                        }
                        processedTemplateUpdates.add(newAsset.Id);
                    }
                }
            }
        }
        
        if (!templateIds.isEmpty()) {
            AssetTemplateTriggerHelper.updateAssetCounts(templateIds);
        }
    }
    
    /**
     * Create WorkOrder records for assets needing maintenance
     */
    private static void createMaintenanceWorkOrders(List<Asset> assets) {
        if (!Schema.sObjectType.WorkOrder.isCreateable()) {
            System.debug('User does not have permission to create WorkOrders');
            return;
        }
        
        List<WorkOrder> workOrdersToCreate = new List<WorkOrder>();
        
        for (Asset asset : assets) {
            WorkOrder wo = new WorkOrder();
            wo.AssetId = asset.Id;
            wo.Subject = 'Overdue Maintenance - ' + asset.Name;
            wo.Description = 'Automated work order created for overdue maintenance';
            wo.Status = 'New';
            wo.Priority = 'High';
            workOrdersToCreate.add(wo);
        }
        
        if (!workOrdersToCreate.isEmpty()) {
            try {
                SObjectAccessDecision decision = Security.stripInaccessible(
                    AccessType.CREATABLE, workOrdersToCreate);
                insert decision.getRecords();
                System.debug('Created ' + decision.getRecords().size() + ' maintenance work orders');
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Error creating maintenance work orders: ' + e.getMessage());
            }
        }
        
        // Also send email alerts
        sendMaintenanceAlertEmails(assets);
    }
    
    /**
     * Send email alerts for overdue maintenance
     */
    private static void sendMaintenanceAlertEmails(List<Asset> assets) {
        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
        
        // Get the email template if it exists
        List<EmailTemplate> templates = [
            SELECT Id, Subject, Body 
            FROM EmailTemplate 
            WHERE DeveloperName = 'Asset_Overdue_Maintenance_Alert' 
            WITH USER_MODE
            LIMIT 1
        ];
        
        // Get OrgWideEmailAddress if configured
        List<OrgWideEmailAddress> orgWideAddresses = [
            SELECT Id, Address 
            FROM OrgWideEmailAddress 
            WHERE Address LIKE '%maintenance%' OR Address LIKE '%asset%'
            WITH USER_MODE
            LIMIT 1
        ];
        
        // Get maintenance team email from custom settings
        String maintenanceTeamEmail = getMaintenanceTeamEmail();
        
        for (Asset asset : assets) {
            if (templates.isEmpty()) {
                // Send simple email without template
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setToAddresses(new List<String>{maintenanceTeamEmail});
                email.setSubject('Asset Maintenance Overdue: ' + asset.Name);
                email.setPlainTextBody('Asset ' + asset.Name + ' has overdue maintenance. Please schedule maintenance as soon as possible.');
                
                if (!orgWideAddresses.isEmpty()) {
                    email.setOrgWideEmailAddressId(orgWideAddresses[0].Id);
                }
                
                emailsToSend.add(email);
            } else {
                // Use template
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setTemplateId(templates[0].Id);
                email.setTargetObjectId(asset.OwnerId);
                email.setWhatId(asset.Id);
                email.setToAddresses(new List<String>{maintenanceTeamEmail});
                
                if (!orgWideAddresses.isEmpty()) {
                    email.setOrgWideEmailAddressId(orgWideAddresses[0].Id);
                }
                
                email.setSaveAsActivity(false);
                emailsToSend.add(email);
            }
        }
        
        // Send all emails in bulk
        if (!emailsToSend.isEmpty()) {
            try {
                Messaging.sendEmail(emailsToSend);
            } catch (Exception e) {
                // Log error but don't fail the transaction
                System.debug(LoggingLevel.ERROR, 'Error sending overdue maintenance emails: ' + e.getMessage());
            }
        }
    }
    
    /**
     * Get maintenance team email - fallback to org admin
     */
    private static String getMaintenanceTeamEmail() {
        // Fallback to org admin email
        List<User> admins = [SELECT Email FROM User WHERE Profile.Name = 'System Administrator' AND IsActive = true LIMIT 1];
        return !admins.isEmpty() ? admins[0].Email : UserInfo.getUserEmail();
    }
}
