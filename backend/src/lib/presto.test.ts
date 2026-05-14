import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const fetchMock = vi.fn();

vi.stubGlobal('fetch', fetchMock);

describe('presto client', () => {
  beforeEach(() => {
    fetchMock.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('executes an authenticated presto query and maps rows', async () => {
    fetchMock
      .mockResolvedValueOnce({
        ok: true,
        text: async () =>
          JSON.stringify({
            id: 'query-1',
            nextUri: 'https://localhost:8443/v1/statement/query-1/1',
          }),
      })
      .mockResolvedValueOnce({
        ok: true,
        text: async () =>
          JSON.stringify({
            id: 'query-1',
            columns: [{ name: 'metric_name', type: 'varchar' }],
            data: [['temperature_c']],
          }),
      });

    const { executePrestoQuery } = await import('./presto.js');

    const rows = await executePrestoQuery<{ metric_name: string }>('SELECT metric_name FROM metrics');

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      'https://localhost:8443/v1/statement',
      expect.objectContaining({
        method: 'POST',
        body: 'SELECT metric_name FROM metrics',
        headers: expect.objectContaining({
          Authorization: 'Basic dGVzdC1wcmVzdG8tdXNlcjp0ZXN0LXByZXN0by1wYXNzd29yZA==',
          'X-Presto-User': 'test-presto-user',
          'X-Presto-Catalog': 'iceberg_data',
          'X-Presto-Schema': 'iot',
        }),
      }),
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      'https://localhost:8443/v1/statement/query-1/1',
      expect.objectContaining({
        method: 'GET',
      }),
    );
    expect(rows).toEqual([{ metric_name: 'temperature_c' }]);
  });

  it('surfaces presto query errors as dependency errors', async () => {
    fetchMock.mockResolvedValueOnce({
      ok: true,
      text: async () =>
        JSON.stringify({
          error: {
            message: 'catalog not found',
            errorName: 'CATALOG_NOT_FOUND',
          },
        }),
    });

    const { executePrestoQuery, PrestoDependencyError } = await import('./presto.js');

    await expect(executePrestoQuery('SELECT 1')).rejects.toBeInstanceOf(PrestoDependencyError);
  });
});

// Made with Bob