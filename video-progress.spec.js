const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const TARGET_URL = 'https://cb3newsmonitoringdashboard.lovable.app/lokal/langtad';
// Maintain 45 concurrent tabs running (configurable via TABS=... environment variable)
const TAB_COUNT = parseInt(process.env.TABS || '45', 10);

/**
 * Removes all screenshot image files from the screenshots folder
 */
function clearScreenshots() {
  const dir = path.join(__dirname, 'screenshots');
  if (fs.existsSync(dir)) {
    const files = fs.readdirSync(dir);
    for (const file of files) {
      if (/\.(png|jpe?g)$/i.test(file)) {
        try {
          fs.unlinkSync(path.join(dir, file));
        } catch (e) {}
      }
    }
  }
}

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

  console.log(`${prefix} Playback active at 2.0x.`);
}

async function runVideoSession(page, slotIndex, sessionCount) {
  const prefix = `[Slot ${slotIndex} | #${sessionCount}]`;
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
}

/**
 * An independent worker slot that maintains 1 active tab at all times.
 * When a session finishes, it closes the tab and immediately launches a new one.
 */
async function workerSlot(browser, slotIndex) {
  let sessionCount = 1;

  while (true) {
    const prefix = `[Slot ${slotIndex} | #${sessionCount}]`;
    let context;
    let page;

    try {
      // Create isolated context per session to release memory & cache completely
      context = await browser.newContext();
      page = await context.newPage();

      await runVideoSession(page, slotIndex, sessionCount);
    } catch (err) {
      console.error(`${prefix} Error:`, err.message);
      if (page) {
        await page.screenshot({
          path: `screenshots/slot-${slotIndex}-session-${sessionCount}-failed.png`,
          fullPage: true
        }).catch(() => {});
      }
    } finally {
      // Close the tab and context immediately when done to free RAM
      if (page) {
        await page.close().catch(() => {});
      }
      if (context) {
        await context.close().catch(() => {});
      }
      // Clean up screenshots periodically to keep disk space free
      clearScreenshots();
      sessionCount++;
    }

    // Immediate continuation into the next session
    console.log(`${prefix} Finished. Starting replacement tab immediately...`);
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
}

test('Maintain continuous pool of concurrent tabs running infinitely', async ({ browser }) => {
  test.setTimeout(0); // 0 disables test timeout so it runs indefinitely
  fs.mkdirSync('screenshots', { recursive: true });
  clearScreenshots();

  console.log(`\n==================================================`);
  console.log(`Starting ${TAB_COUNT} continuous rolling workers...`);
  console.log(`Each finished tab will immediately be replaced by a new tab.`);
  console.log(`==================================================\n`);

  // Launch TAB_COUNT independent workers with a slight stagger so the initial batch doesn't spike CPU/network
  const workers = Array.from({ length: TAB_COUNT }, async (_, i) => {
    if (i > 0) {
      await new Promise((resolve) => setTimeout(resolve, i * 600));
    }
    return workerSlot(browser, i + 1);
  });

  // Keep all workers running in parallel forever
  await Promise.all(workers);
});
