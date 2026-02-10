import { Queue } from "@kit.ArkTS";
import { EnqueueItem } from "./HoldingQueue";
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import BDPlugin from './BDPlugin';
import { Task, TaskStatus } from './Models';
import TransferManager from './TransferManager';

export class WiFi {
  static readonly TAG = 'WiFi';
  static requireWifi: boolean = true;
  static requireWiFiQueue: Queue<EnqueueItem> = new Queue<EnqueueItem>();
  static reEnqueueQueue: Queue<EnqueueItem> = new Queue<EnqueueItem>();
  private static netConnection: connection.NetConnection | undefined = undefined;

  /**
   * Initializes the WiFi module, registering network listeners.
   */
  static init() {
    try {
      WiFi.netConnection = connection.createNetConnection();
      WiFi.netConnection.on('netAvailable', (data) => {
        console.info(WiFi.TAG, 'Network available');
        WiFi.checkQueue();
      });
      WiFi.netConnection.on('netCapabilitiesChange', (data) => {
        console.info(WiFi.TAG, 'Network capabilities changed');
        WiFi.checkQueue();
      });
      WiFi.netConnection.register((error: BusinessError) => {
        if (error) {
          console.error(WiFi.TAG, `Register network listener error: ${error.message}`);
        }
      });
    } catch (e) {
      console.error(WiFi.TAG, `WiFi init error: ${(e as BusinessError).message}`);
    }
  }

  static reEnqueue(enqueueItem?: EnqueueItem) {
    if (enqueueItem) {
      WiFi.reEnqueueQueue.add(enqueueItem);
      // In a real implementation, we would process this queue to restart tasks
    }
  }

  /**
   * Checks if the current network satisfies the task's requirements.
   * Returns true if task can proceed, false otherwise.
   */
  static async canProceed(task: Task): Promise<boolean> {
    if (!task.requiresWiFi) {
      return true;
    }
    
    try {
      const hasWiFi = await connection.hasDefaultNet();
      if (!hasWiFi) return false;

      const netHandle = connection.getDefaultNetSync();
      const capabilities = await connection.getNetCapabilities(netHandle);
      
      // Check if bearer types include WIFI (bearerType 1 is WIFI, 0 is CELLULAR)
      // Note: API might vary slightly, checking for 'BEARER_WIFI' constant equivalent
      if (capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) {
          return true;
      }
      return false;
    } catch (e) {
      console.error(WiFi.TAG, `Network check failed: ${(e as BusinessError).message}`);
      // Default to false if we can't determine, to stay safe
      return false;
    }
  }

  /**
   * Checks the waiting queue and starts tasks if WiFi is available.
   */
  static async checkQueue() {
    // This is a simplified check. In a full implementation, we'd need to
    // iterate over paused tasks or a specific 'waiting for wifi' queue
    // and resume them using TransferManager.
    
    // For this MVP, we rely on the fact that if a task failed/paused due to WiFi,
    // the user or system might retry it. This listener ensures we log the state change.
    console.info(WiFi.TAG, "Checking network queue - not fully implemented in MVP");
  }
}