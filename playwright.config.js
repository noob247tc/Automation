const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: '.',
  testMatch: 'video-progress.spec.js',

  workers: 1,

  retries: 0,

  // Disable test timeout to support infinite batch looping
  timeout: 0,

  use: {
    headless: true,
    browserName: 'chromium',
    launchOptions: {
      args: [
        '--autoplay-policy=no-user-gesture-required',
        '--disable-background-timer-throttling',
        '--disable-backgrounding-occluded-windows',
        '--disable-renderer-backgrounding',
        '--mute-audio'
      ]
    }
  }
});
