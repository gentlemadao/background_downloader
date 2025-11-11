import { common, abilityAccessCtrl, Permissions, bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';

// Corresponds to the Dart enum PermissionType
export enum PermissionType {
  notifications,
  androidSharedStorage, // Maps to media permissions on OHOS
}

// Corresponds to the Dart enum PermissionStatus
export enum PermissionStatus {
  undetermined,
  denied,
  granted,
  partial, // Not used on OHOS, but kept for compatibility
  requestError,
}

export class PermissionsService {
  /**
   * Maps our internal PermissionType to the OHOS permission string.
   */
  private static getOhosPermission(permissionType: PermissionType): Permissions | null {
    switch (permissionType) {
      case PermissionType.androidSharedStorage:
        // On OHOS, this maps to media permissions. We'll request both read and write.
        return 'ohos.permission.WRITE_MEDIA'; // Requesting write also covers read
      default:
        return null;
    }
  }

  /**
   * Checks the status of a given permission.
   */
  public static async getPermissionStatus(permissionType: PermissionType): Promise<PermissionStatus> {
    if (permissionType === PermissionType.notifications) {
      try {
        const isEnabled = await notificationManager.isNotificationEnabled();
        return isEnabled ? PermissionStatus.granted : PermissionStatus.denied;
      } catch (e) {
        console.error('PermissionsService', `Error checking notification status: ${(e as BusinessError).message}`);
        return PermissionStatus.requestError;
      }
    }
    let tokenId: number = 0;
    let grantStatus: abilityAccessCtrl.GrantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;
    try {
      let bundleInfo: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      let appInfo: bundleManager.ApplicationInfo = bundleInfo.appInfo;
      tokenId = appInfo.accessTokenId;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`Failed to get bundle info for self, code: ${err.code}, message: ${err.message}`);
    }

    const atManager = abilityAccessCtrl.createAtManager();
    try {
      grantStatus = await atManager.checkAccessToken(tokenId, PermissionsService.getOhosPermission(permissionType));
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`Failed to check access token, code: ${err.code}, message: ${err.message}`);
    }
    return grantStatus == abilityAccessCtrl.GrantStatus.PERMISSION_DENIED ? PermissionStatus.denied :
    PermissionStatus.granted;
  }

  /**
   * Requests a permission from the user.
   */
  public static async requestPermission(context: common.UIAbilityContext,
    permissionType: PermissionType): Promise<PermissionStatus> {
    if (permissionType === PermissionType.notifications) {
      try {
        await notificationManager.requestEnableNotification(context);
        // After requesting, check the status again to be sure.
        return await PermissionsService.getPermissionStatus(permissionType);
      } catch (e) {
        console.error('PermissionsService',
          `Error requesting notification permission: ${(e as BusinessError).message}`);
        return PermissionStatus.requestError;
      }
    }

    const ohosPermission = PermissionsService.getOhosPermission(permissionType);
    if (!ohosPermission) {
      return PermissionStatus.granted;
    }

    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const permissionsToRequest: Permissions[] = [ohosPermission];

      const result = await atManager.requestPermissionsFromUser(context, permissionsToRequest);
      const grantStatus = result.authResults[0];
      return grantStatus === 0 ? PermissionStatus.granted : PermissionStatus.denied;
    } catch (e) {
      console.error('PermissionsService', `Error requesting permission: ${(e as BusinessError).message}`);
      return PermissionStatus.requestError;
    }
  }
}
