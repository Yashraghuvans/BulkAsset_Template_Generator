/**
 * Helper class for AssetDashboardController
 * Contains utility methods for maintenance status calculations using FSL objects
 */
public with sharing class AssetDashboardControllerHelper {
    
    /**
     * Get maintenance status for assets based on MaintenancePlan and WorkOrder
     * Replaces custom field-based maintenance tracking
     */
    public static Map<String, Integer> calculateMaintenanceStatus(List<Asset> assets) {
        Map<String, Integer> maintenanceMap = new Map<String, Integer>{
            'Current' => 0,
            'Due Soon' => 0,
            'Overdue' => 0,
            'Not Set' => 0
        };
        
        if (assets.isEmpty()) {
            return maintenanceMap;
        }
        
        Set<Id> assetIds = new Set<Id>();
        for (Asset a : assets) {
            assetIds.add(a.Id);
        }
        
        // Query MaintenancePlans for these assets
        Map<Id, Date> assetToNextMaintenance = new Map<Id, Date>();
        
        for (MaintenancePlan mp : [
            SELECT AssetId, NextSuggestedMaintenanceDate
            FROM MaintenancePlan
            WHERE AssetId IN :assetIds
            AND NextSuggestedMaintenanceDate != null
            WITH USER_MODE
            ORDER BY NextSuggestedMaintenanceDate ASC
        ]) {
            if (!assetToNextMaintenance.containsKey(mp.AssetId)) {
                assetToNextMaintenance.put(mp.AssetId, mp.NextSuggestedMaintenanceDate);
            }
        }
        
        // Also check for scheduled WorkOrders
        for (WorkOrder wo : [
            SELECT AssetId, StartDate
            FROM WorkOrder
            WHERE AssetId IN :assetIds
            AND Status IN ('New', 'Scheduled')
            AND StartDate != null
            WITH USER_MODE
            ORDER BY StartDate ASC
        ]) {
            Date existingDate = assetToNextMaintenance.get(wo.AssetId);
            if (existingDate == null || wo.StartDate < existingDate) {
                assetToNextMaintenance.put(wo.AssetId, wo.StartDate);
            }
        }
        
        Date today = Date.today();
        
        for (Asset asset : assets) {
            Date nextMaintenance = assetToNextMaintenance.get(asset.Id);
            String status = 'Not Set';
            
            if (nextMaintenance != null) {
                Integer daysUntil = today.daysBetween(nextMaintenance);
                
                if (daysUntil < 0) {
                    status = 'Overdue';
                } else if (daysUntil <= 7) {
                    status = 'Due Soon';
                } else {
                    status = 'Current';
                }
            }
            
            maintenanceMap.put(status, maintenanceMap.get(status) + 1);
        }
        
        return maintenanceMap;
    }
}
