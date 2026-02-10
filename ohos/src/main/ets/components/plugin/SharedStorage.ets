import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SharedStorageDestination } from './Models';

export class SharedStorage {
  private static readonly TAG = "SharedStorage";

  /**
   * Move the file at [filePath] to [destination] in shared storage.
   * Returns the path in shared storage if successful, or null.
   */
  public static async moveToSharedStorage(context: common.UIAbilityContext, filePath: string, destination: SharedStorageDestination, directory: string): Promise<string | null> {
    try {
      if (destination === SharedStorageDestination.GALLERY) {
        return await SharedStorage.moveToGallery(context, filePath);
      }
      // For other destinations, currently OHOS has limited support for direct background moving
      // without user interaction (Picker). We might need to use other APIs or return null.
      console.warn(SharedStorage.TAG, `Destination ${destination} not yet fully supported on OHOS`);
      return null;
    } catch (e) {
      console.error(SharedStorage.TAG, `Error moving to shared storage: ${(e as BusinessError).message}`);
      return null;
    }
  }

  private static async moveToGallery(context: common.UIAbilityContext, filePath: string): Promise<string | null> {
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const filename = filePath.split('/').pop() ?? "image.jpg";
      
      // Determine type based on extension
      const extension = filename.split('.').pop()?.toLowerCase() ?? "";
      let photoType = photoAccessHelper.PhotoType.IMAGE;
      if (['mp4', 'mov', 'avi', 'mkv'].includes(extension)) {
        photoType = photoAccessHelper.PhotoType.VIDEO;
      }

      const uri = await helper.createAsset(photoType, extension);
      const file = await fs.open(uri, fs.OpenMode.READ_WRITE);
      const sourceFile = await fs.open(filePath, fs.OpenMode.READ_ONLY);
      
      // Use copy to avoid issues with different mount points
      await fs.copyFile(sourceFile.fd, file.fd);
      
      await fs.close(file);
      await fs.close(sourceFile);
      
      console.info(SharedStorage.TAG, `Successfully moved ${filePath} to Gallery: ${uri}`);
      return uri;
    } catch (e) {
      console.error(SharedStorage.TAG, `Failed to move to gallery: ${(e as BusinessError).message}`);
      return null;
    }
  }

  /**
   * Returns the path in shared storage for the given [filename] and [destination].
   * On OHOS, this is often a virtual URI or a specific path in /storage/media.
   */
  public static pathInSharedStorage(filename: string, destination: SharedStorageDestination, directory: string): string | null {
    // For Gallery/Photos on OHOS, there isn't a simple deterministic file path
    // like /storage/emulated/0/... that we can return easily. 
    // We return a mock or actual path if possible. 
    // For now, return null as most OHOS shared access is via URI.
    return null;
  }
}
