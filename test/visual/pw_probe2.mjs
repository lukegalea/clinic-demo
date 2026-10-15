import { chromium } from 'playwright';
const browser = await chromium.launch();
const page = await browser.newPage();
page.on('response', (r) => { if (r.status() === 404) console.log('404:', r.url()); });
await page.goto('http://localhost:4124/acting-as', { waitUntil: 'networkidle', timeout: 30_000 });
await page.waitForTimeout(5_000);
await browser.close();
