// End-to-end checks for the landing page in docs/.
// Usage: node scripts/site-test.mjs [url]   (default http://localhost:8765/index.html)
// Needs playwright (npm i -D playwright) and a Chromium (npx playwright install chromium).
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:8765/index.html';
const results = [];
let failed = 0;
function check(name, ok, detail) {
  results.push({ name, ok, detail });
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  (' + detail + ')' : ''}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });

async function newPage(opts = {}) {
  const page = await browser.newPage({ viewport: { width: 1360, height: 900 }, colorScheme: 'dark', ...opts });
  page.errors = [];
  page.on('pageerror', (e) => page.errors.push(String(e.message)));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) page.errors.push(m.text()); }); // resource failures are checked separately
  // Keep analytics local: swallow the gtag script and record what the page would send.
  await page.route(/googletagmanager\.com|google-analytics\.com/, (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: '' }));
  return page;
}

// ---------- desktop ----------
{
  const page = await newPage();
  const failedRequests = [];
  page.on('requestfailed', (r) => { if (!r.url().includes('googletagmanager')) failedRequests.push(r.url()); });
  await page.goto(url, { waitUntil: 'networkidle' });

  check('page loads with a title', (await page.title()).includes('Headroom'), await page.title());
  check('no JavaScript errors on load', page.errors.length === 0, page.errors.join(' | '));
  check('all assets load', failedRequests.length === 0, failedRequests.join(', '));

  const fonts = await page.evaluate(() => document.fonts.check('600 20px Geist') && document.fonts.check('12px "Geist Mono"'));
  check('self-hosted Geist fonts are active', fonts);
  check('stylesheet is inlined (no render-blocking CSS request)', (await page.$$('link[rel=stylesheet]')).length === 0);

  const broken = await page.$$eval('img', (imgs) => imgs.filter((i) => i.complete && i.naturalWidth === 0).map((i) => i.getAttribute('src')));
  check('no broken images', broken.length === 0, broken.join(', '));
  await page.locator('#dup-shot img').scrollIntoViewIfNeeded();
  const dupShot = await page.waitForFunction(() => { const i = document.querySelector('#dup-shot img'); return !i.closest('figure').hidden && i.complete && i.naturalWidth > 0; }, null, { timeout: 5000 }).then(() => true, () => false);
  await page.evaluate(() => window.scrollTo(0, 0));
  check('duplicates screenshot is shown', dupShot);

  const anchors = await page.$$eval('a[href^="#"]', (as) => as.map((a) => a.getAttribute('href')).filter((h) => h.length > 1 && !document.querySelector(h)));
  check('every in-page link has a target', anchors.length === 0, anchors.join(', '));

  const h1Lines = await page.$eval('h1', (h) => Math.round(h.getBoundingClientRect().height / parseFloat(getComputedStyle(h).lineHeight)));
  check('hero headline is 2 lines on desktop', h1Lines === 2, `${h1Lines} lines`);

  // hero demo: scan, hover, zoom, clean, reset
  await page.waitForFunction(() => document.getElementById('demo').classList.contains('scanned'), null, { timeout: 8000 }).catch(() => {});
  check('treemap demo finishes its scan', await page.$eval('#demo', (d) => d.classList.contains('scanned')));
  check('file counter reaches 1,256,000', (await page.textContent('[data-stat=files]')).trim() === '1,256,000');
  const box = await page.locator('#demo canvas').boundingBox();
  await page.mouse.move(box.x + box.width * 0.2, box.y + box.height * 0.3); await sleep(300);
  check('hover shows the tooltip', await page.$eval('.demo-tip', (t) => !t.hidden && t.textContent.length > 0));
  await page.mouse.click(box.x + box.width * 0.2, box.y + box.height * 0.3); await sleep(900);
  const crumbs = await page.$$eval('.demo-crumbs button', (b) => b.map((x) => x.textContent));
  check('click zooms into a folder (breadcrumbs grow)', crumbs.length >= 2, crumbs.join(' > '));
  await page.click('.demo-crumbs button'); await sleep(900);
  check('breadcrumb returns to the root', (await page.$$eval('.demo-crumbs button', (b) => b.length)) === 1);
  const freeBefore = await page.textContent('[data-stat=free]');
  await page.click('.demo-clean'); await sleep(1400);
  const freeAfter = await page.textContent('[data-stat=free]');
  check('Clean safe items raises free space', parseFloat(freeAfter) > parseFloat(freeBefore), `${freeBefore.trim()} -> ${freeAfter.trim()}`);
  check('button becomes Reset demo', (await page.textContent('.demo-clean')).includes('Reset'));
  await page.click('.demo-clean'); await sleep(1000);
  check('Reset restores the demo', (await page.textContent('[data-stat=free]')).trim() === freeBefore.trim());

  // menu bar demo
  await page.evaluate(() => document.getElementById('menubar').scrollIntoView({ block: 'start' }));
  await page.waitForFunction(() => document.querySelector('.mb-note').classList.contains('in'), null, { timeout: 9000 }).catch(() => {});
  check('menu bar demo shows the notification', await page.$eval('.mb-note', (n) => n.classList.contains('in')));
  check('ring turns red when low', await page.$eval('.mb-item', (i) => i.classList.contains('crit')));
  await page.click('.mb-clean'); await sleep(1600);
  check('Clean in the notification refills free space', (await page.textContent('[data-mb=free]')).trim() === '52 GB');
  check('Replay appears', await page.$eval('.mb-replay', (r) => !r.hidden));

  // duplicates: scroll-driven passes
  const seen = new Set();
  const top = await page.evaluate(() => document.getElementById('dup-stage').offsetTop);
  const h = await page.evaluate(() => document.getElementById('dup-stage').offsetHeight - window.innerHeight);
  for (const f of [0.05, 0.25, 0.45, 0.67, 0.9]) {
    await page.evaluate((y) => window.scrollTo(0, y), top + h * f); await sleep(f > 0.8 ? 1200 : 400);
    seen.add(await page.$eval('#dup-stage', (d) => d.getAttribute('data-pass')));
  }
  check('duplicate finder steps through passes 0 to 4 on scroll', ['0', '1', '2', '3', '4'].every((p) => seen.has(p)), [...seen].join(','));
  check('final pass shows the stack badge', await page.$eval('.group-badge', (b) => getComputedStyle(b).opacity === '1'));
  check('decoy cards are flipped at the end', await page.$eval('.card.decoy-size', (c) => getComputedStyle(c).transform !== 'none'));

  // theme toggle
  await page.click('#theme-toggle'); await sleep(500);
  const theme = await page.evaluate(() => document.documentElement.getAttribute('data-theme'));
  check('theme toggle switches theme', theme === 'light' || theme === 'dark', theme);
  check('theme is remembered', (await page.evaluate(() => { try { return localStorage.getItem('headroom-theme'); } catch (e) { return null; } })) === theme);

  // FAQ
  const faq = page.locator('.faq-list details').first();
  await faq.locator('summary').click(); await sleep(200);
  check('FAQ item opens', await faq.evaluate((d) => d.open));

  // analytics: events reach the dataLayer
  const events = await page.evaluate(() => (window.dataLayer || []).filter((e) => e[0] === 'event').map((e) => e[1]));
  const expected = ['page_context', 'demo_scan_complete', 'demo_hover', 'demo_zoom', 'demo_clean', 'demo_reset', 'menubar_notification_shown', 'menubar_clean', 'duplicates_pass', 'theme_toggle', 'faq_open', 'section_view'];
  const missing = expected.filter((e) => !events.includes(e));
  check('analytics events fire for every interaction', missing.length === 0, missing.length ? 'missing: ' + missing.join(', ') : `${events.length} events`);
  check('GA config uses the measurement id', await page.evaluate(() => (window.dataLayer || []).some((e) => e[0] === 'config' && e[1] === 'G-EE4D7SZGJC')));

  check('no JavaScript errors during interaction', page.errors.length === 0, page.errors.join(' | '));
  await page.close();
}

// ---------- light scheme ----------
{
  const page = await newPage({ colorScheme: 'light' });
  await page.goto(url, { waitUntil: 'networkidle' });
  const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  check('light scheme renders a light background', bg === 'rgb(246, 246, 248)', bg);
  await page.close();
}

// ---------- phone ----------
{
  const page = await newPage({ viewport: { width: 390, height: 844 } });
  await page.goto(url, { waitUntil: 'networkidle' });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  check('no horizontal scrolling on a phone', overflow <= 0, `${overflow}px overflow`);
  const h1Lines = await page.$eval('h1', (h) => Math.round(h.getBoundingClientRect().height / parseFloat(getComputedStyle(h).lineHeight)));
  check('hero headline is at most 3 lines on a phone', h1Lines <= 3, `${h1Lines} lines`);
  // phones: the duplicate finder autoplays once when it scrolls into view (no scroll pinning), then offers Replay
  // Jump there: the page scrolls smoothly, and a long smooth scroll would eat into the timing checked below.
  await page.evaluate(() => document.getElementById('duplicates').scrollIntoView({ behavior: 'instant' }));
  const dupPass = () => page.$eval('#dup-stage', (d) => d.getAttribute('data-pass'));
  await sleep(1500);
  const midPass = await dupPass();
  check('duplicates section autoplays on a phone (mid-run)', ['1', '2'].includes(midPass), `pass ${midPass}`);
  await page.waitForFunction(() => document.getElementById('dup-stage').classList.contains('done'), null, { timeout: 12000 }).catch(() => {});
  check('duplicates autoplay ends on the final pass', (await dupPass()) === '4');
  await sleep(900);   // the collapse is a 0.6s transition
  check('decoy cards collapse at the end on a phone', await page.$eval('.decoy-size', (c) => c.getBoundingClientRect().height < 2));
  check('Replay is offered on a phone', await page.$eval('.dup-replay', (b) => getComputedStyle(b).display !== 'none'));
  await page.click('.dup-replay'); await sleep(300);
  check('Replay restarts the animation', (await dupPass()) === '0');
  check('no JavaScript errors on a phone', page.errors.length === 0, page.errors.join(' | '));
  await page.close();
}

// ---------- reduced motion ----------
{
  const page = await newPage({ reducedMotion: 'reduce' });
  await page.goto(url, { waitUntil: 'networkidle' }); await sleep(500);
  check('reduced motion: treemap renders immediately', await page.$eval('#demo', (d) => d.classList.contains('scanned')));
  check('reduced motion: all reveal elements visible', await page.$$eval('.reveal', (els) => els.every((e) => getComputedStyle(e).opacity === '1')));
  await page.close();
}

await browser.close();
console.log(`\n${results.length - failed}/${results.length} checks passed`);
process.exit(failed ? 1 : 0);
