import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { commonEventManager } from '@kit.BasicServicesKit';
import BDPlugin from 'background_downloader/src/main/ets/components/plugin/BDPlugin';
import { AbilityConstant, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export default class EntryAbility extends FlutterAbility {
  static readonly TAG = 'EntryAbility';
  subscriber: commonEventManager.CommonEventSubscriber | undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    super.onCreate(want, launchParam);
    this.createSubscriber();
  }

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
  }

  onDestroy() {
    super.onDestroy();
    if (this.subscriber) {
      commonEventManager.unsubscribe(this.subscriber, () => {
        console.info(EntryAbility.TAG, "Unsubscribed common event");
      });
    }
  }

  createSubscriber() {
    let subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
      events: ["com.bbflight.background_downloader.pause", "com.bbflight.background_downloader.cancel"]
    };
    commonEventManager.createSubscriber(subscribeInfo).then((subscriber) => {
      this.subscriber = subscriber;
      commonEventManager.subscribe(this.subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        if (err) {
          console.error(EntryAbility.TAG, `Failed to subscribe common event. Code is ${err.code}, message is ${err.message}`);
          return;
        }
        console.info(EntryAbility.TAG, `Received common event: ${data.event}`);
        if (data.parameters) {
          const taskId = data.parameters.taskId as string;
          if (data.event === "com.bbflight.background_downloader.pause") {
            BDPlugin.pauseTaskWithId(taskId);
          } else if (data.event === "com.bbflight.background_downloader.cancel") {
            BDPlugin.cancelTasksWithIds(this.context, [taskId]);
          }
        }
      });
    });
  }
}