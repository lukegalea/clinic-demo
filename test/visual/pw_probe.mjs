import { chromium } from 'playwright';

const browser = await chromium.launch();
const page = await browser.newPage();
page.on('websocket', (ws) => console.log('WS OPEN:', ws.url()));
page.on('console', (msg) => {
  if (msg.type() === 'error') console.log('CONSOLE ERROR:', msg.text().slice(0, 200));
});
page.on('pageerror', (err) => console.log('PAGE ERROR:', String(err).slice(0, 300)));

await page.goto('http://localhost:4124/acting-as', { waitUntil: 'networkidle', timeout: 30_000 });
await page.waitForTimeout(8_000);

const pills = await page.locator('a[href*="/a2ui/actor"]').count();
const body = (await page.locator('body').innerText()).replace(/\s+/g, ' ').slice(0, 300);
console.log('pills:', pills);
console.log('body:', body);
await browser.close();
