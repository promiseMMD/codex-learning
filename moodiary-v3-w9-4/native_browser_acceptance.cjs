const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { chromium } = require(process.env.MOODIARY_PLAYWRIGHT_MODULE || 'playwright');

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.MOODIARY_CHROME,
    headless: true, args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 }, locale: 'zh-CN' });
    await page.addInitScript(() => {
      window.__messages = [];
      window.MoodiaryEditor = { postMessage(raw) {
        const m = JSON.parse(raw); window.__messages.push(m);
        if (m.type === 'boot') queueMicrotask(() => window.MoodiaryBridge.respond(m.payload.reqId,
          JSON.stringify({ editable: true, locale: 'zh', theme: {
            roles: {}, dark: false, firstLineIndent: false, fontScale: 1, bodyOnly: true,
          } })));
      } };
    });
    await page.goto('file://' + path.resolve(process.argv[2]));
    await page.waitForFunction(() => window.__messages.some(m => m.type === 'ready'));
    await page.evaluate(() => {
      window.MoodiaryBridge.setContent(JSON.stringify({type:'doc',attrs:{v:2},content:[
        {type:'paragraph',content:[{type:'text',text:'手机原生块编辑验收'}]}]}));
      window.MoodiaryBridge.setTitle('这个独立标题不能出现在块编辑页');
      window.MoodiaryBridge.setMeta('');
    });
    await page.locator('.ProseMirror').click();
    await page.keyboard.press('Control+End');
    await page.evaluate(() => window.MoodiaryBridge.exec('toggleBold'));
    await page.keyboard.insertText(' · 当日补记');
    await page.evaluate(() => window.MoodiaryBridge.snapshot('actual-native-save'));
    const snapshot = await page.evaluate(() => window.__messages.filter(m=>m.type==='snapshot').at(-1).payload);
    assert.equal(snapshot.reqId, 'actual-native-save');
    const doc = JSON.parse(snapshot.document);
    assert.equal(doc.attrs.v, 2);
    assert.ok(snapshot.document.includes('当日补记'));
    assert.ok(snapshot.document.includes('bold'));
    assert.equal(await page.locator('.md-title').isVisible(), false);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
    assert.equal(overflow, false);
    fs.mkdirSync(process.argv[3], { recursive: true });
    await page.screenshot({ path: path.join(process.argv[3], 'native-body-editor.png') });
    await page.evaluate(() => {
      window.MoodiaryBridge.setTheme({roles:{},dark:false,firstLineIndent:false,fontScale:1,bodyOnly:false});
    });
    assert.equal(await page.locator('.md-title').isVisible(), true);
    await page.evaluate(() => {
      window.MoodiaryBridge.setContent(JSON.stringify({type:'doc',attrs:{v:99},content:[
        {type:'paragraph',content:[{type:'text',text:'未来版本不可保存'}]}]}));
      window.MoodiaryBridge.snapshot('future-schema');
    });
    const rejected = await page.evaluate(() => window.__messages.filter(m=>m.type==='snapshot').at(-1).payload);
    assert.equal(rejected.document, null);
    console.log('Native production editor: acknowledged rich snapshot, body-only title isolation, ordinary title regression, future-schema rejection, mobile overflow checks passed.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
