const { test, expect } = require('@playwright/test');
const fs = require('fs');

const TARGET_URL = 'https://cb3newsmonitoringdashboard.lovable.app/lokal/langtad';
// Batch size defaults to 45 tabs (configurable via TABS=... environment variable)
const TAB_COUNT = parseInt(process.env.TABS || '45', 10);

/**
 * Ensures YouTube embed starts playing and runs at max supported speed (2.0x)
 */
async function startYouTubePlayback(page, iframe, player, video, prefix) {
  // 1. Focus iframe and allow player scripts to initialize
  await iframe.focus().catch(() => {});
  await page.waitForTimeout(1000);

  // 2. Try clicking play button inside iframe
  const playButton = player.locator('.ytp-large-play-button, button[aria-label="Play"]').first();
  if (await playButton.isVisible({ timeout: 5000 }).catch(() => false)) {
    console.log(`${prefix} Clicking YouTube large play button...`);
    await playButton.click({ force: true }).catch(() => {});
  } else {
    console.log(`${prefix} Clicking center of iframe...`);
    await iframe.click({ force: true }).catch(() => {});
  }

  // 3. Send postMessage command to YouTube iframe API
  await iframe.evaluate((el) => {
    try {
      el.contentWindow.postMessage(JSON.stringify({ event: 'command', func: 'playVideo', args: '' }), '*');
      el.contentWindow.postMessage(JSON.stringify({ event: 'command', func: 'setPlaybackRate', args: [2] }), '*');
    } catch (e) {}
  }).catch(() => {});

  // 4. Mute and trigger play on video tag, capping playbackRate at 2.0 (YouTube max)
  await video.evaluate((v) => {
    v.muted = true;
    try { v.playbackRate = 2.0; } catch (e) {}
    const p = v.play();
    if (p && typeof p.catch === 'function') p.catch(() => {});
  }).catch(() => {});

  // 5. Poll to confirm playback started, retrying the play trigger if paused
  await expect.poll(
    async () => {
      const state = await video.evaluate((v) => {
        if (v.paused) {
          v.muted = true;
          try { v.playbackRate = 2.0; } catch (e) {}
          v.play().catch(() => {});
        } else {
          try { v.playbackRate = 2.0; } catch (e) {}
        }
        return {
          paused: v.paused,
          currentTime: v.currentTime
        };
      }).catch(() => null);

      if (!state || state.paused) {
        await iframe.click({ force: true }).catch(() => {});
        await iframe.evaluate((el) => {
          try {
            el.contentWindow.postMessage(JSON.stringify({ event: 'command', func: 'playVideo', args: '' }), '*');
          } catch (e) {}
        }).catch(() => {});
      }

      return state ? !state.paused : false;
    },
    {
      timeout: 30000,
      intervals: [1500, 2500],
      message: `${prefix} Waiting for playback to start`
    }
  ).toBe(true);

  console.log(`${prefix} Playback confirmed at 2.0x speed.`);
}

async function runVideoSession(page, index, batch) {
  const prefix = `[Batch ${batch} | Tab ${index}]`;
  console.log(`${prefix} Opening dashboard...`);

  await page.goto(TARGET_URL, { waitUntil: 'domcontentloaded' });

  // Locate YouTube iframe
  const iframe = page.locator('iframe[src*="youtube"]').first();
  await expect(iframe).toBeVisible({ timeout: 45000 });
  await iframe.scrollIntoViewIfNeeded();

  const player = page.frameLocator('iframe[src*="youtube"]').first();
  const video = player.locator('video');
  await expect(video).toBeVisible({ timeout: 45000 });

  // Start playback
  await startYouTubePlayback(page, iframe, player, video, prefix);

  // Monitor watched percentage and confirmation message
  const successMessage = page.getByText(
    'Salamat! Your full view was counted for your lokal.',
    { exact: true }
  );

  let lastProgress = -1;
  await expect.poll(
    async () => {
      // Keep enforcing 2x speed and ensuring video isn't paused
      await video.evaluate((v) => {
        if (v.paused) v.play().catch(() => {});
        try { v.playbackRate = 2.0; } catch (e) {}
      }).catch(() => {});

      const body = await page.locator('body').innerText().catch(() => '');
      const match = body.match(/Watched\s+(\d+)%/);
      if (match) {
        const progress = Number(match[1]);
        if (progress !== lastProgress) {
          console.log(`${prefix} Watched ${progress}%`);
          lastProgress = progress;
        }
      }

      return await successMessage.isVisible().catch(() => false);
    },
    {
      timeout: 25 * 60 * 1000,
      intervals: [2000, 3000],
      message: `${prefix} Waiting for full-view confirmation`
    }
  ).toBe(true);

  console.log(`${prefix} Full-view confirmation achieved.`);
  await page.screenshot({
    path: `screenshots/batch-${batch}-tab-${index}-confirmed.png`,
    fullPage: true
  }).catch(() => {});
}

test('Play and monitor full-view confirmation infinitely in batches', async ({ browser }) => {
  test.setTimeout(0); // 0 disables test timeout so the infinite loop never gets killed
  fs.mkdirSync('screenshots', { recursive: true });

  let batch = 1;

  while (true) {
    console.log(`\n==================================================`);
    console.log(`[STARTING BATCH ${batch}] Launching ${TAB_COUNT} concurrent tabs...`);
    console.log(`==================================================\n`);

    // Create a dedicated browser context for each batch to completely free memory between batches
    const context = await browser.newContext();
    const pages = [];

    for (let i = 1; i <= TAB_COUNT; i++) {
      const page = await context.newPage();
      pages.push({ page, index: i });
    }

    // Run all tabs concurrently in this batch
    const tasks = pages.map(({ page, index }) =>
      runVideoSession(page, index, batch)
        .catch(async (err) => {
          console.error(`[Batch ${batch} | Tab ${index}] Error:`, err.message);
          await page.screenshot({
            path: `screenshots/batch-${batch}-tab-${index}-failed.png`,
            fullPage: true
          }).catch(() => {});
        })
        .finally(async () => {
          // Close each tab once its session is finished to free RAM immediately
          await page.close().catch(() => {});
        })
    );

    // Wait for all tabs in the current batch to finish
    await Promise.allSettled(tasks);

    console.log(`\n==================================================`);
    console.log(`[BATCH ${batch} COMPLETE] All ${TAB_COUNT} tabs finished. Clearing memory...`);
    console.log(`==================================================\n`);

    // Close the entire context to wipe cache/storage and prevent memory leaks
    await context.close().catch(() => {});

    batch++;

    console.log(`Starting next batch in 3 seconds...`);
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
});
