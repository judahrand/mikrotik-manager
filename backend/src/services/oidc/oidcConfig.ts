/**
 * OIDC provider configuration, persisted as a single JSONB row in app_settings
 * under OIDC_SETTINGS_KEY. The client secret is encrypted at rest with the
 * platform's self-healing key (utils/crypto). This key is deliberately excluded
 * from the generic GET/PUT /api/settings surface (see routes/settings.ts) so the
 * secret is only ever written through the dedicated, admin-only OIDC endpoints.
 */
import { query, queryOne } from '../../config/database';
import { encrypt, decrypt } from '../../utils/crypto';

export const OIDC_SETTINGS_KEY = 'oidc_config';

export type AppRole = 'admin' | 'operator' | 'viewer';
export const APP_ROLES: AppRole[] = ['admin', 'operator', 'viewer'];

export interface OidcConfig {
  enabled: boolean;
  issuer_url: string;
  client_id: string;
  /** AES-GCM ciphertext of the client secret, or null if none set. */
  client_secret_encrypted: string | null;
  scopes: string;
  username_claim: string;
  email_claim: string;
  groups_claim: string;
  group_role_map: Record<string, AppRole>;
  default_role: AppRole;
  auto_provision: boolean;
  link_by_verified_email: boolean;
  allowed_email_domains: string[];
  button_label: string;
  /** Optional override for building the redirect URI (else derived from the request). */
  public_base_url: string;
}

export const DEFAULT_OIDC_CONFIG: OidcConfig = {
  enabled: false,
  issuer_url: '',
  client_id: '',
  client_secret_encrypted: null,
  scopes: 'openid profile email',
  username_claim: 'preferred_username',
  email_claim: 'email',
  groups_claim: 'groups',
  group_role_map: {},
  default_role: 'viewer',
  auto_provision: true,
  link_by_verified_email: true,
  allowed_email_domains: [],
  button_label: 'Sign in with SSO',
  public_base_url: '',
};

export function loadOidcConfigRow(): Promise<{ value: Partial<OidcConfig> } | null> {
  return queryOne<{ value: Partial<OidcConfig> }>(
    `SELECT value FROM app_settings WHERE key = $1`,
    [OIDC_SETTINGS_KEY]
  );
}

export async function loadOidcConfig(): Promise<OidcConfig> {
  const row = await loadOidcConfigRow();
  return { ...DEFAULT_OIDC_CONFIG, ...(row?.value ?? {}) };
}

export function validateOidcConfigPatch(body: Partial<OidcConfig>): string | undefined {
  const validRole = (role: unknown): role is AppRole => APP_ROLES.includes(role as AppRole);
  if (body.default_role !== undefined) {
    if (!validRole(body.default_role)) return 'Invalid default_role';
    // Admin must be granted by an explicit group mapping.
    if (body.default_role === 'admin') {
      return 'default_role cannot be admin — grant admin via an explicit group → role mapping instead';
    }
  }
  if (body.group_role_map !== undefined) {
    if (typeof body.group_role_map !== 'object' || body.group_role_map === null) {
      return 'group_role_map must be an object';
    }
    for (const role of Object.values(body.group_role_map)) {
      if (!validRole(role)) return `Invalid role in group_role_map: ${String(role)}`;
    }
  }
  if (body.enabled && body.issuer_url !== undefined) {
    try { new URL(body.issuer_url); } catch { return 'issuer_url must be a valid URL'; }
  }
}

/**
 * Persist config. `newSecret` (plaintext) is encrypted and stored; pass undefined
 * to keep the existing secret, or '' to clear it. Bootstrap uses onlyIfAbsent
 * so a concurrent write through Settings wins.
 */
export async function saveOidcConfig(
  patch: Partial<OidcConfig>,
  newSecret?: string,
  onlyIfAbsent = false
): Promise<OidcConfig> {
  const current = onlyIfAbsent ? DEFAULT_OIDC_CONFIG : await loadOidcConfig();
  const merged: OidcConfig = { ...current, ...patch };

  if (newSecret !== undefined) {
    merged.client_secret_encrypted = newSecret ? encrypt(newSecret) : null;
  }

  const onConflict = onlyIfAbsent ? 'NOTHING' : 'UPDATE SET value = $2, updated_at = NOW()';
  await query(
    `INSERT INTO app_settings (key, value, updated_at) VALUES ($1, $2, NOW())
     ON CONFLICT (key) DO ${onConflict}`,
    [OIDC_SETTINGS_KEY, JSON.stringify(merged)]
  );
  return merged;
}

export function getClientSecret(config: OidcConfig): string | null {
  if (!config.client_secret_encrypted) return null;
  try {
    return decrypt(config.client_secret_encrypted);
  } catch {
    return null;
  }
}

/** Config shape safe to return to an admin UI — no secret material. */
export function maskedConfig(config: OidcConfig): Omit<OidcConfig, 'client_secret_encrypted'> & { has_secret: boolean } {
  const { client_secret_encrypted, ...rest } = config;
  return { ...rest, has_secret: !!client_secret_encrypted };
}
