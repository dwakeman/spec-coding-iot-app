import { Router } from 'express';

import { deviceStateRepository } from '../repositories/device-state-repository.js';

export const sitesRouter = Router();

sitesRouter.get('/v1/sites', async (_req, res, next) => {
  try {
    const siteIds = await deviceStateRepository.listSiteIds();

    res.status(200).json({
      data: siteIds.map((siteId) => ({
        siteId,
      })),
    });
  } catch (error) {
    next(error);
  }
});

// Made with Bob