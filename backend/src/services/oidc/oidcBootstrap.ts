import { readFile } from 'node:fs/promises';
import { z } from 'zod';
import { getSecretsInfo } from '../../utils/secrets';
import { APP_ROLES, loadOidcConfigRow, saveOidcConfig, validateOidcConfigPatch } from './oidcConfig';

const role = z.enum(APP_ROLES);
const bootstrapConfig = z.strictObject({
  enabled: z.boolean(),
  issuer_url: z.string(),
  client_id: z.string(),
  client_secret: z.string(),
  scopes: z.string(),
  username_claim: z.string(),
  email_claim: z.string(),
  groups_claim: z.string(),
  group_role_map: z.record(z.string(), role),
  default_role: role,
  auto_provision: z.boolean(),
  link_by_verified_email: z.boolean(),
  allowed_email_domains: z.array(z.string()),
  button_label: z.string(),
  public_base_url: z.string(),
}).partial();

export async function bootstrapOidcConfig(file: string | undefined, encryptionKeyVerified: boolean): Promise<void> {
  if (!file) return;

  try {
    if (await loadOidcConfigRow()) return;
    // The operator supplies this path through the backend environment.
    // eslint-disable-next-line security/detect-non-literal-fs-filename
    const { client_secret, ...patch } = bootstrapConfig.parse(JSON.parse(await readFile(file, 'utf8')));
    if (validateOidcConfigPatch(patch)) throw new Error('Invalid OIDC settings');
    if (patch.enabled) {
      if (!patch.issuer_url || !patch.client_id?.trim()) throw new Error('Incomplete OIDC settings');
      const { protocol } = new URL(patch.issuer_url);
      if (protocol !== 'https:' && protocol !== 'http:') throw new Error('Unsupported issuer protocol');
    }
    if (patch.public_base_url) {
      // The login route appends the callback path to this string.
      if (!/^https?:\/\/[^/]/i.test(patch.public_base_url) || /[\s\\?#]/u.test(patch.public_base_url)) {
        throw new Error('Invalid public base URL');
      }
      const { username, password } = new URL(patch.public_base_url);
      if (username || password) throw new Error('Invalid public base URL');
    }
    const { encSource, ephemeral } = getSecretsInfo();
    if (!encryptionKeyVerified || (client_secret && encSource === 'generated' && ephemeral)) {
      throw new Error('Encryption key unavailable');
    }
    await saveOidcConfig(patch, client_secret, true);
  } catch {
    // File and parser errors can include the path or raw input, including secrets.
    throw new Error('OIDC_BOOTSTRAP_FILE import failed. Check the mounted JSON settings, database, and encryption key.');
  }
}
