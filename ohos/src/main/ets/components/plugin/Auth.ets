import { collections, uri } from '@kit.ArkTS';

@Sendable
export class Auth {
  accessToken?: string;
  accessHeaders: collections.Map<string, string>;
  accessQueryParams: collections.Map<string, string>;
  accessTokenExpiryTime?: number;
  refreshToken?: string;
  refreshHeaders: collections.Map<string, string>;
  refreshQueryParams: collections.Map<string, string>;
  refreshUrl?: string;
  onAuthRawHandle?: number;

  constructor(
    accessToken?: string,
    accessHeaders: collections.Map<string, string> = new collections.Map(),
    accessQueryParams: collections.Map<string, string> = new collections.Map(),
    accessTokenExpiryTime?: number,
    refreshToken?: string,
    refreshHeaders: collections.Map<string, string> = new collections.Map(),
    refreshQueryParams: collections.Map<string, string> = new collections.Map(),
    refreshUrl?: string,
    onAuthRawHandle?: number
  ) {
    this.accessToken = accessToken;
    this.accessHeaders = accessHeaders;
    this.accessQueryParams = accessQueryParams;
    this.accessTokenExpiryTime = accessTokenExpiryTime;
    this.refreshToken = refreshToken;
    this.refreshHeaders = refreshHeaders;
    this.refreshQueryParams = refreshQueryParams;
    this.refreshUrl = refreshUrl;
    this.onAuthRawHandle = onAuthRawHandle;
  }

  getExpandedAccessHeaders(): collections.Map<string, string> {
    return this.expandMap(this.accessHeaders);
  }

  getExpandedAccessQueryParams(): collections.Map<string, string> {
    return this.expandMap(this.accessQueryParams);
  }

  addOrUpdateQueryParams(url: string, queryParams: collections.Map<string, string> = new collections.Map()): uri.URI {
    const startUri = new uri.URI(url);
    if (queryParams.size === 0) {
      return startUri;
    }

    const updatedQueryParams = new collections.Map<string, string | null>();
    // Copy existing params
    const existingParams = startUri.query.split('&');
    for (const param of existingParams) {
      const params = param.split('=');
      const key = params[0];
      const value = params[1];
      if (key) {
        updatedQueryParams.set(decodeURIComponent(key), decodeURIComponent(value || ''));
      }
    }

    // Add/update with new params
    queryParams.forEach((value: string, key: string) => {
      if (value !== undefined && key !== undefined) {
        updatedQueryParams.set(key.trim(), value.toString().trim());
      }
    });

    // Rebuild the query string
    let newQuery = '';
    updatedQueryParams.forEach((value: string | null, key: string | null) => {
      if (value !== undefined && key !== undefined && value !== null && key !== null) {
        if (newQuery.length > 0) {
          newQuery += '&';
        }
        newQuery += `${encodeURIComponent(key)}=${encodeURIComponent(value ?? '')}`;
      }
    });


    return new uri.URI(`${startUri.scheme}://${startUri.authority}${startUri.path}?${newQuery}`);
  }

  isTokenExpired(bufferTime: number = 10000): boolean {
    const expiry = this.accessTokenExpiryTime;
    if (expiry == null) {
      return false;
    }
    const expiryTimeWithBuffer = Date.now() + bufferTime;
    return expiryTimeWithBuffer > expiry;
  }

  private expandMap(mapToExpand: collections.Map<string, string>): collections.Map<string, string> {
    const newMap = new collections.Map<string, string>();
    mapToExpand.forEach((value: string, key: string) => {
      let newValue = value;
      if (this.accessToken) {
        newValue = newValue.replace('{accessToken}', this.accessToken);
      }
      if (this.refreshToken) {
        newValue = newValue.replace('{refreshToken}', this.refreshToken);
      }
      newMap.set(key, newValue);
    });
    return newMap;
  }

  hasOnAuthCallback(): boolean {
    return this.onAuthRawHandle != null;
  }
}