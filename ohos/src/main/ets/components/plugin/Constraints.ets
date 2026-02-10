import { Task } from './Models';
import { common } from '@kit.AbilityKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { statfs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class Constraints {
  private static readonly TAG = 'Constraints';

  /**
   * Checks if all constraints for the task are met.
   */
  static async meetsConstraints(task: Task, context: common.UIAbilityContext): Promise<boolean> {
    if (task.requiresWiFi) {
      const wifiMet = await Constraints.checkWiFi();
      if (!wifiMet) {
        console.info(Constraints.TAG, `Task ${task.taskId} requires WiFi but it is not available.`);
        return false;
      }
    }

    if (task.requiresCharging) {
      if (!Constraints.checkCharging()) {
        console.info(Constraints.TAG, `Task ${task.taskId} requires charging but device is not charging.`);
        return false;
      }
    }

    if (task.requiresBatteryNotLow) {
      if (!Constraints.checkBatteryNotLow()) {
        console.info(Constraints.TAG, `Task ${task.taskId} requires battery not low.`);
        return false;
      }
    }

    if (task.requiresStorageNotLow) {
      const storageMet = await Constraints.checkStorageNotLow(context);
      if (!storageMet) {
        console.info(Constraints.TAG, `Task ${task.taskId} requires storage not low.`);
        return false;
      }
    }

    // requiresDeviceIdle is ignored as it's hard to determine reliably and usually handled by OS job schedulers
    
    return true;
  }

  private static async checkWiFi(): Promise<boolean> {
    try {
      const hasNet = await connection.hasDefaultNet();
      if (!hasNet) return false;
      
      const netHandle = connection.getDefaultNetSync();
      const capabilities = await connection.getNetCapabilities(netHandle);
      return capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI);
    } catch (e) {
      console.error(Constraints.TAG, `WiFi check failed: ${(e as BusinessError).message}`);
      return false;
    }
  }

  private static checkCharging(): boolean {
    try {
      const status = batteryInfo.chargingStatus;
      return status === batteryInfo.BatteryChargeState.ENABLE || status === batteryInfo.BatteryChargeState.FULL;
    } catch (e) {
      console.error(Constraints.TAG, `Charging check failed: ${(e as BusinessError).message}`);
      // Fail safe
      return false;
    }
  }

  private static checkBatteryNotLow(): boolean {
    try {
      const level = batteryInfo.batterySOC;
      // Define "Low" as < 20%? Android usually uses a system broadcast. 
      // Here we pick a reasonable threshold or check if system has a flag.
      // For simplicity, let's say > 15%
      return level > 15;
    } catch (e) {
      console.error(Constraints.TAG, `Battery check failed: ${(e as BusinessError).message}`);
      return true; // Assume not low if can't check
    }
  }

  private static async checkStorageNotLow(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const path = context.filesDir; // Check internal storage associated with app
      const freeSize = statfs.getFreeSizeSync(path);
      const totalSize = statfs.getTotalSizeSync(path);
      
      // Threshold: e.g. 5% of total or fixed 100MB?
      // Android uses sys specific low storage threshold.
      // Let's use 100MB as a safe buffer.
      const threshold = 100 * 1024 * 1024; 
      return freeSize > threshold;
    } catch (e) {
      console.error(Constraints.TAG, `Storage check failed: ${(e as BusinessError).message}`);
      return true; // Assume okay
    }
  }
}
