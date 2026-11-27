import { readFile } from 'node:fs/promises';
import { query, queryOne } from '../../../config/database';
import { confirmEncryptionKey } from '../../../utils/secrets';
import { bootstrapOidcConfig } from '../oidcBootstrap';
import { DEFAULT_OIDC_CONFIG, getClientSecret, OIDC_SETTINGS_KEY } from '../oidcConfig';

jest.mock('node:fs/promises', () => ({ readFile: jest.fn() }));
jest.mock('../../../config/database', () => ({ query: jest.fn(), queryOne: jest.fn() }));

const file = '/run/secrets/oidc.json';
const secret = 'test client secret';
const config = { enabled: true, issuer_url: 'https://idp.example.test', client_id: 'manager', client_secret: secret };

const originalKey = process.env.ENCRYPTION_KEY;
beforeAll(() => {
  process.env.ENCRYPTION_KEY = 'test-bootstrap-encryption-key-0123456789';
});
afterAll(() => {
  if (originalKey === undefined) delete process.env.ENCRYPTION_KEY;
  else process.env.ENCRYPTION_KEY = originalKey;
});

beforeEach(() => {
  jest.resetAllMocks();
  jest.mocked(queryOne).mockResolvedValue(null);
  jest.mocked(readFile).mockResolvedValue(JSON.stringify(config));
});

it('inserts defaults and an encrypted secret without overwriting a concurrent save', async () => {
  confirmEncryptionKey(0);
  await bootstrapOidcConfig(file, true);

  const [sql, params] = jest.mocked(query).mock.calls[0];
  expect(sql).toContain('ON CONFLICT (key) DO NOTHING');
  expect(params?.[0]).toBe(OIDC_SETTINGS_KEY);
  expect(params?.[1]).not.toContain(secret);
  const stored = JSON.parse(params?.[1] as string);
  expect(stored).toEqual({
    ...DEFAULT_OIDC_CONFIG,
    enabled: true,
    issuer_url: config.issuer_url,
    client_id: config.client_id,
    client_secret_encrypted: expect.any(String),
  });
  expect(getClientSecret(stored)).toBe(secret);
});

it('skips the file when an existing row contains only defaults', async () => {
  jest.mocked(queryOne).mockResolvedValue({ value: {} });
  await bootstrapOidcConfig(file, false);

  expect(readFile).not.toHaveBeenCalled();
  expect(query).not.toHaveBeenCalled();
});

it.each([undefined, ''])('skips an unset or empty bootstrap path (%p)', async (file) => {
  await bootstrapOidcConfig(file, false);
  expect(queryOne).not.toHaveBeenCalled();
  expect(readFile).not.toHaveBeenCalled();
});

it.each([
  ['malformed JSON', `{"client_secret":"${secret}"`],
  ['admin fallback', JSON.stringify({ ...config, default_role: 'admin' })],
  ['missing client ID', JSON.stringify({ ...config, client_id: '' })],
  ['missing issuer', JSON.stringify({ ...config, issuer_url: '' })],
  ['invalid issuer', JSON.stringify({ ...config, issuer_url: 'not a URL' })],
  ['bare callback hostname', JSON.stringify({ ...config, public_base_url: 'manager.example.test' })],
  ['non-HTTP callback URL', JSON.stringify({ ...config, public_base_url: 'ftp://manager.example.test' })],
  ['callback URL with a query', JSON.stringify({ ...config, public_base_url: 'https://manager.example.test/?' })],
  ['callback URL with a fragment', JSON.stringify({ ...config, public_base_url: 'https://manager.example.test/#app' })],
  ['callback URL with credentials', JSON.stringify({ ...config, public_base_url: 'https://user:password@manager.example.test' })],
  ['invalid field type', JSON.stringify({ ...config, auto_provision: 'false' })],
  ['supplied ciphertext', JSON.stringify({ ...config, client_secret_encrypted: secret })],
])('redacts the error for %s', async (_description, json) => {
  jest.mocked(readFile).mockResolvedValue(json);
  await expect(bootstrapOidcConfig(file, true)).rejects.toEqual(
    new Error('OIDC_BOOTSTRAP_FILE import failed. Check the mounted JSON settings, database, and encryption key.')
  );
  expect(query).not.toHaveBeenCalled();
});

it.each(['', 'http://localhost:8080', 'https://manager.example.test/manager/'])(
  'accepts an optional HTTP(S) callback base URL (%p)',
  async (public_base_url) => {
    jest.mocked(readFile).mockResolvedValue(JSON.stringify({ ...config, public_base_url }));
    await bootstrapOidcConfig(file, true);
    const [, params] = jest.mocked(query).mock.calls[0];
    expect(JSON.parse(params?.[1] as string)).toMatchObject({ public_base_url });
  }
);

it('refuses an import when encryption key verification failed', async () => {
  await expect(bootstrapOidcConfig(file, false)).rejects.toThrow('OIDC_BOOTSTRAP_FILE import failed');
  expect(query).not.toHaveBeenCalled();
});
