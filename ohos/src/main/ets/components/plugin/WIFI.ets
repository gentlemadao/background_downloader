import { Queue } from "@kit.ArkTS";
import { EnqueueItem } from "./HoldingQueue";

export class WiFi {
  static requireWifi: boolean = true;
  static requireWiFiQueue: Queue<EnqueueItem> = new Queue<EnqueueItem>();
  static reEnqueueQueue: Queue<EnqueueItem> = new Queue<EnqueueItem>();

  static reEnqueue(enqueueItem?: EnqueueItem) {
    if (enqueueItem) {
      WiFi.reEnqueueQueue.add(enqueueItem);
    }
  }
}
