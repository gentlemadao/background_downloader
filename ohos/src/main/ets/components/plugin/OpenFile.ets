import { common, Want } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class OpenFile {
  private static readonly TAG = "OpenFile";

  /**
   * Opens the file at the given [filePath] using the system's default app for its MIME type.
   * On OpenHarmony, this is done via starting an ability with a Want.
   */
  public static async openFile(context: common.UIAbilityContext, filePath: string, mimeType?: string): Promise<boolean> {
    try {
      const uri = fileUri.getUriFromPath(filePath);
      const want: Want = {
        action: "ohos.want.action.viewData",
        uri: uri,
        type: mimeType
      };

      await context.startAbility(want);
      console.info(OpenFile.TAG, `Successfully started ability to open file: ${filePath}`);
      return true;
    } catch (e) {
      const error = e as BusinessError;
      console.error(OpenFile.TAG, `Failed to open file ${filePath}. Code: ${error.code}, Message: ${error.message}`);
      return false;
    }
  }
}
